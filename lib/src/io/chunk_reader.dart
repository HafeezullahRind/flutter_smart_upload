import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../exceptions/upload_exception.dart';
import '../models/upload_chunk.dart';

/// Reads a file one chunk at a time through a single [RandomAccessFile].
///
/// This is the memory-efficiency core of the package. The file handle stays
/// open for the duration of the upload and each [read] seeks and pulls exactly
/// one chunk, so peak heap is one chunk regardless of file size — as opposed to
/// `file.readAsBytes()`, which would need the whole file resident.
///
/// Reading out of order is supported (seek-based), which is what makes
/// resuming from an arbitrary chunk cheap.
class ChunkReader {
  ChunkReader._(this._handle, this.file, this.fileSize, this.chunkSize);

  /// Opens [file] for chunked reading.
  ///
  /// Throws [SmartUploadException] with [UploadErrorCode.fileNotFound] if the
  /// file is missing, or [UploadErrorCode.invalidFile] if it is empty.
  static Future<ChunkReader> open(File file, {required int chunkSize}) async {
    if (chunkSize <= 0) {
      throw SmartUploadException(
        'chunkSize must be greater than zero, got $chunkSize',
        errorCode: UploadErrorCode.invalidRequest,
      );
    }
    if (!file.existsSync()) {
      throw SmartUploadException.fileNotFound(file.path);
    }
    final int size = await file.length();
    if (size <= 0) {
      throw SmartUploadException.invalidFile('File is empty: ${file.path}');
    }
    try {
      final RandomAccessFile handle = await file.open();
      return ChunkReader._(handle, file, size, chunkSize);
    } on FileSystemException catch (e, s) {
      throw SmartUploadException(
        'Cannot open ${file.path}: ${e.message}',
        errorCode: UploadErrorCode.invalidFile,
        cause: e,
        stackTrace: s,
      );
    }
  }

  final RandomAccessFile _handle;
  bool _closed = false;

  /// The file being read.
  final File file;

  /// Total size of [file] in bytes.
  final int fileSize;

  /// Size of every chunk except (possibly) the last.
  final int chunkSize;

  /// Number of chunks [file] is split into. Always at least 1.
  int get totalChunks => math.max(1, (fileSize + chunkSize - 1) ~/ chunkSize);

  /// Byte offset at which chunk [index] starts.
  int startOf(int index) => index * chunkSize;

  /// Number of bytes in chunk [index].
  int sizeOf(int index) =>
      math.min(chunkSize, fileSize - startOf(index)).clamp(0, chunkSize);

  /// Reads chunk [index].
  ///
  /// The returned [UploadChunk] is the only copy of those bytes; drop the
  /// reference as soon as the adapter has consumed it.
  Future<UploadChunk> read(int index) async {
    if (_closed) {
      throw SmartUploadException(
        'ChunkReader for ${file.path} is already closed',
        errorCode: UploadErrorCode.invalidRequest,
      );
    }
    if (index < 0 || index >= totalChunks) {
      throw SmartUploadException(
        'Chunk index $index out of range (0..${totalChunks - 1})',
        errorCode: UploadErrorCode.invalidRequest,
      );
    }
    final int start = startOf(index);
    final int length = sizeOf(index);
    try {
      await _handle.setPosition(start);
      final Uint8List bytes = await _handle.read(length);
      if (bytes.length != length) {
        throw SmartUploadException(
          'Short read for chunk $index: expected $length bytes, '
          'got ${bytes.length}. The file changed while uploading.',
          errorCode: UploadErrorCode.invalidFile,
        );
      }
      return UploadChunk(
        index: index,
        totalChunks: totalChunks,
        start: start,
        bytes: bytes,
      );
    } on FileSystemException catch (e, s) {
      throw SmartUploadException(
        'Failed reading chunk $index of ${file.path}: ${e.message}',
        errorCode: UploadErrorCode.invalidFile,
        cause: e,
        stackTrace: s,
      );
    }
  }

  /// Lazily yields chunks from [from] (inclusive) to the end of the file.
  ///
  /// Each chunk is read only when the consumer asks for it, so a `await for`
  /// over this stream never holds more than one chunk.
  Stream<UploadChunk> readFrom(int from) async* {
    for (int i = from; i < totalChunks; i++) {
      yield await read(i);
    }
  }

  /// Releases the file handle. Safe to call more than once.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _handle.close();
    } on FileSystemException {
      // Nothing useful to do if the handle is already gone.
    }
  }
}
