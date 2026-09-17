import 'package:meta/meta.dart';

/// A point-in-time snapshot of an upload's transfer progress.
///
/// Byte counts reflect bytes actually acknowledged by the adapter, not the
/// number of chunks completed, so progress advances smoothly for files whose
/// last chunk is short.
@immutable
class UploadProgress {
  /// Creates a progress snapshot.
  const UploadProgress({
    required this.uploadedBytes,
    required this.totalBytes,
    required this.elapsed,
    this.estimatedRemaining,
    this.bytesPerSecond = 0,
  });

  /// A zero-progress snapshot for a file of [totalBytes].
  const UploadProgress.initial(int totalBytes)
      : this(
          uploadedBytes: 0,
          totalBytes: totalBytes,
          elapsed: Duration.zero,
        );

  /// Bytes confirmed as transferred.
  final int uploadedBytes;

  /// Total bytes to transfer (post-compression, when compression is enabled).
  final int totalBytes;

  /// Wall-clock time spent transferring, excluding paused periods.
  final Duration elapsed;

  /// Projected time to completion, or `null` while the rate is unknown.
  final Duration? estimatedRemaining;

  /// Smoothed transfer rate in bytes per second.
  final double bytesPerSecond;

  /// Completion in the range `0.0`–`100.0`.
  double get percentage =>
      totalBytes <= 0 ? 0 : (uploadedBytes / totalBytes) * 100;

  /// Completion in the range `0.0`–`1.0`, convenient for progress widgets.
  double get fraction => totalBytes <= 0 ? 0 : uploadedBytes / totalBytes;

  /// Bytes still to be transferred.
  int get remainingBytes =>
      totalBytes - uploadedBytes < 0 ? 0 : totalBytes - uploadedBytes;

  /// Whether every byte has been acknowledged.
  bool get isComplete => totalBytes > 0 && uploadedBytes >= totalBytes;

  /// Returns a copy with the given fields replaced.
  UploadProgress copyWith({
    int? uploadedBytes,
    int? totalBytes,
    Duration? elapsed,
    Duration? estimatedRemaining,
    double? bytesPerSecond,
  }) =>
      UploadProgress(
        uploadedBytes: uploadedBytes ?? this.uploadedBytes,
        totalBytes: totalBytes ?? this.totalBytes,
        elapsed: elapsed ?? this.elapsed,
        estimatedRemaining: estimatedRemaining ?? this.estimatedRemaining,
        bytesPerSecond: bytesPerSecond ?? this.bytesPerSecond,
      );

  @override
  String toString() => 'UploadProgress(${percentage.toStringAsFixed(1)}%, '
      '$uploadedBytes/$totalBytes bytes, '
      '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UploadProgress &&
          other.uploadedBytes == uploadedBytes &&
          other.totalBytes == totalBytes &&
          other.elapsed == elapsed &&
          other.estimatedRemaining == estimatedRemaining &&
          other.bytesPerSecond == bytesPerSecond;

  @override
  int get hashCode => Object.hash(
        uploadedBytes,
        totalBytes,
        elapsed,
        estimatedRemaining,
        bytesPerSecond,
      );
}
