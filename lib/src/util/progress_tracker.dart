import 'dart:math' as math;

import '../models/upload_progress.dart';

/// Turns raw "n more bytes were accepted" notifications into [UploadProgress]
/// snapshots, including a smoothed transfer rate and an ETA.
///
/// Elapsed time comes from a [Stopwatch] that is stopped while the upload is
/// paused, so sitting paused for ten minutes does not report a 0 B/s average
/// afterwards.
class ProgressTracker {
  /// Creates a tracker for a payload of [totalBytes], of which [initialBytes]
  /// are already stored server-side (non-zero when resuming).
  ProgressTracker({required this.totalBytes, int initialBytes = 0})
      : _uploaded = initialBytes,
        _baseline = initialBytes;

  /// Weight of the newest sample in the exponential moving average.
  ///
  /// 0.3 keeps the displayed speed responsive to a connection changing without
  /// making it jitter on every chunk.
  static const double _alpha = 0.3;

  /// Total bytes to transfer.
  final int totalBytes;

  final Stopwatch _stopwatch = Stopwatch();
  final int _baseline;
  int _uploaded;
  double _bytesPerSecond = 0;
  int _lastSampleMicros = 0;
  int _lastSampleBytes = 0;

  /// Bytes acknowledged so far, including the resume baseline.
  int get uploadedBytes => _uploaded;

  /// Bytes pushed over the wire during this run.
  int get bytesThisRun => _uploaded - _baseline;

  /// Time spent transferring, excluding paused periods.
  Duration get elapsed => _stopwatch.elapsed;

  /// Smoothed transfer rate.
  double get bytesPerSecond => _bytesPerSecond;

  /// Starts (or restarts) the clock.
  void start() {
    _stopwatch.start();
    _lastSampleMicros = _stopwatch.elapsedMicroseconds;
    _lastSampleBytes = _uploaded;
  }

  /// Stops the clock while the upload is paused or waiting for connectivity.
  void pause() => _stopwatch.stop();

  /// Restarts the clock after a pause, discarding the stale rate sample.
  void resume() {
    _stopwatch.start();
    _lastSampleMicros = _stopwatch.elapsedMicroseconds;
    _lastSampleBytes = _uploaded;
  }

  /// Records [bytes] more as transferred and returns the new snapshot.
  UploadProgress add(int bytes) {
    _uploaded = math.min(totalBytes, _uploaded + bytes);
    _sample();
    return snapshot;
  }

  /// Overrides the uploaded byte count, e.g. after the server reported what it
  /// already holds.
  UploadProgress setUploaded(int bytes) {
    _uploaded = bytes.clamp(0, totalBytes);
    _sample();
    return snapshot;
  }

  void _sample() {
    final int now = _stopwatch.elapsedMicroseconds;
    final int deltaMicros = now - _lastSampleMicros;
    // Ignore samples under a millisecond: dividing by a near-zero interval
    // produces meaningless spikes.
    if (deltaMicros < 1000) return;
    final int deltaBytes = _uploaded - _lastSampleBytes;
    final double instant = deltaBytes * 1000000 / deltaMicros;
    _bytesPerSecond = _bytesPerSecond == 0
        ? instant
        : _alpha * instant + (1 - _alpha) * _bytesPerSecond;
    _lastSampleMicros = now;
    _lastSampleBytes = _uploaded;
  }

  /// The current progress snapshot.
  UploadProgress get snapshot {
    final int remaining = math.max(0, totalBytes - _uploaded);
    return UploadProgress(
      uploadedBytes: _uploaded,
      totalBytes: totalBytes,
      elapsed: _stopwatch.elapsed,
      bytesPerSecond: _bytesPerSecond,
      estimatedRemaining: _bytesPerSecond <= 0 || remaining == 0
          ? null
          : Duration(
              microseconds:
                  (remaining / _bytesPerSecond * Duration.microsecondsPerSecond)
                      .round(),
            ),
    );
  }
}
