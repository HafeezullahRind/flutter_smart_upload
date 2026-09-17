import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';

import '../exceptions/upload_exception.dart';
import '../models/upload_options.dart';
import '../models/upload_progress.dart';
import '../models/upload_result.dart';
import '../models/upload_status.dart';

/// Called whenever transfer progress advances.
typedef ProgressCallback = void Function(UploadProgress progress);

/// Called whenever an upload changes state.
typedef StatusCallback = void Function(UploadStatus status);

/// Internal seam between a task and the uploader that owns it.
@internal
abstract class UploadTaskDelegate {
  /// Suspends [task].
  Future<void> pauseTask(UploadTask task);

  /// Resumes [task].
  Future<void> resumeTask(UploadTask task);

  /// Cancels [task].
  Future<void> cancelTask(UploadTask task);
}

/// A handle on one upload.
///
/// Returned by [SmartUploader.upload] as soon as the upload is accepted — not
/// when it finishes — so that you can drive it while it runs:
///
/// ```dart
/// final UploadTask task = await uploader.upload(file: file);
/// await task.pause();
/// await task.resume();
/// final UploadResult result = await task.done;
/// print(result.url);
/// ```
///
/// [done] completes with the [UploadResult] on success, or throws a
/// [SmartUploadException] on failure or cancellation.
class UploadTask {
  /// Creates a task. Called by [SmartUploader]; not part of the public API.
  @internal
  UploadTask({
    required this.id,
    required this.file,
    required this.fileName,
    required this.fileSize,
    required this.options,
    required UploadTaskDelegate delegate,
    this.onProgress,
    this.onStatusChanged,
    UploadStatus initialStatus = UploadStatus.queued,
  })  : _delegate = delegate,
        _status = initialStatus,
        _progress = UploadProgress.initial(fileSize) {
    // Keep an error handler attached so a failed upload that nobody awaited
    // does not surface as an unhandled async error.
    unawaited(_completer.future.then<void>(
      (UploadResult _) {},
      onError: (Object _, StackTrace __) {},
    ));
  }

  /// Stable identifier, also the persistence key.
  final String id;

  /// The file the caller asked to upload.
  final File file;

  /// Name reported to the backend.
  final String fileName;

  /// Size of [file] on disk, before compression.
  final int fileSize;

  /// The options this upload was started with.
  final UploadOptions options;

  /// Progress callback supplied at `upload()` time.
  final ProgressCallback? onProgress;

  /// Status callback supplied at `upload()` time.
  final StatusCallback? onStatusChanged;

  final UploadTaskDelegate _delegate;
  final Completer<UploadResult> _completer = Completer<UploadResult>();
  // Closed by `TaskInternals.complete`/`fail` when the task reaches a terminal
  // state, which is the only point at which no further events can arrive.
  // ignore: close_sinks
  final StreamController<UploadStatus> _statusController =
      StreamController<UploadStatus>.broadcast();
  // ignore: close_sinks
  final StreamController<UploadProgress> _progressController =
      StreamController<UploadProgress>.broadcast();

  UploadStatus _status;
  UploadProgress _progress;
  UploadResult? _result;
  SmartUploadException? _error;
  bool _pauseRequested = false;
  bool _cancelRequested = false;
  bool _waitingForNetwork = false;
  int _attempts = 0;
  Completer<void>? _cancelSignal;

  /// The current state.
  UploadStatus get status => _status;

  /// The most recent progress snapshot.
  UploadProgress get progress => _progress;

  /// The result, once the upload has completed successfully.
  UploadResult? get result => _result;

  /// The failure, once the upload has failed or been cancelled.
  SmartUploadException? get error => _error;

  /// Shorthand for `result?.url`.
  String? get url => _result?.url;

  /// How many attempts have been made, including the current one.
  int get attempts => _attempts;

  /// Whether the upload is parked because the device is offline.
  bool get isWaitingForNetwork => _waitingForNetwork;

  /// Whether the upload has reached a terminal state.
  bool get isFinished => _status.isTerminal;

  /// Completes with the result, or throws [SmartUploadException].
  Future<UploadResult> get done => _completer.future;

  /// Emits every state transition. Closes when the task finishes.
  Stream<UploadStatus> get statusStream => _statusController.stream;

  /// Emits every progress update. Closes when the task finishes.
  Stream<UploadProgress> get progressStream => _progressController.stream;

  /// Suspends the upload.
  ///
  /// A queued task leaves the queue immediately. A transferring task finishes
  /// the chunk currently in flight — so no bytes are wasted — and then stops.
  /// The returned future completes once the task has actually stopped.
  Future<void> pause() => _delegate.pauseTask(this);

  /// Puts a paused upload back in the queue.
  ///
  /// The transfer picks up at the first chunk the server does not already
  /// hold. A *failed* task is terminal — its [done] future is already
  /// resolved — so restart one with `uploader.resume(task.id)`, which hands
  /// back a fresh task built from the persisted record.
  Future<void> resume() => _delegate.resumeTask(this);

  /// Cancels the upload and releases its resources.
  ///
  /// Stops further network requests, asks the adapter to discard the
  /// server-side session, deletes any compressed temporary file and drops the
  /// persisted record. [done] then throws with
  /// [UploadErrorCode.uploadCancelled].
  Future<void> cancel() => _delegate.cancelTask(this);

  /// Waits until [test] accepts the task's state.
  Future<void> _waitForStatus(bool Function(UploadStatus status) test) async {
    if (test(_status)) return;
    await for (final UploadStatus status in _statusController.stream) {
      if (test(status)) return;
    }
  }

  @override
  String toString() => 'UploadTask($id, $fileName, ${_status.name}, '
      '${_progress.percentage.toStringAsFixed(1)}%)';
}

/// Privileged access to [UploadTask] state for the orchestrator.
///
/// Keeps the mutation surface out of the public API while letting other
/// library files drive a task.
@internal
class TaskInternals {
  const TaskInternals._();

  /// Whether a pause has been requested but not yet honoured.
  static bool isPauseRequested(UploadTask task) => task._pauseRequested;

  /// Whether a cancellation has been requested.
  static bool isCancelRequested(UploadTask task) => task._cancelRequested;

  /// Requests a pause at the next safe point.
  static void requestPause(UploadTask task) => task._pauseRequested = true;

  /// Clears a pending pause request.
  static void clearPause(UploadTask task) => task._pauseRequested = false;

  /// Requests cancellation and wakes anything waiting on [cancelSignal].
  static void requestCancel(UploadTask task) {
    task._cancelRequested = true;
    final Completer<void>? signal = task._cancelSignal;
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  /// A future that completes as soon as cancellation is requested.
  ///
  /// Raced against in-flight adapter calls so a cancel does not have to wait
  /// out a two-minute socket timeout.
  static Future<void> cancelSignal(UploadTask task) {
    final Completer<void> signal =
        task._cancelSignal ??= Completer<void>.sync();
    if (task._cancelRequested && !signal.isCompleted) signal.complete();
    return signal.future;
  }

  /// Prepares the task for a fresh attempt.
  static void resetForRetry(UploadTask task) {
    task._pauseRequested = false;
    task._cancelRequested = false;
    task._cancelSignal = null;
    task._error = null;
    task._waitingForNetwork = false;
  }

  /// Increments and returns the attempt counter.
  static int nextAttempt(UploadTask task) => ++task._attempts;

  /// Sets whether the task is parked waiting for connectivity.
  static void setWaitingForNetwork(UploadTask task, bool value) =>
      task._waitingForNetwork = value;

  /// Applies a state transition, notifying listeners.
  ///
  /// Terminal states are final: a late transition from an abandoned runner
  /// cannot flip a cancelled task to failed.
  static void setStatus(UploadTask task, UploadStatus status) {
    if (task._status == status || task._status.isTerminal) return;
    task._status = status;
    if (!task._statusController.isClosed) task._statusController.add(status);
    task.onStatusChanged?.call(status);
  }

  /// Publishes a progress snapshot.
  static void setProgress(UploadTask task, UploadProgress progress) {
    task._progress = progress;
    if (!task._progressController.isClosed) {
      task._progressController.add(progress);
    }
    task.onProgress?.call(progress);
  }

  /// Marks the task complete and closes its streams.
  static void complete(UploadTask task, UploadResult result) {
    if (task._completer.isCompleted) return;
    task._result = result;
    setProgress(
      task,
      task._progress.copyWith(uploadedBytes: task._progress.totalBytes),
    );
    setStatus(task, UploadStatus.completed);
    if (!task._completer.isCompleted) task._completer.complete(result);
    _close(task);
  }

  /// Marks the task failed (or cancelled) and closes its streams.
  static void fail(
    UploadTask task,
    SmartUploadException error, {
    bool cancelled = false,
  }) {
    if (task._completer.isCompleted) return;
    task._error = error;
    setStatus(task, cancelled ? UploadStatus.cancelled : UploadStatus.failed);
    if (!task._completer.isCompleted) task._completer.completeError(error);
    _close(task);
  }

  /// Waits until [test] accepts the task's state.
  static Future<void> waitForStatus(
    UploadTask task,
    bool Function(UploadStatus status) test,
  ) =>
      task._waitForStatus(test);

  static void _close(UploadTask task) {
    unawaited(task._statusController.close());
    unawaited(task._progressController.close());
  }
}
