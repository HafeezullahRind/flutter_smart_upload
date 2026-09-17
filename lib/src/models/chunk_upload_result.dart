import 'package:meta/meta.dart';

import 'upload_chunk.dart';
import 'upload_session.dart';

/// What an adapter reports back after storing one chunk.
///
/// Failures are signalled by throwing (ideally a [SmartUploadException] with a
/// meaningful code) rather than by returning a "failed" result, so that the
/// retry policy sees a real error to classify.
@immutable
class ChunkUploadResult {
  /// Creates a chunk result.
  const ChunkUploadResult({
    required this.index,
    required this.bytesUploaded,
    this.etag,
    this.session,
    this.data = const <String, Object?>{},
  });

  /// Convenience constructor for adapters that accepted the whole chunk.
  ChunkUploadResult.accepted(UploadChunk chunk, {this.etag, this.session})
      : index = chunk.index,
        bytesUploaded = chunk.size,
        data = const <String, Object?>{};

  /// The chunk index this result refers to.
  final int index;

  /// How many bytes the server accepted. Usually `chunk.size`.
  final int bytesUploaded;

  /// Server-provided entity tag, if the protocol uses one.
  final String? etag;

  /// An updated session to use for subsequent calls.
  ///
  /// Return this when the server hands back new state — a rotated token, a
  /// part list, a moved upload URL — and the orchestrator will adopt and
  /// persist it.
  final UploadSession? session;

  /// Free-form extra data from the adapter.
  final Map<String, Object?> data;

  @override
  String toString() =>
      'ChunkUploadResult(index: $index, bytes: $bytesUploaded)';
}
