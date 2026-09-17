import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../exceptions/upload_exception.dart';
import '../models/upload_options.dart';
import '../util/mime_types.dart';
import 'compressor.dart';

/// Resizes and re-encodes images before upload, in a background isolate.
///
/// A 4 MB 12-megapixel phone photo typically leaves this at 300–600 KB with
/// `quality: 80` and a 1920 px long edge — an order of magnitude less to
/// transfer, which matters far more than upload throughput on a mobile
/// connection.
///
/// ### Memory
///
/// Decoding is inherently allocation-heavy: an image costs `width * height * 4`
/// bytes once decoded, whatever its compressed size. Three things keep that
/// from hurting:
///
/// 1. **It happens in a separate isolate.** The decode heap is created and
///    destroyed with the isolate, so it never fragments or grows your app's
///    heap, and the UI thread keeps rendering.
/// 2. **Dimensions are read before pixels.** The header is parsed first, and
///    anything above [maxDecodePixels] is passed through untouched instead of
///    risking an out-of-memory kill on a low-end device.
/// 3. **Only paths cross the isolate boundary.** The source is read and the
///    result is written inside the isolate; no large buffer is ever copied
///    between isolates.
///
/// For very large images, or for the tightest memory budget on low-end
/// Android, plug in a platform-native compressor instead — [Compressor] exists
/// precisely so that swap is a one-line change.
///
/// ```dart
/// SmartUploadConfig(compressor: const ImageCompressor());
/// ```
class ImageCompressor extends Compressor {
  /// Creates an image compressor.
  const ImageCompressor({
    this.maxDecodePixels = 24000000,
    this.maxSourceBytes = 64 * 1024 * 1024,
    this.compressAnimated = false,
    this.highQualityResize = true,
    this.runInIsolate = true,
  });

  /// Images with more pixels than this are left alone.
  ///
  /// The default, 24 MP, corresponds to roughly 96 MB of decoded pixels —
  /// about as much as is safe to ask of a budget Android device.
  final int maxDecodePixels;

  /// Files larger than this are left alone.
  final int maxSourceBytes;

  /// Whether to touch animated formats (GIF). Off by default: re-encoding
  /// would flatten the animation to a single frame.
  final bool compressAnimated;

  /// Use averaged sampling when downscaling. Slightly slower, markedly better
  /// looking than nearest-neighbour.
  final bool highQualityResize;

  /// Run the work in a background isolate. Leave this on outside of tests.
  final bool runInIsolate;

  static const Set<String> _supported = <String>{
    'image/jpeg',
    'image/png',
    'image/bmp',
    'image/tiff',
    'image/gif',
  };

  @override
  bool canCompress(File file, String contentType, UploadOptions options) {
    if (!options.compress) return false;
    if (!isImageContentType(contentType)) return false;
    if (!_supported.contains(contentType)) return false;
    if (contentType == 'image/gif' && !compressAnimated) return false;
    final int length = file.existsSync() ? file.lengthSync() : 0;
    return length > 0 && length <= maxSourceBytes;
  }

  @override
  Future<CompressionResult> compress({
    required File file,
    required UploadOptions options,
    required String contentType,
    required Directory workDirectory,
  }) async {
    final int originalSize = await file.length();
    final _Job job = _Job(
      sourcePath: file.path,
      targetPath: p.join(
        workDirectory.path,
        '${p.basenameWithoutExtension(file.path)}_'
        '${DateTime.now().microsecondsSinceEpoch}'
        '${_extensionFor(options.format, contentType)}',
      ),
      quality: options.quality,
      maxWidth: options.maxWidth,
      maxHeight: options.maxHeight,
      format: _resolveFormat(options.format, contentType),
      stripMetadata: options.stripMetadata,
      maxDecodePixels: maxDecodePixels,
      highQualityResize: highQualityResize,
    );

    final _Outcome? outcome;
    try {
      outcome = runInIsolate
          ? await Isolate.run(() => _compressSync(job))
          : _compressSync(job);
    } catch (e, s) {
      throw SmartUploadException(
        'Image compression failed for ${file.path}: $e',
        errorCode: UploadErrorCode.compressionFailed,
        cause: e,
        stackTrace: s,
      );
    }

    if (outcome == null) {
      // Unsupported, too large, or not worth it: upload the original.
      return CompressionResult.unchanged(file, originalSize, contentType);
    }

    return CompressionResult(
      file: File(outcome.path),
      originalSize: originalSize,
      compressedSize: outcome.size,
      contentType: outcome.contentType,
      didCompress: true,
      isTemporary: true,
      width: outcome.width,
      height: outcome.height,
    );
  }

  /// Picks the effective output format, since not every container has an
  /// encoder.
  static _Format _resolveFormat(ImageOutputFormat requested, String source) {
    switch (requested) {
      case ImageOutputFormat.jpeg:
        return _Format.jpeg;
      case ImageOutputFormat.png:
        return _Format.png;
      case ImageOutputFormat.webp:
        // The pure-Dart `image` package can decode WebP but not encode it.
        return _Format.jpeg;
      case ImageOutputFormat.original:
        // Keep PNG lossless (it is usually chosen for transparency or line
        // art); everything else is best served as JPEG.
        return source == 'image/png' ? _Format.png : _Format.jpeg;
    }
  }

  static String _extensionFor(ImageOutputFormat requested, String source) =>
      _resolveFormat(requested, source) == _Format.png ? '.png' : '.jpg';
}

enum _Format { jpeg, png }

/// Everything the isolate needs. Primitives only, so it copies cheaply.
class _Job {
  const _Job({
    required this.sourcePath,
    required this.targetPath,
    required this.quality,
    required this.maxWidth,
    required this.maxHeight,
    required this.format,
    required this.stripMetadata,
    required this.maxDecodePixels,
    required this.highQualityResize,
  });

  final String sourcePath;
  final String targetPath;
  final int quality;
  final int? maxWidth;
  final int? maxHeight;
  final _Format format;
  final bool stripMetadata;
  final int maxDecodePixels;
  final bool highQualityResize;
}

/// What came back out. Small enough that copying it is free.
class _Outcome {
  const _Outcome({
    required this.path,
    required this.size,
    required this.width,
    required this.height,
    required this.contentType,
  });

  final String path;
  final int size;
  final int width;
  final int height;
  final String contentType;
}

/// The actual work. Runs inside the isolate; returns `null` to mean "leave the
/// original alone".
_Outcome? _compressSync(_Job job) {
  final File source = File(job.sourcePath);
  final Uint8List bytes = source.readAsBytesSync();

  final img.Decoder? decoder = img.findDecoderForData(bytes);
  if (decoder == null) return null;

  // Parse the header first: dimensions are known long before any pixel is
  // allocated, which is what makes the guard below possible.
  final img.DecodeInfo? info = decoder.startDecode(bytes);
  if (info == null) return null;
  if (info.width <= 0 || info.height <= 0) return null;
  if (info.width * info.height > job.maxDecodePixels) return null;

  img.Image? image = decoder.decode(bytes);
  if (image == null) return null;

  final _Size? target = _fit(
    image.width,
    image.height,
    job.maxWidth,
    job.maxHeight,
  );
  if (target != null) {
    image = img.copyResize(
      image,
      width: target.width,
      height: target.height,
      interpolation: job.highQualityResize
          ? img.Interpolation.average
          : img.Interpolation.nearest,
    );
  }

  if (job.stripMetadata) {
    // Drops EXIF — including GPS coordinates, which users rarely intend to
    // publish — and the colour profile.
    image.exif = img.ExifData();
    image.iccProfile = null;
  }

  final Uint8List encoded = switch (job.format) {
    _Format.png => img.encodePng(image, level: 6),
    _Format.jpeg => img.encodeJpg(
        image,
        quality: job.quality,
        // 4:2:0 chroma subsampling halves the chroma planes; invisible on
        // photographs below ~q90 and a solid size win.
        chroma:
            job.quality < 90 ? img.JpegChroma.yuv420 : img.JpegChroma.yuv444,
      ),
  };

  final File target_ = File(job.targetPath)..writeAsBytesSync(encoded);
  return _Outcome(
    path: target_.path,
    size: encoded.length,
    width: image.width,
    height: image.height,
    contentType: job.format == _Format.png ? 'image/png' : 'image/jpeg',
  );
}

class _Size {
  const _Size(this.width, this.height);

  final int width;
  final int height;
}

/// Scales `width x height` down to fit the bounds, preserving aspect ratio.
///
/// Returns `null` when the image already fits, so no resize is attempted.
_Size? _fit(int width, int height, int? maxWidth, int? maxHeight) {
  if (maxWidth == null && maxHeight == null) return null;
  final double widthScale = maxWidth == null ? 1 : maxWidth / width;
  final double heightScale = maxHeight == null ? 1 : maxHeight / height;
  final double scale = widthScale < heightScale ? widthScale : heightScale;
  if (scale >= 1) return null;
  return _Size(
    (width * scale).round().clamp(1, width),
    (height * scale).round().clamp(1, height),
  );
}
