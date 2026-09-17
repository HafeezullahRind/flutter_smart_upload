import 'dart:async';
import 'dart:typed_data';

import '../models/chunk_upload_result.dart';
import '../models/upload_chunk.dart';
import '../models/upload_request.dart';
import '../models/upload_result.dart';
import '../models/upload_session.dart';
import 'upload_adapter.dart';

/// A fake backend that keeps uploads in memory.
///
/// Intended for tests, demos and the example app — it lets you exercise the
/// whole pipeline (chunking, progress, pause, resume, retry, queueing) without
/// a server. Do not use it in production: everything it "stores" is discarded
/// when the process exits.
///
/// ```dart
/// final SmartUploader uploader = SmartUploader(
///   adapter: InMemoryUploadAdapter(latency: const Duration(milliseconds: 50)),
/// );
/// ```
class InMemoryUploadAdapter extends UploadAdapter {
  /// Creates a fake backend.
  ///
  /// Set [retainBytes] to `false` — the default — to count bytes without
  /// keeping them, which is what you want when the example app uploads a
  /// 500 MB video on a phone.
  InMemoryUploadAdapter({
    this.latency = Duration.zero,
    this.retainBytes = false,
    this.baseUrl = 'memory://uploads',
  });

  /// Artificial delay applied to every call, to make progress visible in a
  /// demo UI.
  final Duration latency;

  /// Whether to keep chunk payloads, so tests can assert on the reassembled
  /// file.
  final bool retainBytes;

  /// Prefix of the URL reported on completion.
  final String baseUrl;

  final Map<String, _Upload> _uploads = <String, _Upload>{};

  /// Ids of uploads that were finalised.
  Iterable<String> get completedUploads => _uploads.entries
      .where((MapEntry<String, _Upload> e) => e.value.completed)
      .map((MapEntry<String, _Upload> e) => e.key);

  /// The reassembled bytes of [uploadId], when [retainBytes] is on.
  Uint8List? bytesOf(String uploadId) {
    final _Upload? upload = _uploads[uploadId];
    if (upload == null || !upload.retain) return null;
    final BytesBuilder builder = BytesBuilder(copy: false);
    final List<int> indices = upload.chunks.keys.toList()..sort();
    for (final int index in indices) {
      builder.add(upload.chunks[index]!);
    }
    return builder.takeBytes();
  }

  /// How many bytes were accepted for [uploadId].
  int bytesReceived(String uploadId) => _uploads[uploadId]?.received ?? 0;

  /// Forgets everything.
  void reset() => _uploads.clear();

  @override
  Future<UploadSession> initialize(UploadRequest request) async {
    await _wait();
    final _Upload upload = _uploads.putIfAbsent(
      request.uploadId,
      () => _Upload(fileName: request.fileName, retain: retainBytes),
    );
    return UploadSession(
      uploadId: request.uploadId,
      sessionId: 'mem-${request.uploadId}',
      uploadedChunkIndices: Set<int>.of(upload.chunks.keys),
      uploadedBytes: upload.received,
    );
  }

  @override
  Future<ChunkUploadResult> uploadChunk(
    UploadSession session,
    UploadChunk chunk,
  ) async {
    await _wait();
    final _Upload upload = _uploads.putIfAbsent(
      session.uploadId,
      () => _Upload(fileName: session.uploadId, retain: retainBytes),
    );
    upload.accept(chunk);
    return ChunkUploadResult.accepted(chunk, etag: 'mem-${chunk.index}');
  }

  @override
  Future<UploadResult> complete(UploadSession session) async {
    await _wait();
    final _Upload? upload = _uploads[session.uploadId];
    upload?.completed = true;
    return UploadResult(
      uploadId: session.uploadId,
      url: '$baseUrl/${session.uploadId}',
      fileName: upload?.fileName,
      fileSize: upload?.received ?? 0,
      data: <String, Object?>{'sessionId': session.sessionId},
    );
  }

  @override
  Future<void> cancel(UploadSession session) async {
    await _wait();
    _uploads.remove(session.uploadId);
  }

  Future<void> _wait() => latency == Duration.zero
      ? Future<void>.value()
      : Future<void>.delayed(latency);
}

class _Upload {
  _Upload({required this.fileName, required this.retain});

  final String fileName;
  final bool retain;
  final Map<int, Uint8List> chunks = <int, Uint8List>{};
  int received = 0;
  bool completed = false;

  void accept(UploadChunk chunk) {
    // Idempotent: a retried chunk must not be counted twice.
    if (chunks.containsKey(chunk.index)) return;
    chunks[chunk.index] = retain ? chunk.bytes : Uint8List(0);
    received += chunk.size;
  }
}
