import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_smart_upload/flutter_smart_upload.dart';

/// Creates a temporary directory that is removed when the test ends.
Directory createTempDir([String prefix = 'fsu_test']) =>
    Directory.systemTemp.createTempSync(prefix);

/// Writes a file of [size] bytes filled with a deterministic pattern.
File createFile(Directory dir, String name, int size) {
  final File file = File('${dir.path}/$name');
  final Uint8List bytes = Uint8List(size);
  for (int i = 0; i < size; i++) {
    bytes[i] = i % 251;
  }
  file.writeAsBytesSync(bytes);
  return file;
}

/// Writes a file of [size] bytes of random data.
File createRandomFile(Directory dir, String name, int size, [int seed = 7]) {
  final Random random = Random(seed);
  final Uint8List bytes = Uint8List(size);
  for (int i = 0; i < size; i++) {
    bytes[i] = random.nextInt(256);
  }
  File('${dir.path}/$name').writeAsBytesSync(bytes);
  return File('${dir.path}/$name');
}

/// A configurable fake backend that records everything it is asked to do.
///
/// The knobs cover the failure modes worth testing: a chunk that fails N times
/// before succeeding, a permanently rejected chunk, an unauthorised session,
/// and a slow server.
class MockUploadAdapter extends UploadAdapter {
  MockUploadAdapter({
    this.latency = Duration.zero,
    this.chunkLatency = Duration.zero,
    Map<int, int>? transientChunkFailures,
    this.permanentChunkFailure,
    this.initializeFailures = 0,
    this.completeFailures = 0,
    this.failInitializeWith,
    this.failChunkWith,
    this.resumeFails = false,
    this.reportUploadedChunks = const <int>{},
    this.serverChunkSize,
  }) : _transientChunkFailures =
            Map<int, int>.of(transientChunkFailures ?? const <int, int>{});

  /// Delay applied to `initialize` and `complete`.
  final Duration latency;

  /// Delay applied to `uploadChunk`.
  final Duration chunkLatency;

  /// Chunk index -> how many times it should fail before succeeding.
  final Map<int, int> _transientChunkFailures;

  /// A chunk index that always fails.
  final int? permanentChunkFailure;

  /// How many times `initialize` should fail before succeeding.
  int initializeFailures;

  /// How many times `complete` should fail before succeeding.
  int completeFailures;

  /// Error thrown by a failing `initialize`. Defaults to a server error.
  final SmartUploadException? failInitializeWith;

  /// Error thrown by a failing `uploadChunk`. Defaults to a server error.
  final SmartUploadException? failChunkWith;

  /// Whether `restore` should reject the persisted session.
  final bool resumeFails;

  /// Chunk indices the "server" claims to already hold.
  final Set<int> reportUploadedChunks;

  /// A chunk size the "server" mandates, overriding the client's plan.
  final int? serverChunkSize;

  /// Chunk indices in the order they were received, including retries.
  final List<int> receivedOrder = <int>[];

  /// Payload of every accepted chunk, keyed by index.
  final Map<int, Uint8List> storedChunks = <int, Uint8List>{};

  /// Per-chunk checksums handed over by the orchestrator.
  final Map<int, String?> chunkChecksums = <int, String?>{};

  /// Requests seen by `initialize`.
  final List<UploadRequest> requests = <UploadRequest>[];

  int initializeCalls = 0;
  int completeCalls = 0;
  int cancelCalls = 0;
  int restoreCalls = 0;

  /// Called before each chunk is processed; use it to inject side effects
  /// (pausing, going offline, cancelling) at an exact point in the transfer.
  FutureOr<void> Function(UploadChunk chunk)? onChunk;

  /// The reassembled payload.
  Uint8List assembled() {
    final BytesBuilder builder = BytesBuilder(copy: false);
    for (final int index in storedChunks.keys.toList()..sort()) {
      builder.add(storedChunks[index]!);
    }
    return builder.takeBytes();
  }

  @override
  Future<UploadSession> initialize(UploadRequest request) async {
    initializeCalls++;
    requests.add(request);
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    if (initializeFailures > 0) {
      initializeFailures--;
      throw failInitializeWith ??
          SmartUploadException.server('initialize failed');
    }
    return UploadSession(
      uploadId: request.uploadId,
      sessionId: 'session-${request.uploadId}',
      chunkSize: serverChunkSize,
      uploadedChunkIndices: Set<int>.of(reportUploadedChunks),
    );
  }

  @override
  Future<ChunkUploadResult> uploadChunk(
    UploadSession session,
    UploadChunk chunk,
  ) async {
    await onChunk?.call(chunk);
    if (chunkLatency > Duration.zero) await Future<void>.delayed(chunkLatency);
    receivedOrder.add(chunk.index);

    if (chunk.index == permanentChunkFailure) {
      throw failChunkWith ??
          SmartUploadException.server('chunk ${chunk.index} always fails');
    }
    final int remaining = _transientChunkFailures[chunk.index] ?? 0;
    if (remaining > 0) {
      _transientChunkFailures[chunk.index] = remaining - 1;
      throw failChunkWith ??
          SmartUploadException.server('chunk ${chunk.index} failed');
    }

    storedChunks[chunk.index] = chunk.bytes;
    chunkChecksums[chunk.index] = chunk.checksum;
    return ChunkUploadResult.accepted(chunk, etag: 'etag-${chunk.index}');
  }

  @override
  Future<UploadResult> complete(UploadSession session) async {
    completeCalls++;
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    if (completeFailures > 0) {
      completeFailures--;
      throw SmartUploadException.server('complete failed');
    }
    return UploadResult(
      uploadId: session.uploadId,
      url: 'https://cdn.test/${session.uploadId}',
      data: <String, Object?>{'sessionId': session.sessionId},
    );
  }

  @override
  Future<void> cancel(UploadSession session) async {
    cancelCalls++;
  }

  @override
  Future<UploadSession> restore(UploadSession session) async {
    restoreCalls++;
    if (resumeFails) {
      throw SmartUploadException(
        'session expired',
        errorCode: UploadErrorCode.resumeFailed,
      );
    }
    return session;
  }
}

/// A retry policy with no waiting, so retry tests run instantly.
class InstantRetryPolicy extends RetryPolicy {
  const InstantRetryPolicy({this.maxRetries = 3});

  @override
  final int maxRetries;

  @override
  bool shouldRetry(RetryContext context) =>
      context.attempt <= maxRetries &&
      context.error.isRetryable &&
      context.adapterSaysRetryable;

  @override
  Duration delayFor(RetryContext context) => Duration.zero;
}

/// Builds a config with test-friendly defaults: tiny chunks, instant retries.
SmartUploadConfig testConfig({
  int chunkSize = 1024,
  int maxConcurrentUploads = 2,
  int maxRetries = 3,
  UploadStorage? storage,
  Compressor? compressor,
  NetworkMonitor? networkMonitor,
  ChecksumMode checksumMode = ChecksumMode.none,
  ChecksumProvider? checksumProvider,
  Directory? tempDirectory,
  bool deleteRecordOnSuccess = true,
  bool waitForNetwork = false,
  Duration networkWaitTimeout = const Duration(seconds: 2),
  Duration progressInterval = Duration.zero,
  Duration chunkTimeout = const Duration(seconds: 5),
  RetryPolicy? retryPolicy,
}) =>
    SmartUploadConfig(
      chunkSize: chunkSize,
      maxConcurrentUploads: maxConcurrentUploads,
      maxRetries: maxRetries,
      retryPolicy: retryPolicy ?? InstantRetryPolicy(maxRetries: maxRetries),
      storage: storage,
      compressor: compressor ?? const NoopCompressor(),
      networkMonitor: networkMonitor ?? const AlwaysOnlineNetworkMonitor(),
      checksumMode: checksumMode,
      checksumProvider: checksumProvider ?? const Md5ChecksumProvider(),
      tempDirectory: tempDirectory,
      deleteRecordOnSuccess: deleteRecordOnSuccess,
      waitForNetwork: waitForNetwork,
      networkWaitTimeout: networkWaitTimeout,
      progressInterval: progressInterval,
      chunkTimeout: chunkTimeout,
    );
