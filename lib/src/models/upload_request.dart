import 'dart:io';

import 'package:meta/meta.dart';

import 'upload_options.dart';

/// Everything an [UploadAdapter] needs to open a server-side session.
///
/// Instances are created by the orchestrator after the file has been validated
/// and (optionally) compressed, so [file] and [fileSize] always describe the
/// bytes that are actually going to be sent.
@immutable
class UploadRequest {
  /// Creates an upload request.
  const UploadRequest({
    required this.uploadId,
    required this.file,
    required this.fileName,
    required this.fileSize,
    required this.contentType,
    required this.chunkSize,
    required this.totalChunks,
    this.checksum,
    this.metadata = const <String, String>{},
    this.options = const UploadOptions(),
  });

  /// Client-generated identifier, stable across resumes.
  final String uploadId;

  /// The file that will be read. May be a compressed temporary copy.
  final File file;

  /// Name to report to the server.
  final String fileName;

  /// Size of [file] in bytes.
  final int fileSize;

  /// MIME type, e.g. `image/jpeg`. Falls back to
  /// `application/octet-stream`.
  final String contentType;

  /// Size of each chunk except possibly the last.
  final int chunkSize;

  /// Number of chunks the file was split into. At least 1.
  final int totalChunks;

  /// Whole-file digest, when [ChecksumMode.includesFile] was requested.
  final String? checksum;

  /// Caller-supplied metadata, forwarded verbatim.
  final Map<String, String> metadata;

  /// The options this upload was started with.
  final UploadOptions options;

  /// Whether the transfer will be split across more than one chunk.
  bool get isChunked => totalChunks > 1;

  @override
  String toString() => 'UploadRequest($uploadId, $fileName, $fileSize bytes, '
      '$totalChunks chunks)';
}
