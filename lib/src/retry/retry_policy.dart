import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../exceptions/upload_exception.dart';

/// Everything a [RetryPolicy] needs to decide what happens after a failure.
@immutable
class RetryContext {
  /// Creates a retry context.
  const RetryContext({
    required this.attempt,
    required this.error,
    required this.elapsed,
    this.chunkIndex,
    this.adapterSaysRetryable = true,
  });

  /// 1-based number of the attempt that just failed.
  ///
  /// `1` means the original try failed and the first *retry* is being
  /// considered.
  final int attempt;

  /// The failure being classified.
  final SmartUploadException error;

  /// Time spent on this upload so far.
  final Duration elapsed;

  /// The chunk that failed, or `null` for session-level operations
  /// (`initialize`/`complete`).
  final int? chunkIndex;

  /// The adapter's own opinion, from `UploadAdapter.isRetryable`.
  final bool adapterSaysRetryable;

  @override
  String toString() =>
      'RetryContext(attempt: $attempt, chunk: $chunkIndex, ${error.code})';
}

/// Decides whether and when a failed operation is tried again.
///
/// Implement this to plug in your own rules — respect `Retry-After`, give up
/// after a wall-clock budget, never retry on metered connections, and so on.
abstract class RetryPolicy {
  /// Const constructor so policies can be const.
  const RetryPolicy();

  /// Maximum number of retries *after* the initial attempt.
  int get maxRetries;

  /// Whether the operation described by [context] should be tried again.
  bool shouldRetry(RetryContext context);

  /// How long to wait before the next attempt.
  Duration delayFor(RetryContext context);
}

/// The default policy: exponential backoff with optional jitter, skipping
/// errors that cannot succeed on a retry.
///
/// With the defaults (`retryDelay: 2s`, `multiplier: 2`) the delays are:
///
/// ```text
/// attempt 1 -> 2s
/// attempt 2 -> 4s
/// attempt 3 -> 8s
/// ```
///
/// Permanent failures — [UploadErrorCode.authenticationError],
/// [UploadErrorCode.invalidFile], [UploadErrorCode.fileNotFound],
/// [UploadErrorCode.uploadCancelled] — are never retried, so a bad token fails
/// in milliseconds instead of after 14 seconds of pointless waiting.
class ExponentialBackoffRetryPolicy extends RetryPolicy {
  /// Creates an exponential backoff policy.
  ExponentialBackoffRetryPolicy({
    this.maxRetries = 3,
    this.initialDelay = const Duration(seconds: 2),
    this.multiplier = 2.0,
    this.maxDelay = const Duration(minutes: 2),
    this.jitter = 0.1,
    math.Random? random,
  })  : assert(maxRetries >= 0, 'maxRetries cannot be negative'),
        assert(multiplier >= 1, 'multiplier must be at least 1'),
        assert(jitter >= 0 && jitter < 1, 'jitter must be in [0, 1)'),
        _random = random ?? math.Random();

  @override
  final int maxRetries;

  /// Delay before the first retry.
  final Duration initialDelay;

  /// Factor applied to the delay after every attempt.
  final double multiplier;

  /// Upper bound on a single delay.
  final Duration maxDelay;

  /// Random spread applied to each delay, as a fraction (`0.1` = ±10%).
  ///
  /// Prevents a fleet of clients that lost connectivity together from
  /// retrying in lockstep.
  final double jitter;

  final math.Random _random;

  @override
  bool shouldRetry(RetryContext context) {
    if (context.attempt > maxRetries) return false;
    if (!context.error.isRetryable) return false;
    return context.adapterSaysRetryable;
  }

  @override
  Duration delayFor(RetryContext context) {
    final double base = initialDelay.inMicroseconds *
        math.pow(multiplier, context.attempt - 1).toDouble();
    final double capped = math.min(base, maxDelay.inMicroseconds.toDouble());
    final double spread =
        jitter == 0 ? 0 : capped * jitter * (_random.nextDouble() * 2 - 1);
    return Duration(microseconds: math.max(0, (capped + spread).round()));
  }
}

/// A policy that never retries. Useful in tests and for fire-and-forget
/// uploads where the caller wants to handle failure itself.
class NoRetryPolicy extends RetryPolicy {
  /// Creates the policy.
  const NoRetryPolicy();

  @override
  int get maxRetries => 0;

  @override
  bool shouldRetry(RetryContext context) => false;

  @override
  Duration delayFor(RetryContext context) => Duration.zero;
}
