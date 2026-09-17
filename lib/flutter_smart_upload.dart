/// Backend-agnostic, memory-efficient file uploads for Flutter.
///
/// `flutter_smart_upload` orchestrates uploads — chunking, retries, pause and
/// resume, a concurrency-limited queue, progress, compression and persistence
/// — and delegates the actual transport to an [UploadAdapter] you implement
/// for your backend. It is not an HTTP client and has no opinion about your
/// server.
///
/// ```dart
/// final SmartUploader uploader = SmartUploader(
///   adapter: MyApiUploadAdapter(),
///   config: SmartUploadConfig(
///     chunkSize: 2 * 1024 * 1024,
///     maxConcurrentUploads: 2,
///     maxRetries: 3,
///   ),
/// );
///
/// final UploadTask task = await uploader.upload(
///   file: File('/path/to/image.jpg'),
///   options: const UploadOptions(compress: true, quality: 80),
///   onProgress: (UploadProgress p) => print('${p.percentage}%'),
/// );
///
/// final UploadResult result = await task.done;
/// print(result.url);
/// ```
library;

export 'src/adapters/in_memory_upload_adapter.dart';
export 'src/adapters/upload_adapter.dart';
export 'src/checksum/checksum_provider.dart';
export 'src/compression/compressor.dart';
export 'src/compression/image_compressor.dart';
export 'src/core/smart_upload_config.dart';
export 'src/core/smart_uploader.dart';
export 'src/core/upload_task.dart'
    show ProgressCallback, StatusCallback, UploadTask;
export 'src/exceptions/upload_exception.dart';
export 'src/models/chunk_upload_result.dart';
export 'src/models/upload_chunk.dart';
export 'src/models/upload_event.dart';
export 'src/models/upload_options.dart';
export 'src/models/upload_progress.dart';
export 'src/models/upload_request.dart';
export 'src/models/upload_result.dart';
export 'src/models/upload_session.dart';
export 'src/models/upload_status.dart';
export 'src/network/network_monitor.dart';
export 'src/persistence/file_upload_storage.dart';
export 'src/persistence/memory_upload_storage.dart';
export 'src/persistence/upload_record.dart';
export 'src/persistence/upload_storage.dart';
export 'src/retry/retry_policy.dart';
