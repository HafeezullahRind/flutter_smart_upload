import 'package:meta/meta.dart';

/// The outcome of a successful upload, returned by `UploadAdapter.complete`
/// and surfaced on `UploadTask.done`.
@immutable
class UploadResult {
  /// Creates an upload result.
  const UploadResult({
    required this.uploadId,
    this.url,
    this.fileName,
    this.fileSize = 0,
    this.bytesUploaded = 0,
    this.duration = Duration.zero,
    this.checksum,
    this.data = const <String, Object?>{},
  });

  /// The client-side upload identifier.
  final String uploadId;

  /// Where the stored object can be fetched from, when the backend says so.
  final String? url;

  /// The name the file was stored under.
  final String? fileName;

  /// Size of the uploaded (possibly compressed) payload.
  final int fileSize;

  /// Bytes actually pushed over the wire, excluding bytes skipped on resume.
  final int bytesUploaded;

  /// How long the transfer took, excluding paused time.
  final Duration duration;

  /// Whole-file digest, when one was computed.
  final String? checksum;

  /// Anything else the backend returned (keys, ids, CDN paths...).
  final Map<String, Object?> data;

  /// Returns a copy with orchestrator-owned fields filled in.
  UploadResult copyWith({
    String? url,
    String? fileName,
    int? fileSize,
    int? bytesUploaded,
    Duration? duration,
    String? checksum,
    Map<String, Object?>? data,
  }) =>
      UploadResult(
        uploadId: uploadId,
        url: url ?? this.url,
        fileName: fileName ?? this.fileName,
        fileSize: fileSize ?? this.fileSize,
        bytesUploaded: bytesUploaded ?? this.bytesUploaded,
        duration: duration ?? this.duration,
        checksum: checksum ?? this.checksum,
        data: data ?? this.data,
      );

  @override
  String toString() => 'UploadResult($uploadId, url: $url, $fileSize bytes in '
      '${duration.inMilliseconds}ms)';
}
