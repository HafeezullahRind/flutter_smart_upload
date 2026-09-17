import 'package:meta/meta.dart';

import '../exceptions/upload_exception.dart';
import 'upload_progress.dart';
import 'upload_result.dart';
import 'upload_status.dart';

/// Base class for everything published on `SmartUploader.events`.
///
/// The hierarchy is `sealed`, so a `switch` over an event is exhaustively
/// checked by the compiler:
///
/// ```dart
/// uploader.events.listen((UploadEvent event) {
///   final String line = switch (event) {
///     UploadProgressEvent(:final UploadProgress progress) =>
///       '${progress.percentage.toStringAsFixed(0)}%',
///     UploadCompletedEvent(:final UploadResult result) => 'done ${result.url}',
///     UploadFailedEvent(:final SmartUploadException error) => 'error $error',
///     _ => event.status.name,
///   };
///   print('[${event.uploadId}] $line');
/// });
/// ```
@immutable
sealed class UploadEvent {
  /// Creates an event for [uploadId].
  UploadEvent({required this.uploadId, DateTime? timestamp})
      : timestamp = timestamp ?? DateTime.now();

  /// The upload this event belongs to.
  final String uploadId;

  /// When the event was raised.
  final DateTime timestamp;

  /// The status the task is in as a result of this event.
  UploadStatus get status;

  @override
  String toString() => '$runtimeType($uploadId)';
}

/// The upload was accepted and is waiting for a concurrency slot.
final class UploadQueuedEvent extends UploadEvent {
  /// Creates the event.
  UploadQueuedEvent({
    required super.uploadId,
    required this.fileName,
    required this.fileSize,
    super.timestamp,
  });

  /// Name of the file being uploaded.
  final String fileName;

  /// Size of the file on disk, before compression.
  final int fileSize;

  @override
  UploadStatus get status => UploadStatus.queued;
}

/// The file is being validated, hashed and split into chunks.
final class UploadPreparingEvent extends UploadEvent {
  /// Creates the event.
  UploadPreparingEvent({required super.uploadId, super.timestamp});

  @override
  UploadStatus get status => UploadStatus.preparing;
}

/// The compression pipeline is running.
final class UploadCompressingEvent extends UploadEvent {
  /// Creates the event.
  UploadCompressingEvent({required super.uploadId, super.timestamp});

  @override
  UploadStatus get status => UploadStatus.compressing;
}

/// Compression finished. Reports how much was saved.
final class UploadCompressedEvent extends UploadEvent {
  /// Creates the event.
  UploadCompressedEvent({
    required super.uploadId,
    required this.originalSize,
    required this.compressedSize,
    super.timestamp,
  });

  /// Size before compression, in bytes.
  final int originalSize;

  /// Size after compression, in bytes.
  final int compressedSize;

  /// Fraction of the original size that was saved, `0.0`–`1.0`.
  double get savedFraction =>
      originalSize <= 0 ? 0 : 1 - (compressedSize / originalSize);

  @override
  UploadStatus get status => UploadStatus.compressing;
}

/// The adapter opened a session and the first chunk is about to be sent.
final class UploadStartedEvent extends UploadEvent {
  /// Creates the event.
  UploadStartedEvent({
    required super.uploadId,
    required this.totalBytes,
    required this.totalChunks,
    this.resumed = false,
    super.timestamp,
  });

  /// Bytes that will be transferred.
  final int totalBytes;

  /// Number of chunks the file was split into.
  final int totalChunks;

  /// Whether this run continued a previously persisted upload.
  final bool resumed;

  @override
  UploadStatus get status => UploadStatus.uploading;
}

/// Bytes were acknowledged by the adapter.
final class UploadProgressEvent extends UploadEvent {
  /// Creates the event.
  UploadProgressEvent({
    required super.uploadId,
    required this.progress,
    super.timestamp,
  });

  /// The progress snapshot.
  final UploadProgress progress;

  @override
  UploadStatus get status => UploadStatus.uploading;

  @override
  String toString() => 'UploadProgressEvent($uploadId, $progress)';
}

/// One chunk was stored successfully.
final class UploadChunkCompletedEvent extends UploadEvent {
  /// Creates the event.
  UploadChunkCompletedEvent({
    required super.uploadId,
    required this.chunkIndex,
    required this.totalChunks,
    required this.bytesUploaded,
    super.timestamp,
  });

  /// Index of the stored chunk.
  final int chunkIndex;

  /// Total number of chunks.
  final int totalChunks;

  /// Bytes accepted for this chunk.
  final int bytesUploaded;

  @override
  UploadStatus get status => UploadStatus.uploading;
}

/// The upload was suspended.
final class UploadPausedEvent extends UploadEvent {
  /// Creates the event.
  UploadPausedEvent({
    required super.uploadId,
    this.waitingForNetwork = false,
    super.timestamp,
  });

  /// Whether the pause was caused by the device going offline rather than by
  /// an explicit `pause()` call.
  final bool waitingForNetwork;

  @override
  UploadStatus get status => UploadStatus.paused;
}

/// The upload left the paused state.
final class UploadResumedEvent extends UploadEvent {
  /// Creates the event.
  UploadResumedEvent({required super.uploadId, super.timestamp});

  @override
  UploadStatus get status => UploadStatus.uploading;
}

/// A failed operation is about to be retried.
final class UploadRetryEvent extends UploadEvent {
  /// Creates the event.
  UploadRetryEvent({
    required super.uploadId,
    required this.attempt,
    required this.maxAttempts,
    required this.delay,
    required this.error,
    this.chunkIndex,
    super.timestamp,
  });

  /// 1-based attempt number that is about to run.
  final int attempt;

  /// Total attempts allowed by the retry policy.
  final int maxAttempts;

  /// How long the orchestrator will wait before retrying.
  final Duration delay;

  /// The error that triggered the retry.
  final SmartUploadException error;

  /// Which chunk failed, or `null` for session-level operations.
  final int? chunkIndex;

  @override
  UploadStatus get status => UploadStatus.uploading;
}

/// The upload finished successfully.
final class UploadCompletedEvent extends UploadEvent {
  /// Creates the event.
  UploadCompletedEvent({
    required super.uploadId,
    required this.result,
    super.timestamp,
  });

  /// The adapter's result, enriched with orchestrator timings.
  final UploadResult result;

  @override
  UploadStatus get status => UploadStatus.completed;
}

/// The upload gave up after exhausting retries, or hit a permanent error.
final class UploadFailedEvent extends UploadEvent {
  /// Creates the event.
  UploadFailedEvent({
    required super.uploadId,
    required this.error,
    this.attempts = 1,
    super.timestamp,
  });

  /// Why the upload failed.
  final SmartUploadException error;

  /// How many attempts were made in total.
  final int attempts;

  @override
  UploadStatus get status => UploadStatus.failed;

  @override
  String toString() => 'UploadFailedEvent($uploadId, $error)';
}

/// The upload was cancelled by the caller.
final class UploadCancelledEvent extends UploadEvent {
  /// Creates the event.
  UploadCancelledEvent({required super.uploadId, super.timestamp});

  @override
  UploadStatus get status => UploadStatus.cancelled;
}
