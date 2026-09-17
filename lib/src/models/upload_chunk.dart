import 'dart:typed_data';

import 'package:meta/meta.dart';

/// A single slice of the source file, already read into memory.
///
/// Exactly one chunk per in-flight upload is resident at a time: the
/// orchestrator reads a chunk, hands it to the adapter, and drops the
/// reference before reading the next one. With the default 2 MB chunk size and
/// two concurrent uploads the transfer path costs ~4 MB of heap regardless of
/// whether the file is 3 MB or 3 GB.
@immutable
class UploadChunk {
  /// Creates a chunk.
  const UploadChunk({
    required this.index,
    required this.totalChunks,
    required this.start,
    required this.bytes,
    this.checksum,
  });

  /// Zero-based position of this chunk in the file.
  final int index;

  /// Total number of chunks in the file.
  final int totalChunks;

  /// Byte offset of this chunk within the file.
  final int start;

  /// The chunk payload.
  final Uint8List bytes;

  /// Digest of [bytes], when per-chunk checksums are enabled.
  final String? checksum;

  /// Number of bytes in this chunk.
  int get size => bytes.length;

  /// Exclusive end offset of this chunk within the file.
  int get end => start + size;

  /// Whether this is the final chunk.
  bool get isLast => index == totalChunks - 1;

  /// Whether this is the only chunk (the file fits in one request).
  bool get isOnly => totalChunks == 1;

  /// A `bytes=start-end` value for HTTP `Content-Range` headers.
  ///
  /// The caller still needs the total size, e.g.
  /// `'bytes ${chunk.byteRange}/${request.fileSize}'`.
  String get byteRange => '$start-${end - 1}';

  /// Returns a copy of this chunk tagged with [checksum].
  UploadChunk withChecksum(String checksum) => UploadChunk(
        index: index,
        totalChunks: totalChunks,
        start: start,
        bytes: bytes,
        checksum: checksum,
      );

  /// Wraps [bytes] in a single-event stream for streaming HTTP clients.
  Stream<List<int>> asStream() => Stream<List<int>>.value(bytes);

  @override
  String toString() =>
      'UploadChunk(${index + 1}/$totalChunks, $size bytes @ $start)';
}
