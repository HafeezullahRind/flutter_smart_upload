import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../adapters/upload_adapter.dart';
import '../compression/compressor.dart';
import '../exceptions/upload_exception.dart';
import '../io/chunk_reader.dart';
import '../models/chunk_upload_result.dart';
import '../models/upload_chunk.dart';
import '../models/upload_event.dart';
import '../models/upload_options.dart';
import '../models/upload_progress.dart';
import '../models/upload_request.dart';
import '../models/upload_result.dart';
import '../models/upload_session.dart';
import '../models/upload_status.dart';
import '../persistence/upload_record.dart';
import '../retry/retry_policy.dart';
import '../util/mime_types.dart';
import '../util/progress_tracker.dart';
import 'smart_upload_config.dart';
import 'upload_task.dart';

/// How a single run of [UploadManager.execute] ended.
@internal
enum UploadOutcome {
  /// The file was uploaded and the adapter finalised it.
  completed,

  /// The upload gave up. The task is terminal.
  failed,

  /// The upload stopped at a chunk boundary and can be resumed.
  paused,

  /// The caller cancelled. The task is terminal.
  cancelled,
}

/// Runs the full lifecycle of one upload: prepare, compress, checksum,
/// initialise, transfer chunk by chunk, finalise.
///
/// Everything that is not "talk to the server" lives here; everything that is
/// lives behind [UploadAdapter].
@internal
class UploadManager {
  /// Creates a manager.
  UploadManager({
    required this.config,
    required this.adapter,
    required void Function(UploadEvent event) emit,
  }) : _emit = emit;

  /// Global settings.
  final SmartUploadConfig config;

  /// The backend.
  final UploadAdapter adapter;

  final void Function(UploadEvent event) _emit;

  /// Runs [task] to completion, to a pause point, or to failure.
  ///
  /// [resumeFrom] carries persisted state when continuing an earlier run.
  Future<UploadOutcome> execute(UploadTask task, {UploadRecord? record}) async {
    final _RunState state = _RunState(task: task, record: record);
    TaskInternals.nextAttempt(task);
    try {
      await _prepare(state);
      if (await _shouldStop(state)) return _stopped(state);

      await _openSession(state);
      if (await _shouldStop(state)) return _stopped(state);

      final UploadOutcome? interrupted = await _transfer(state);
      if (interrupted != null) return interrupted;

      return await _finish(state);
    } on SmartUploadException catch (e) {
      return _abort(state, e);
    } catch (e, s) {
      return _abort(state, SmartUploadException.wrap(e, s));
    } finally {
      await state.reader?.close();
      state.reader = null;
    }
  }

  // ---------------------------------------------------------------- prepare

  /// Validates the file, compresses it, hashes it and plans the chunks.
  Future<void> _prepare(_RunState state) async {
    final UploadTask task = state.task;
    TaskInternals.setStatus(task, UploadStatus.preparing);
    _emit(UploadPreparingEvent(uploadId: task.id));

    final File source = task.file;
    if (!source.existsSync()) {
      throw SmartUploadException.fileNotFound(source.path);
    }
    final int sourceSize = await source.length();
    if (sourceSize <= 0) {
      throw SmartUploadException.invalidFile('File is empty: ${source.path}');
    }

    final UploadOptions options = task.options;
    final String sourceContentType =
        options.contentType ?? contentTypeForPath(source.path);

    state.payload = source;
    state.payloadSize = sourceSize;
    state.contentType = sourceContentType;

    await _compress(state, sourceContentType);
    await _hash(state);
    _planChunks(state);

    await _persist(state, UploadStatus.preparing);
  }

  /// Runs the compression stage when it can do something useful.
  Future<void> _compress(_RunState state, String sourceContentType) async {
    final UploadTask task = state.task;
    final UploadOptions options = task.options;
    final Compressor compressor = config.compressor;

    // Reuse a compressed artefact left behind by an interrupted run instead of
    // paying for compression twice.
    final String? previous = state.record?.uploadPath;
    if (previous != null && previous != task.file.path) {
      final File cached = File(previous);
      if (cached.existsSync()) {
        state.payload = cached;
        state.payloadSize = await cached.length();
        state.contentType = state.record?.contentType ?? sourceContentType;
        state.temporaryPayload = cached;
        return;
      }
    }

    if (!options.compress ||
        !compressor.canCompress(task.file, sourceContentType, options)) {
      return;
    }

    TaskInternals.setStatus(task, UploadStatus.compressing);
    _emit(UploadCompressingEvent(uploadId: task.id));

    final Directory workDir = await _workDirectory();
    late final CompressionResult result;
    try {
      result = await compressor.compress(
        file: task.file,
        options: options,
        contentType: sourceContentType,
        workDirectory: workDir,
      );
    } on SmartUploadException {
      rethrow;
    } catch (e, s) {
      throw SmartUploadException(
        'Compression failed for ${task.file.path}: $e',
        errorCode: UploadErrorCode.compressionFailed,
        cause: e,
        stackTrace: s,
      );
    }

    // A "compressed" file that grew is worse than no compression at all.
    final bool worthIt = result.didCompress &&
        (!options.skipCompressionIfLarger ||
            result.compressedSize < result.originalSize);

    if (!worthIt) {
      if (result.isTemporary) await _deleteQuietly(result.file);
      return;
    }

    state.payload = result.file;
    state.payloadSize = result.compressedSize;
    state.contentType = result.contentType;
    if (result.isTemporary) state.temporaryPayload = result.file;

    _emit(UploadCompressedEvent(
      uploadId: task.id,
      originalSize: result.originalSize,
      compressedSize: result.compressedSize,
    ));
  }

  /// Computes the whole-file digest when the caller asked for one.
  Future<void> _hash(_RunState state) async {
    final ChecksumMode mode =
        state.task.options.checksum ?? config.checksumMode;
    state.checksumMode = mode;
    if (!mode.includesFile) return;

    // Reuse the digest from the persisted record when the payload has not
    // changed; hashing is a full extra read of the file.
    final UploadRecord? record = state.record;
    if (record?.checksum != null &&
        record?.uploadSize == state.payloadSize &&
        record?.checksumAlgorithm == config.checksumProvider.algorithm &&
        !config.verifyChecksumOnResume) {
      state.checksum = record!.checksum;
      return;
    }

    final String digest =
        await config.checksumProvider.calculate(state.payload);
    if (record?.checksum != null && record!.checksum != digest) {
      throw SmartUploadException(
        'The file changed since this upload was persisted; it cannot be '
        'resumed safely.',
        errorCode: UploadErrorCode.checksumMismatch,
      );
    }
    state.checksum = digest;
  }

  /// Decides chunk size and chunk count.
  void _planChunks(_RunState state) {
    final int chunkSize = state.task.options.chunkSize ??
        state.initialSession?.chunkSize ??
        config.chunkSize;
    state.chunkSize = chunkSize;
    state.totalChunks =
        ((state.payloadSize + chunkSize - 1) ~/ chunkSize).clamp(1, 1 << 40);
  }

  // ---------------------------------------------------------------- session

  /// Opens a new adapter session, or revalidates a persisted one.
  Future<void> _openSession(_RunState state) async {
    final UploadTask task = state.task;
    final UploadRequest request = UploadRequest(
      uploadId: task.id,
      file: state.payload,
      fileName: task.fileName,
      fileSize: state.payloadSize,
      contentType: state.contentType,
      chunkSize: state.chunkSize,
      totalChunks: state.totalChunks,
      checksum: state.checksum,
      metadata: task.options.metadata,
      options: task.options,
    );

    final UploadSession? persisted = state.initialSession;
    UploadSession session;
    if (persisted != null) {
      try {
        session = await _run(
          state,
          () => adapter.restore(persisted),
          timeout: config.sessionTimeout,
          fallback: UploadErrorCode.resumeFailed,
        );
        state.resumed = true;
      } on SmartUploadException catch (e) {
        if (e.errorCode != UploadErrorCode.resumeFailed) rethrow;
        // The server forgot the session: start over rather than fail.
        session = await _initialize(state, request);
      }
    } else {
      session = await _initialize(state, request);
    }

    // The server may mandate a different chunk size than we planned with.
    //
    // Chunk indices are only meaningful relative to a chunk size, and this
    // stays consistent because `state.uploaded` is always taken from the same
    // response that carried the size: a resumed plan plans with
    // `initialSession.chunkSize`, so `restore` returning it unchanged is a
    // no-op here, and a fresh `initialize` sets both together.
    final int? serverChunkSize = session.chunkSize;
    if (serverChunkSize != null && serverChunkSize != state.chunkSize) {
      state.chunkSize = serverChunkSize;
      state.totalChunks =
          ((state.payloadSize + serverChunkSize - 1) ~/ serverChunkSize)
              .clamp(1, 1 << 40);
    }

    state.session = session;
    state.uploaded = <int>{...session.uploadedChunkIndices}
      ..removeWhere((int i) => i < 0 || i >= state.totalChunks);
    state.tracker = ProgressTracker(
      totalBytes: state.payloadSize,
      initialBytes: _bytesFor(state, state.uploaded),
    );
    await _persist(state, UploadStatus.uploading);
  }

  Future<UploadSession> _initialize(
    _RunState state,
    UploadRequest request,
  ) async {
    final UploadSession session = await _run(
      state,
      () => adapter.initialize(request),
      timeout: config.sessionTimeout,
      fallback: UploadErrorCode.serverError,
    );
    state.resumed = false;
    return session;
  }

  // --------------------------------------------------------------- transfer

  /// Uploads every chunk the server does not already hold.
  ///
  /// Returns `null` when the whole file was transferred, or the outcome that
  /// interrupted it.
  Future<UploadOutcome?> _transfer(_RunState state) async {
    final UploadTask task = state.task;
    TaskInternals.setStatus(task, UploadStatus.uploading);
    _emit(UploadStartedEvent(
      uploadId: task.id,
      totalBytes: state.payloadSize,
      totalChunks: state.totalChunks,
      resumed: state.resumed,
    ));
    _publishProgress(state, force: true);

    final ChunkReader reader = await ChunkReader.open(
      state.payload,
      chunkSize: state.chunkSize,
    );
    state.reader = reader;
    state.tracker.start();

    // Ascending order matters: backends that append rather than address parts
    // by index depend on it, and it makes "resume from the first gap" the
    // natural behaviour.
    for (int index = 0; index < state.totalChunks; index++) {
      if (state.uploaded.contains(index)) continue;

      final UploadOutcome? stop = await _checkpoint(state);
      if (stop != null) return stop;

      UploadChunk chunk = await reader.read(index);
      if (state.checksumMode.includesChunk) {
        chunk = chunk.withChecksum(
          await config.checksumProvider.calculateBytes(chunk.bytes),
        );
      }

      final ChunkUploadResult result = await _run(
        state,
        () => adapter.uploadChunk(state.session, chunk),
        timeout: config.chunkTimeout,
        chunkIndex: index,
        fallback: UploadErrorCode.chunkUploadFailed,
      );

      final int accepted =
          result.bytesUploaded <= 0 ? chunk.size : result.bytesUploaded;
      state.uploaded.add(index);
      final UploadSession base = result.session ?? state.session;
      state.session = base.copyWith(
        uploadedChunkIndices: <int>{...base.uploadedChunkIndices, index},
        uploadedBytes: _bytesFor(state, state.uploaded),
      );
      state.tracker.add(accepted);

      _emit(UploadChunkCompletedEvent(
        uploadId: task.id,
        chunkIndex: index,
        totalChunks: state.totalChunks,
        bytesUploaded: accepted,
      ));
      _publishProgress(state, force: index == state.totalChunks - 1);
      await _persist(state, UploadStatus.uploading);
    }

    await reader.close();
    state.reader = null;
    return null;
  }

  /// Honours pause, cancellation and connectivity between chunks.
  Future<UploadOutcome?> _checkpoint(_RunState state) async {
    final UploadTask task = state.task;
    if (TaskInternals.isCancelRequested(task)) {
      await _cancelSession(state);
      await _cleanup(state, deleteTemporary: true, deleteRecord: true);
      TaskInternals.fail(task, SmartUploadException.cancelled(),
          cancelled: true);
      _emit(UploadCancelledEvent(uploadId: task.id));
      return UploadOutcome.cancelled;
    }
    if (TaskInternals.isPauseRequested(task)) {
      await _pause(state);
      return UploadOutcome.paused;
    }
    if (config.waitForNetwork && !await config.networkMonitor.isOnline()) {
      final bool online = await _awaitNetwork(state);
      // Cancellation or a pause may have arrived while we waited; those take
      // precedence over reporting the connectivity failure.
      if (TaskInternals.isCancelRequested(task) ||
          TaskInternals.isPauseRequested(task)) {
        return _checkpoint(state);
      }
      if (!online) {
        throw SmartUploadException.network(
          'Still offline after ${config.networkWaitTimeout.inSeconds}s',
        );
      }
      return _checkpoint(state);
    }
    return null;
  }

  /// Parks the upload until connectivity returns.
  ///
  /// Nothing is sent while offline — no retry storm, no radio wake-ups — the
  /// task simply waits on the monitor's stream.
  Future<bool> _awaitNetwork(_RunState state) async {
    final UploadTask task = state.task;
    state.tracker.pause();
    TaskInternals.setWaitingForNetwork(task, true);
    TaskInternals.setStatus(task, UploadStatus.paused);
    _emit(UploadPausedEvent(uploadId: task.id, waitingForNetwork: true));
    try {
      // Racing the cancel signal means `cancel()` does not have to wait out
      // the whole connectivity timeout.
      final bool online = await Future.any<bool>(<Future<bool>>[
        config.networkMonitor.onConnectivityChanged
            .firstWhere((bool online) => online)
            .timeout(config.networkWaitTimeout, onTimeout: () => false),
        TaskInternals.cancelSignal(task).then((_) => false),
      ]);
      return online;
    } on StateError {
      // The connectivity stream closed without ever reporting "online".
      return false;
    } finally {
      TaskInternals.setWaitingForNetwork(task, false);
      if (!task.status.isTerminal) {
        TaskInternals.setStatus(task, UploadStatus.uploading);
        _emit(UploadResumedEvent(uploadId: task.id));
      }
      state.tracker.resume();
    }
  }

  /// Stops at a chunk boundary, keeping everything needed to continue.
  Future<void> _pause(_RunState state) async {
    state.tracker.pause();
    await state.reader?.close();
    state.reader = null;
    await _persist(state, UploadStatus.paused);
    TaskInternals.clearPause(state.task);
    TaskInternals.setStatus(state.task, UploadStatus.paused);
    _emit(UploadPausedEvent(uploadId: state.task.id));
  }

  // ----------------------------------------------------------------- finish

  /// Finalises the upload with the adapter and completes the task.
  Future<UploadOutcome> _finish(_RunState state) async {
    final UploadTask task = state.task;
    final UploadResult raw = await _run(
      state,
      () => adapter.complete(state.session),
      timeout: config.sessionTimeout,
      fallback: UploadErrorCode.serverError,
    );

    final UploadResult result = raw.copyWith(
      fileName: raw.fileName ?? task.fileName,
      fileSize: raw.fileSize == 0 ? state.payloadSize : raw.fileSize,
      bytesUploaded: raw.bytesUploaded == 0
          ? state.tracker.bytesThisRun
          : raw.bytesUploaded,
      duration:
          raw.duration == Duration.zero ? state.tracker.elapsed : raw.duration,
      checksum: raw.checksum ?? state.checksum,
    );

    await _cleanup(
      state,
      deleteTemporary: true,
      deleteRecord: config.deleteRecordOnSuccess,
      completedStatus: UploadStatus.completed,
    );
    TaskInternals.complete(task, result);
    _emit(UploadCompletedEvent(uploadId: task.id, result: result));
    return UploadOutcome.completed;
  }

  /// Handles a terminal failure, distinguishing cancellation from a real
  /// error.
  Future<UploadOutcome> _abort(
    _RunState state,
    SmartUploadException error,
  ) async {
    final UploadTask task = state.task;
    final bool cancelled = error.errorCode == UploadErrorCode.uploadCancelled ||
        TaskInternals.isCancelRequested(task);

    if (cancelled) {
      await _cancelSession(state);
      await _cleanup(state, deleteTemporary: true, deleteRecord: true);
      if (!task.isFinished) {
        TaskInternals.fail(task, SmartUploadException.cancelled(),
            cancelled: true);
        _emit(UploadCancelledEvent(uploadId: task.id));
      }
      return UploadOutcome.cancelled;
    }

    // Keep the record and any compressed artefact: this upload is a candidate
    // for `uploader.resume(id)`.
    await _persist(state, UploadStatus.failed, error: error);
    TaskInternals.fail(task, error);
    _emit(UploadFailedEvent(
      uploadId: task.id,
      error: error,
      attempts: task.attempts,
    ));
    return UploadOutcome.failed;
  }

  /// Returns the outcome for a task that was stopped before transferring.
  Future<UploadOutcome> _stopped(_RunState state) async {
    final UploadTask task = state.task;
    if (TaskInternals.isCancelRequested(task)) {
      await _cancelSession(state);
      await _cleanup(state, deleteTemporary: true, deleteRecord: true);
      if (!task.isFinished) {
        TaskInternals.fail(task, SmartUploadException.cancelled(),
            cancelled: true);
        _emit(UploadCancelledEvent(uploadId: task.id));
      }
      return UploadOutcome.cancelled;
    }
    await _pause(state);
    return UploadOutcome.paused;
  }

  /// Whether the task was paused or cancelled outside a transfer loop.
  Future<bool> _shouldStop(_RunState state) async =>
      TaskInternals.isCancelRequested(state.task) ||
      TaskInternals.isPauseRequested(state.task);

  // ------------------------------------------------------------------ infra

  /// Runs an adapter call with a timeout, cancellation racing and retries.
  Future<T> _run<T>(
    _RunState state,
    Future<T> Function() operation, {
    required Duration timeout,
    required UploadErrorCode fallback,
    int? chunkIndex,
  }) async {
    final RetryPolicy policy = config.retryPolicy;
    int attempt = 0;
    while (true) {
      try {
        return await _race(state.task, operation(), timeout, fallback);
      } on SmartUploadException catch (error) {
        if (error.errorCode == UploadErrorCode.uploadCancelled) rethrow;
        attempt++;
        final RetryContext context = RetryContext(
          attempt: attempt,
          error: error,
          elapsed: state.tracker.elapsed,
          chunkIndex: chunkIndex,
          adapterSaysRetryable: adapter.isRetryable(error),
        );
        if (!policy.shouldRetry(context)) rethrow;

        final Duration delay = policy.delayFor(context);
        _emit(UploadRetryEvent(
          uploadId: state.task.id,
          attempt: attempt,
          maxAttempts: policy.maxRetries,
          delay: delay,
          error: error,
          chunkIndex: chunkIndex,
        ));
        await _backoff(state, error, delay);
      }
    }
  }

  /// Waits out the backoff, or waits for the network when that is the real
  /// problem — whichever is more likely to make the next attempt succeed.
  Future<void> _backoff(
    _RunState state,
    SmartUploadException error,
    Duration delay,
  ) async {
    final bool networkish = error.errorCode == UploadErrorCode.networkError ||
        error.errorCode == UploadErrorCode.timeout;
    if (networkish &&
        config.waitForNetwork &&
        !await config.networkMonitor.isOnline()) {
      await _awaitNetwork(state);
      return;
    }
    await Future.any<void>(<Future<void>>[
      Future<void>.delayed(delay),
      TaskInternals.cancelSignal(state.task),
    ]);
  }

  /// Applies the timeout and lets a cancellation abandon an in-flight call.
  Future<T> _race<T>(
    UploadTask task,
    Future<T> operation,
    Duration timeout,
    UploadErrorCode fallback,
  ) async {
    final Completer<T> race = Completer<T>();

    // Whichever finishes first wins; the loser's outcome is dropped rather
    // than left to surface as an unhandled async error.
    unawaited(operation.timeout(timeout).then<void>(
      (T value) {
        if (!race.isCompleted) race.complete(value);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (race.isCompleted) return;
        if (error is TimeoutException) {
          race.completeError(
            SmartUploadException.timeout(
              'Operation timed out after ${timeout.inSeconds}s',
              cause: error,
            ),
            stackTrace,
          );
        } else {
          race.completeError(
            SmartUploadException.wrap(error, stackTrace, fallback),
            stackTrace,
          );
        }
      },
    ));

    unawaited(TaskInternals.cancelSignal(task).then<void>((_) {
      if (!race.isCompleted) {
        race.completeError(SmartUploadException.cancelled());
      }
    }));

    return race.future;
  }

  /// Asks the adapter to discard the server-side session, ignoring failures.
  Future<void> _cancelSession(_RunState state) async {
    final UploadSession? session = state.sessionOrNull;
    if (session == null) return;
    try {
      await adapter.cancel(session).timeout(config.sessionTimeout);
    } catch (_) {
      // Cleanup is best effort; the cancellation itself already succeeded.
    }
  }

  /// Deletes temporary artefacts and persisted state as appropriate.
  Future<void> _cleanup(
    _RunState state, {
    required bool deleteTemporary,
    required bool deleteRecord,
    UploadStatus? completedStatus,
  }) async {
    await state.reader?.close();
    state.reader = null;
    if (deleteTemporary && state.temporaryPayload != null) {
      await _deleteQuietly(state.temporaryPayload!);
      state.temporaryPayload = null;
    }
    if (deleteRecord) {
      await _deleteRecord(state);
    } else if (completedStatus != null) {
      await _persist(state, completedStatus);
    }
  }

  Future<void> _deleteRecord(_RunState state) async {
    try {
      await config.storage.delete(state.task.id);
    } catch (_) {
      // A stale record is harmless compared to failing a finished upload.
    }
  }

  /// Writes the current state so the upload can survive a restart.
  Future<void> _persist(
    _RunState state,
    UploadStatus status, {
    SmartUploadException? error,
  }) async {
    final UploadTask task = state.task;
    final DateTime now = DateTime.now();
    final UploadRecord record = UploadRecord(
      uploadId: task.id,
      sourcePath: task.file.path,
      uploadPath: state.payload.path,
      fileName: task.fileName,
      fileSize: task.fileSize,
      uploadSize: state.payloadSize,
      contentType: state.contentType,
      status: status,
      checksum: state.checksum,
      checksumAlgorithm:
          state.checksum == null ? null : config.checksumProvider.algorithm,
      chunkSize: state.chunkSize,
      totalChunks: state.totalChunks,
      uploadedChunkIndices: <int>{...state.uploaded},
      uploadedBytes: _bytesFor(state, state.uploaded),
      session: state.sessionOrNull ?? state.initialSession,
      options: task.options,
      errorMessage: error?.message,
      errorCode: error?.code,
      attempts: task.attempts,
      createdAt: state.record?.createdAt ?? now,
      updatedAt: now,
    );
    state.record = record;
    try {
      await config.storage.save(record);
    } catch (_) {
      // Persistence is an optimisation: losing it costs a restart, not the
      // upload in progress. A third-party storage is not allowed to take an
      // in-flight transfer down with it.
    }
  }

  /// Publishes progress, damped to [SmartUploadConfig.progressInterval].
  void _publishProgress(_RunState state, {bool force = false}) {
    final UploadProgress progress = state.tracker.snapshot;
    final Duration since = progress.elapsed - state.lastProgressAt;
    if (!force && since < config.progressInterval) return;
    state.lastProgressAt = progress.elapsed;
    TaskInternals.setProgress(state.task, progress);
    _emit(UploadProgressEvent(uploadId: state.task.id, progress: progress));
  }

  /// Total bytes represented by a set of chunk indices.
  int _bytesFor(_RunState state, Set<int> indices) {
    int total = 0;
    for (final int index in indices) {
      final int start = index * state.chunkSize;
      final int size = state.payloadSize - start;
      total += size < state.chunkSize ? (size < 0 ? 0 : size) : state.chunkSize;
    }
    return total;
  }

  /// Ensures the directory used for compressed temporary files exists.
  Future<Directory> _workDirectory() async {
    final Directory dir = config.tempDirectory ??
        Directory(p.join(Directory.systemTemp.path, 'flutter_smart_upload'));
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (file.existsSync()) await file.delete();
    } on FileSystemException {
      // Temp files are reclaimed by the OS eventually.
    }
  }
}

/// Mutable bookkeeping for a single run of [UploadManager.execute].
class _RunState {
  _RunState({required this.task, this.record})
      : initialSession = record?.session,
        payload = task.file,
        payloadSize = task.fileSize,
        tracker = ProgressTracker(totalBytes: task.fileSize);

  final UploadTask task;

  /// The persisted record, if this run continues an earlier one.
  ///
  /// Replaced every time state is written, so anything needed from the
  /// *incoming* record is captured separately (see [initialSession]).
  UploadRecord? record;

  /// The session persisted by an earlier run, pinned for the whole run.
  final UploadSession? initialSession;

  /// The file whose bytes are being sent — source or compressed copy.
  File payload;

  /// Size of [payload].
  int payloadSize;

  /// Temporary artefact to delete when the upload finishes.
  File? temporaryPayload;

  /// MIME type of [payload].
  String contentType = kDefaultContentType;

  /// Whole-file digest, when computed.
  String? checksum;

  /// Effective checksum mode for this upload.
  ChecksumMode checksumMode = ChecksumMode.none;

  /// Effective chunk size.
  int chunkSize = SmartUploadConfig.defaultChunkSize;

  /// Number of chunks in the plan.
  int totalChunks = 1;

  /// Indices known to be stored server-side.
  Set<int> uploaded = <int>{};

  /// The open file handle, while transferring.
  ChunkReader? reader;

  /// Progress bookkeeping.
  ProgressTracker tracker;

  /// The adapter's session, once opened.
  UploadSession? _session;

  /// Whether this run continued a persisted session.
  bool resumed = false;

  /// Elapsed time at the last published progress event.
  Duration lastProgressAt = Duration.zero;

  /// The session, which is always present after `_openSession`.
  UploadSession get session => _session!;

  set session(UploadSession value) => _session = value;

  /// The session, or `null` if one was never opened.
  UploadSession? get sessionOrNull => _session;
}
