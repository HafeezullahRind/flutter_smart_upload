import 'dart:io';

import 'package:meta/meta.dart';

import '../models/upload_options.dart';

/// What a [Compressor] produced.
@immutable
class CompressionResult {
  /// Creates a compression result.
  const CompressionResult({
    required this.file,
    required this.originalSize,
    required this.compressedSize,
    required this.contentType,
    this.didCompress = false,
    this.isTemporary = false,
    this.width,
    this.height,
  });

  /// The input was returned unchanged.
  CompressionResult.unchanged(File file, int size, String contentType)
      : this(
          file: file,
          originalSize: size,
          compressedSize: size,
          contentType: contentType,
        );

  /// The file to upload. Either the original or a temporary compressed copy.
  final File file;

  /// Size of the input in bytes.
  final int originalSize;

  /// Size of [file] in bytes.
  final int compressedSize;

  /// MIME type of [file], which can differ from the input after a format
  /// conversion.
  final String contentType;

  /// Whether [file] differs from the input.
  final bool didCompress;

  /// Whether [file] is a temporary artefact the orchestrator must delete once
  /// the upload finishes.
  final bool isTemporary;

  /// Output width in pixels, for images.
  final int? width;

  /// Output height in pixels, for images.
  final int? height;

  /// Fraction of the original size that was saved, `0.0`–`1.0`.
  double get savedFraction =>
      originalSize <= 0 ? 0 : 1 - (compressedSize / originalSize);

  @override
  String toString() => 'CompressionResult(${file.path}, '
      '$originalSize -> $compressedSize bytes, didCompress: $didCompress)';
}

/// Transforms a file before it is uploaded.
///
/// Compression is deliberately a separate, replaceable stage: the orchestrator
/// only knows that it hands a file in and gets a file back. That lets you swap
/// the bundled pure-Dart image compressor for a platform-native one (which is
/// considerably faster and lighter on low-end Android devices) without
/// touching upload logic.
///
/// ```dart
/// class NativeImageCompressor implements Compressor {
///   @override
///   bool canCompress(File file, String contentType, UploadOptions options) =>
///       options.compress && contentType.startsWith('image/');
///
///   @override
///   Future<CompressionResult> compress({
///     required File file,
///     required UploadOptions options,
///     required String contentType,
///     required Directory workDirectory,
///   }) async {
///     final File out = File('${workDirectory.path}/${file.hashCode}.jpg');
///     await FlutterImageCompress.compressAndGetFile(file.path, out.path);
///     return CompressionResult(
///       file: out,
///       originalSize: await file.length(),
///       compressedSize: await out.length(),
///       contentType: 'image/jpeg',
///       didCompress: true,
///       isTemporary: true,
///     );
///   }
/// }
/// ```
abstract class Compressor {
  /// Const constructor so compressors can be const.
  const Compressor();

  /// Whether this compressor can do anything useful with the given input.
  ///
  /// Returning `false` skips the compressing stage entirely — no temp file, no
  /// isolate, no extra read.
  bool canCompress(File file, String contentType, UploadOptions options);

  /// Produces the bytes to upload.
  ///
  /// Write temporary output into [workDirectory] and set
  /// [CompressionResult.isTemporary] so the orchestrator cleans it up.
  Future<CompressionResult> compress({
    required File file,
    required UploadOptions options,
    required String contentType,
    required Directory workDirectory,
  });
}

/// A compressor that never changes anything. The default.
class NoopCompressor extends Compressor {
  /// Creates the compressor.
  const NoopCompressor();

  @override
  bool canCompress(File file, String contentType, UploadOptions options) =>
      false;

  @override
  Future<CompressionResult> compress({
    required File file,
    required UploadOptions options,
    required String contentType,
    required Directory workDirectory,
  }) async =>
      CompressionResult.unchanged(file, await file.length(), contentType);
}
