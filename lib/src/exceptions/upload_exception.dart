/// Canonical error codes emitted by the package.
///
/// Every [SmartUploadException] carries one of these. Adapters are encouraged
/// to reuse them so that application code can branch on a stable value rather
/// than on message text.
enum UploadErrorCode {
  /// The source file does not exist on disk.
  fileNotFound('file_not_found'),

  /// The file exists but is unusable (empty, unreadable, wrong type...).
  invalidFile('invalid_file'),

  /// Compression or resizing failed.
  compressionFailed('compression_failed'),

  /// A transport-level failure: socket closed, DNS failure, offline device.
  networkError('network_error'),

  /// The operation exceeded its deadline.
  timeout('timeout'),

  /// The server answered with a 5xx-style failure.
  serverError('server_error'),

  /// Credentials are missing, expired or rejected.
  authenticationError('authentication_error'),

  /// A single chunk could not be uploaded.
  chunkUploadFailed('chunk_upload_failed'),

  /// The upload was cancelled by the caller.
  uploadCancelled('upload_cancelled'),

  /// Locally computed and remotely reported checksums disagree.
  checksumMismatch('checksum_mismatch'),

  /// A persisted upload could not be resumed.
  resumeFailed('resume_failed'),

  /// The persistence layer failed to read or write upload state.
  storageError('storage_error'),

  /// The request was rejected as malformed.
  invalidRequest('invalid_request'),

  /// Anything that does not fit the categories above.
  unknown('unknown');

  const UploadErrorCode(this.value);

  /// The stable wire value, e.g. `chunk_upload_failed`.
  final String value;

  /// Whether errors of this kind are worth retrying when no explicit
  /// retryability was supplied.
  ///
  /// Permanent failures — bad credentials, malformed requests, missing files —
  /// deliberately return `false` so the retry loop does not burn attempts on
  /// something that cannot succeed.
  bool get isRetryableByDefault => switch (this) {
        networkError || timeout || serverError || chunkUploadFailed => true,
        fileNotFound ||
        invalidFile ||
        invalidRequest ||
        compressionFailed ||
        authenticationError ||
        uploadCancelled ||
        checksumMismatch ||
        resumeFailed ||
        storageError ||
        unknown =>
          false,
      };

  /// Parses a [value] back into a code, falling back to [unknown].
  static UploadErrorCode fromValue(String? value) => values.firstWhere(
        (UploadErrorCode c) => c.value == value,
        orElse: () => unknown,
      );
}

/// The single exception type thrown by `flutter_smart_upload`.
///
/// ```dart
/// try {
///   await task.done;
/// } on SmartUploadException catch (e) {
///   if (e.isRetryable) scheduleAnotherAttempt();
///   print('${e.code}: ${e.message}');
/// }
/// ```
class SmartUploadException implements Exception {
  /// Creates an exception with an explicit [errorCode].
  SmartUploadException(
    this.message, {
    this.errorCode = UploadErrorCode.unknown,
    this.cause,
    this.stackTrace,
    bool? retryable,
  }) : _retryable = retryable;

  /// The source file could not be found.
  SmartUploadException.fileNotFound(String path)
      : this('File not found: $path', errorCode: UploadErrorCode.fileNotFound);

  /// The source file is present but unusable.
  SmartUploadException.invalidFile(String message, {Object? cause})
      : this(message, errorCode: UploadErrorCode.invalidFile, cause: cause);

  /// A transport failure. Retryable by default.
  SmartUploadException.network(String message, {Object? cause})
      : this(message, errorCode: UploadErrorCode.networkError, cause: cause);

  /// A deadline was exceeded. Retryable by default.
  SmartUploadException.timeout(String message, {Object? cause})
      : this(message, errorCode: UploadErrorCode.timeout, cause: cause);

  /// The remote end failed. Retryable by default.
  SmartUploadException.server(String message, {Object? cause})
      : this(message, errorCode: UploadErrorCode.serverError, cause: cause);

  /// Credentials were rejected. Never retried automatically.
  SmartUploadException.authentication(String message, {Object? cause})
      : this(
          message,
          errorCode: UploadErrorCode.authenticationError,
          cause: cause,
        );

  /// The upload was cancelled by the caller.
  SmartUploadException.cancelled([String message = 'Upload was cancelled'])
      : this(message, errorCode: UploadErrorCode.uploadCancelled);

  /// Compression or resizing failed.
  SmartUploadException.compression(String message, {Object? cause})
      : this(
          message,
          errorCode: UploadErrorCode.compressionFailed,
          cause: cause,
        );

  /// A human readable description of what went wrong.
  final String message;

  /// The typed error code.
  final UploadErrorCode errorCode;

  /// The underlying error, when this exception wraps another failure.
  final Object? cause;

  /// The stack trace of [cause], when available.
  final StackTrace? stackTrace;

  final bool? _retryable;

  /// The stable string form of [errorCode], e.g. `network_error`.
  String get code => errorCode.value;

  /// Whether retrying this operation could plausibly succeed.
  ///
  /// Defaults to [UploadErrorCode.isRetryableByDefault] unless the thrower
  /// passed an explicit `retryable` flag.
  bool get isRetryable => _retryable ?? errorCode.isRetryableByDefault;

  /// Returns a copy of this exception with [retryable] overridden.
  SmartUploadException asRetryable({bool retryable = true}) =>
      SmartUploadException(
        message,
        errorCode: errorCode,
        cause: cause,
        stackTrace: stackTrace,
        retryable: retryable,
      );

  /// Wraps an arbitrary [error] into a [SmartUploadException].
  ///
  /// Already-typed errors are returned unchanged so that adapter-supplied
  /// codes survive the trip through the orchestrator.
  static SmartUploadException wrap(
    Object error, [
    StackTrace? stackTrace,
    UploadErrorCode fallback = UploadErrorCode.unknown,
  ]) {
    if (error is SmartUploadException) return error;
    return SmartUploadException(
      error.toString(),
      errorCode: fallback,
      cause: error,
      stackTrace: stackTrace,
    );
  }

  @override
  String toString() => 'SmartUploadException($code): $message'
      '${cause == null ? '' : ' (cause: $cause)'}';
}
