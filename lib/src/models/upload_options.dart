import 'package:meta/meta.dart';

/// How aggressively integrity checksums should be computed.
///
/// Hashing a 500 MB video costs a full extra read of the file, so nothing is
/// hashed unless you ask for it.
enum ChecksumMode {
  /// Never compute a checksum. The default.
  none,

  /// Hash the whole file once, before the transfer starts.
  ///
  /// Also used to detect that a persisted upload still refers to the same
  /// bytes before resuming it.
  file,

  /// Hash each chunk as it is read and hand the digest to the adapter.
  chunk,

  /// Both of the above.
  both;

  /// Whether a whole-file digest is required.
  bool get includesFile => this == file || this == both;

  /// Whether per-chunk digests are required.
  bool get includesChunk => this == chunk || this == both;
}

/// Output container for image re-encoding.
enum ImageOutputFormat {
  /// Keep the source encoding.
  original,

  /// Re-encode as JPEG. Smallest output for photographs.
  jpeg,

  /// Re-encode as PNG. Lossless; ignores `quality`.
  png,

  /// Re-encode as WebP where the compressor supports it.
  webp,
}

/// Per-upload settings: compression, naming, metadata and overrides of the
/// global [SmartUploadConfig].
///
/// ```dart
/// const UploadOptions(
///   compress: true,
///   quality: 80,
///   maxWidth: 1920,
///   maxHeight: 1920,
/// );
/// ```
@immutable
class UploadOptions {
  /// Creates upload options. Every field has a usable default.
  const UploadOptions({
    this.compress = false,
    this.quality = 85,
    this.maxWidth,
    this.maxHeight,
    this.format = ImageOutputFormat.original,
    this.stripMetadata = true,
    this.fileName,
    this.contentType,
    this.metadata = const <String, String>{},
    this.chunkSize,
    this.checksum,
    this.priority = 0,
    this.skipCompressionIfLarger = true,
  })  : assert(quality > 0 && quality <= 100, 'quality must be in 1..100'),
        assert(maxWidth == null || maxWidth > 0, 'maxWidth must be positive'),
        assert(
          maxHeight == null || maxHeight > 0,
          'maxHeight must be positive',
        ),
        assert(chunkSize == null || chunkSize > 0, 'chunkSize must be > 0');

  /// Sensible defaults for photos taken on a phone: 1920px long edge, q80.
  static const UploadOptions image = UploadOptions(
    compress: true,
    quality: 80,
    maxWidth: 1920,
    maxHeight: 1920,
  );

  /// Upload the bytes exactly as they are on disk.
  static const UploadOptions raw = UploadOptions();

  /// Whether to run the compression pipeline before uploading.
  ///
  /// Non-image files pass through untouched even when this is `true` — the
  /// compressor decides what it can handle.
  final bool compress;

  /// Encoder quality in `1..100`. Ignored by lossless formats.
  final int quality;

  /// Maximum output width in pixels. Aspect ratio is preserved.
  final int? maxWidth;

  /// Maximum output height in pixels. Aspect ratio is preserved.
  final int? maxHeight;

  /// Target container for re-encoded images.
  final ImageOutputFormat format;

  /// Drop EXIF/ICC metadata (including GPS coordinates) when re-encoding.
  final bool stripMetadata;

  /// Overrides the name reported to the adapter. Defaults to the basename.
  final String? fileName;

  /// Overrides the guessed MIME type.
  final String? contentType;

  /// Arbitrary key/value pairs forwarded verbatim to the adapter.
  final Map<String, String> metadata;

  /// Overrides [SmartUploadConfig.chunkSize] for this upload only.
  final int? chunkSize;

  /// Overrides [SmartUploadConfig.checksumMode] for this upload only.
  final ChecksumMode? checksum;

  /// Queue priority. Higher values are dequeued first; ties keep FIFO order.
  final int priority;

  /// Fall back to the original bytes when compression made the file bigger.
  final bool skipCompressionIfLarger;

  /// Returns a copy with the given fields replaced.
  UploadOptions copyWith({
    bool? compress,
    int? quality,
    int? maxWidth,
    int? maxHeight,
    ImageOutputFormat? format,
    bool? stripMetadata,
    String? fileName,
    String? contentType,
    Map<String, String>? metadata,
    int? chunkSize,
    ChecksumMode? checksum,
    int? priority,
    bool? skipCompressionIfLarger,
  }) =>
      UploadOptions(
        compress: compress ?? this.compress,
        quality: quality ?? this.quality,
        maxWidth: maxWidth ?? this.maxWidth,
        maxHeight: maxHeight ?? this.maxHeight,
        format: format ?? this.format,
        stripMetadata: stripMetadata ?? this.stripMetadata,
        fileName: fileName ?? this.fileName,
        contentType: contentType ?? this.contentType,
        metadata: metadata ?? this.metadata,
        chunkSize: chunkSize ?? this.chunkSize,
        checksum: checksum ?? this.checksum,
        priority: priority ?? this.priority,
        skipCompressionIfLarger:
            skipCompressionIfLarger ?? this.skipCompressionIfLarger,
      );

  /// Serialises the options so an upload can be resumed in a later process.
  Map<String, Object?> toJson() => <String, Object?>{
        'compress': compress,
        'quality': quality,
        'maxWidth': maxWidth,
        'maxHeight': maxHeight,
        'format': format.name,
        'stripMetadata': stripMetadata,
        'fileName': fileName,
        'contentType': contentType,
        'metadata': metadata,
        'chunkSize': chunkSize,
        'checksum': checksum?.name,
        'priority': priority,
        'skipCompressionIfLarger': skipCompressionIfLarger,
      };

  /// Restores options produced by [toJson].
  static UploadOptions fromJson(Map<String, Object?> json) => UploadOptions(
        compress: (json['compress'] as bool?) ?? false,
        quality: (json['quality'] as int?) ?? 85,
        maxWidth: json['maxWidth'] as int?,
        maxHeight: json['maxHeight'] as int?,
        format: ImageOutputFormat.values.firstWhere(
          (ImageOutputFormat f) => f.name == json['format'],
          orElse: () => ImageOutputFormat.original,
        ),
        stripMetadata: (json['stripMetadata'] as bool?) ?? true,
        fileName: json['fileName'] as String?,
        contentType: json['contentType'] as String?,
        metadata: <String, String>{
          ...?(json['metadata'] as Map<Object?, Object?>?)?.map(
            (Object? k, Object? v) =>
                MapEntry<String, String>(k! as String, v! as String),
          ),
        },
        chunkSize: json['chunkSize'] as int?,
        checksum: json['checksum'] == null
            ? null
            : ChecksumMode.values.firstWhere(
                (ChecksumMode m) => m.name == json['checksum'],
                orElse: () => ChecksumMode.none,
              ),
        priority: (json['priority'] as int?) ?? 0,
        skipCompressionIfLarger:
            (json['skipCompressionIfLarger'] as bool?) ?? true,
      );

  @override
  String toString() => 'UploadOptions(compress: $compress, quality: $quality, '
      'maxWidth: $maxWidth, maxHeight: $maxHeight, priority: $priority)';
}
