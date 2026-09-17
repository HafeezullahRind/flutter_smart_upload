import 'dart:io';

import 'package:meta/meta.dart';

import '../checksum/checksum_provider.dart';
import '../compression/compressor.dart';
import '../models/upload_options.dart';
import '../network/network_monitor.dart';
import '../persistence/memory_upload_storage.dart';
import '../persistence/upload_storage.dart';
import '../retry/retry_policy.dart';

/// Global settings for a [SmartUploader].
///
/// Everything has a default that is safe for a phone on a flaky mobile
/// network, so the shortest useful configuration is no configuration:
///
/// ```dart
/// final SmartUploader uploader = SmartUploader(adapter: myAdapter);
/// ```
@immutable
class SmartUploadConfig {
  /// Creates a configuration.
  SmartUploadConfig({
    this.chunkSize = defaultChunkSize,
    this.maxConcurrentUploads = 2,
    this.maxRetries = 3,
    this.retryDelay = const Duration(seconds: 2),
    RetryPolicy? retryPolicy,
    this.checksumMode = ChecksumMode.none,
    this.checksumProvider = const Md5ChecksumProvider(),
    this.compressor = const NoopCompressor(),
    UploadStorage? storage,
    this.networkMonitor = const AlwaysOnlineNetworkMonitor(),
    this.tempDirectory,
    this.chunkTimeout = const Duration(minutes: 2),
    this.sessionTimeout = const Duration(seconds: 60),
    this.progressInterval = const Duration(milliseconds: 100),
    this.waitForNetwork = true,
    this.networkWaitTimeout = const Duration(minutes: 5),
    this.deleteRecordOnSuccess = true,
    this.verifyChecksumOnResume = true,
    this.autoStart = true,
  })  : assert(chunkSize > 0, 'chunkSize must be greater than zero'),
        assert(
          maxConcurrentUploads > 0,
          'maxConcurrentUploads must be greater than zero',
        ),
        assert(maxRetries >= 0, 'maxRetries cannot be negative'),
        retryPolicy = retryPolicy ??
            ExponentialBackoffRetryPolicy(
              maxRetries: maxRetries,
              initialDelay: retryDelay,
            ),
        storage = storage ?? MemoryUploadStorage();

  /// 2 MB — small enough to retry cheaply on a bad connection, large enough
  /// that per-request overhead stays negligible.
  static const int defaultChunkSize = 2 * 1024 * 1024;

  /// Bytes per chunk. Overridable per upload via [UploadOptions.chunkSize],
  /// and by the server via [UploadSession.chunkSize].
  final int chunkSize;

  /// How many uploads may transfer at the same time. The rest wait in the
  /// queue.
  final int maxConcurrentUploads;

  /// Retries allowed after the initial attempt. Feeds the default
  /// [retryPolicy].
  final int maxRetries;

  /// Delay before the first retry. Doubles on each subsequent attempt.
  final Duration retryDelay;

  /// Decides whether and when failed operations are retried.
  final RetryPolicy retryPolicy;

  /// Default checksum behaviour. Overridable per upload.
  final ChecksumMode checksumMode;

  /// How digests are computed when [checksumMode] asks for them.
  final ChecksumProvider checksumProvider;

  /// Transforms files before upload. Defaults to doing nothing; pass
  /// `ImageCompressor()` to enable image resizing and re-encoding.
  final Compressor compressor;

  /// Where upload state is persisted. Defaults to in-memory.
  final UploadStorage storage;

  /// Supplies connectivity state. Defaults to "always online".
  final NetworkMonitor networkMonitor;

  /// Directory for compressed temporary files. Defaults to a
  /// `flutter_smart_upload` folder inside the system temp directory.
  final Directory? tempDirectory;

  /// Deadline for a single `uploadChunk` call.
  final Duration chunkTimeout;

  /// Deadline for `initialize` and `complete`.
  final Duration sessionTimeout;

  /// Minimum spacing between progress callbacks.
  ///
  /// Progress is always emitted for the first and last byte; this only damps
  /// the stream in between so a fast connection cannot flood the UI thread.
  final Duration progressInterval;

  /// Whether to park uploads while the device is offline instead of failing
  /// them. Requires a real [networkMonitor] to have any effect.
  final bool waitForNetwork;

  /// How long to wait for connectivity before giving up and failing the
  /// upload.
  final Duration networkWaitTimeout;

  /// Whether to drop the persisted record once an upload completes.
  ///
  /// Set to `false` to keep a local history of finished uploads.
  final bool deleteRecordOnSuccess;

  /// Whether to re-hash the file before resuming a persisted upload, to be
  /// sure the bytes did not change. Only has an effect when the original
  /// upload stored a checksum.
  final bool verifyChecksumOnResume;

  /// Whether `upload()` starts the transfer immediately. When `false`, tasks
  /// sit in the queue until [SmartUploader.start] is called.
  final bool autoStart;

  /// Returns a copy with the given fields replaced.
  SmartUploadConfig copyWith({
    int? chunkSize,
    int? maxConcurrentUploads,
    int? maxRetries,
    Duration? retryDelay,
    RetryPolicy? retryPolicy,
    ChecksumMode? checksumMode,
    ChecksumProvider? checksumProvider,
    Compressor? compressor,
    UploadStorage? storage,
    NetworkMonitor? networkMonitor,
    Directory? tempDirectory,
    Duration? chunkTimeout,
    Duration? sessionTimeout,
    Duration? progressInterval,
    bool? waitForNetwork,
    Duration? networkWaitTimeout,
    bool? deleteRecordOnSuccess,
    bool? verifyChecksumOnResume,
    bool? autoStart,
  }) =>
      SmartUploadConfig(
        chunkSize: chunkSize ?? this.chunkSize,
        maxConcurrentUploads: maxConcurrentUploads ?? this.maxConcurrentUploads,
        maxRetries: maxRetries ?? this.maxRetries,
        retryDelay: retryDelay ?? this.retryDelay,
        retryPolicy: retryPolicy ?? this.retryPolicy,
        checksumMode: checksumMode ?? this.checksumMode,
        checksumProvider: checksumProvider ?? this.checksumProvider,
        compressor: compressor ?? this.compressor,
        storage: storage ?? this.storage,
        networkMonitor: networkMonitor ?? this.networkMonitor,
        tempDirectory: tempDirectory ?? this.tempDirectory,
        chunkTimeout: chunkTimeout ?? this.chunkTimeout,
        sessionTimeout: sessionTimeout ?? this.sessionTimeout,
        progressInterval: progressInterval ?? this.progressInterval,
        waitForNetwork: waitForNetwork ?? this.waitForNetwork,
        networkWaitTimeout: networkWaitTimeout ?? this.networkWaitTimeout,
        deleteRecordOnSuccess:
            deleteRecordOnSuccess ?? this.deleteRecordOnSuccess,
        verifyChecksumOnResume:
            verifyChecksumOnResume ?? this.verifyChecksumOnResume,
        autoStart: autoStart ?? this.autoStart,
      );

  @override
  String toString() => 'SmartUploadConfig(chunkSize: $chunkSize, '
      'maxConcurrentUploads: $maxConcurrentUploads, '
      'maxRetries: $maxRetries)';
}
