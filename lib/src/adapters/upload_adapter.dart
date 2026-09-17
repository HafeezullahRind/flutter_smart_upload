import '../exceptions/upload_exception.dart';
import '../models/chunk_upload_result.dart';
import '../models/upload_chunk.dart';
import '../models/upload_request.dart';
import '../models/upload_result.dart';
import '../models/upload_session.dart';

/// The seam between this package and your backend.
///
/// `flutter_smart_upload` never performs a network call itself: it plans
/// chunks, tracks progress, retries, persists state and enforces concurrency,
/// then delegates every byte to an adapter. Implement this interface once per
/// backend protocol (your REST API, S3 multipart, tus, GCS resumable, ...).
///
/// ### Contract
///
/// * [initialize] is called once per attempt, before any chunk is sent. It may
///   report chunks the server already holds via
///   [UploadSession.uploadedChunkIndices] so a resumed upload skips them.
/// * [uploadChunk] is called for every chunk not already stored, in ascending
///   index order. It must be idempotent: a retried chunk may arrive twice.
/// * [complete] is called once after the final chunk is acknowledged.
/// * [cancel] is called when the caller cancels, and must release any
///   server-side resources. It must not throw.
///
/// Signal failures by throwing a [SmartUploadException] with an accurate
/// [UploadErrorCode] — that is what the retry policy classifies. Throwing a
/// plain error is fine too; it is wrapped as a retryable
/// [UploadErrorCode.chunkUploadFailed] or, for session calls, as
/// [UploadErrorCode.unknown].
///
/// ### Minimal example
///
/// ```dart
/// class MyApiUploadAdapter implements UploadAdapter {
///   MyApiUploadAdapter(this._client);
///   final http.Client _client;
///
///   @override
///   Future<UploadSession> initialize(UploadRequest request) async {
///     final http.Response res = await _client.post(
///       Uri.parse('https://api.example.com/uploads'),
///       body: jsonEncode(<String, Object?>{
///         'name': request.fileName,
///         'size': request.fileSize,
///         'chunks': request.totalChunks,
///       }),
///     );
///     if (res.statusCode == 401) {
///       throw SmartUploadException.authentication('Token rejected');
///     }
///     final Map<String, Object?> body =
///         jsonDecode(res.body) as Map<String, Object?>;
///     return UploadSession(
///       uploadId: request.uploadId,
///       sessionId: body['id']! as String,
///       uploadedChunkIndices: <int>{
///         ...?(body['received'] as List<Object?>?)?.cast<int>(),
///       },
///     );
///   }
///
///   @override
///   Future<ChunkUploadResult> uploadChunk(
///     UploadSession session,
///     UploadChunk chunk,
///   ) async {
///     final http.Response res = await _client.put(
///       Uri.parse('https://api.example.com/uploads/${session.sessionId}'
///           '/parts/${chunk.index}'),
///       body: chunk.bytes,
///     );
///     if (res.statusCode >= 500) {
///       throw SmartUploadException.server('HTTP ${res.statusCode}');
///     }
///     return ChunkUploadResult.accepted(chunk, etag: res.headers['etag']);
///   }
///
///   @override
///   Future<UploadResult> complete(UploadSession session) async {
///     final http.Response res = await _client.post(Uri.parse(
///         'https://api.example.com/uploads/${session.sessionId}/complete'));
///     final Map<String, Object?> body =
///         jsonDecode(res.body) as Map<String, Object?>;
///     return UploadResult(
///       uploadId: session.uploadId,
///       url: body['url'] as String?,
///     );
///   }
///
///   @override
///   Future<void> cancel(UploadSession session) async {
///     await _client.delete(Uri.parse(
///         'https://api.example.com/uploads/${session.sessionId}'));
///   }
/// }
/// ```
abstract class UploadAdapter {
  /// Const constructor so adapters can be const.
  const UploadAdapter();

  /// Opens a server-side session for [request].
  ///
  /// Called once per upload attempt, including after a resume. Return the
  /// chunks already stored in [UploadSession.uploadedChunkIndices] to let the
  /// orchestrator skip them.
  Future<UploadSession> initialize(UploadRequest request);

  /// Sends one [chunk].
  ///
  /// Must be idempotent — retries and resumes can deliver the same chunk more
  /// than once.
  Future<ChunkUploadResult> uploadChunk(
    UploadSession session,
    UploadChunk chunk,
  );

  /// Finalises the upload after every chunk has been acknowledged.
  Future<UploadResult> complete(UploadSession session);

  /// Aborts the upload and releases server-side resources.
  ///
  /// Implementations should swallow their own errors; a failure to clean up
  /// must not mask the cancellation.
  Future<void> cancel(UploadSession session);

  /// Revalidates a persisted [session] before an upload is resumed.
  ///
  /// The default implementation trusts the persisted state. Override it to ask
  /// the server what it actually holds — that is always more reliable than the
  /// local record, which can be stale if the process died mid-request.
  ///
  /// Throw [SmartUploadException] with [UploadErrorCode.resumeFailed] when the
  /// session is gone; the orchestrator then restarts the upload from scratch.
  Future<UploadSession> restore(UploadSession session) async => session;

  /// Classifies an [error] the adapter itself threw.
  ///
  /// The default honours [SmartUploadException.isRetryable] and treats
  /// anything else as retryable, on the assumption that unknown failures from
  /// a network call are usually transient. Override for protocol-specific
  /// rules.
  bool isRetryable(Object error) =>
      error is SmartUploadException ? error.isRetryable : true;
}
