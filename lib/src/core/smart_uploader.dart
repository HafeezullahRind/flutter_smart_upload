import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../adapters/upload_adapter.dart';
import '../exceptions/upload_exception.dart';
import '../models/upload_event.dart';
import '../models/upload_options.dart';
import '../models/upload_session.dart';
import '../models/upload_status.dart';
import '../persistence/upload_record.dart';
import '../util/upload_id.dart';
import 'smart_upload_config.dart';
import 'upload_manager.dart';
import 'upload_queue.dart';
import 'upload_task.dart';

/// The entry point of the package.
///
/// Create one per backend and keep it alive for the lifetime of the feature
/// (or the app). It owns the queue, the retry loop, progress bookkeeping and
/// the persisted state; the [UploadAdapter] you pass owns the wire protocol.
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
///   options: const UploadOptions(
///     compress: true,
///     maxWidth: 1920,
///     maxHeight: 1920,
///     quality: 80,
///   ),
///   onProgress: (UploadProgress progress) {
///     print('${progress.percentage.toStringAsFixed(0)}%');
///   },
/// );
///
/// final UploadResult result = await task.done;
/// print(result.url);
/// ```
class SmartUploader implements UploadTaskDelegate {
  /// Creates an uploader for [adapter].
  ///
  /// [config] is optional; its defaults (2 MB chunks, 2 concurrent uploads,
  /// 3 retries with exponential backoff, in-memory state) suit most apps.
  SmartUploader({required this.adapter, SmartUploadConfig? config})
      : config = config ?? SmartUploadConfig() {
    _manager = UploadManager(
      config: this.config,
      adapter: adapter,
      emit: _emit,
    );
    _queue = UploadQueue(
      maxConcurrent: this.config.maxConcurrentUploads,
      runner: _run,
      started: this.config.autoStart,
    );
  }

  /// The backend this uploader talks to.
  final UploadAdapter adapter;

  /// The settings in force.
  final SmartUploadConfig config;

  late final UploadManager _manager;
  late final UploadQueue _queue;

  final StreamController<UploadEvent> _events =
      StreamController<UploadEvent>.broadcast();
  final Map<String, UploadTask> _tasks = <String, UploadTask>{};
  final Map<String, UploadRecord> _records = <String, UploadRecord>{};

  bool _disposed = false;

  /// Every event from every upload this uploader manages.
  ///
  /// A broadcast stream: listen as many times as you like, and expect no
  /// replay of events raised before you subscribed.
  Stream<UploadEvent> get events => _events.stream;

  /// All tasks known to this uploader, including finished ones, newest last.
  List<UploadTask> get tasks => List<UploadTask>.unmodifiable(_tasks.values);

  /// Tasks that are transferring right now.
  ///
  /// A task's slot is released a microtask after its [UploadTask.done] future
  /// resolves, so finished tasks are filtered out here rather than flickering
  /// through this list.
  List<UploadTask> get activeTasks => _queue.active
      .where((UploadTask t) => !t.isFinished)
      .toList(growable: false);

  /// Tasks waiting for a free slot, in the order they will start.
  List<UploadTask> get queuedTasks => _queue.pending;

  /// Looks up a task by its id.
  UploadTask? task(String uploadId) => _tasks[uploadId];

  /// Completes once every queued and running upload has settled.
  Future<void> get onIdle => _queue.onIdle;

  /// Queues [file] for upload and returns its handle immediately.
  ///
  /// The returned task is *not* finished — that is what makes [UploadTask.pause]
  /// and [UploadTask.cancel] usable. Await [UploadTask.done] for the result:
  ///
  /// ```dart
  /// final UploadTask task = await uploader.upload(file: file);
  /// final UploadResult result = await task.done;
  /// ```
  ///
  /// Throws [SmartUploadException] with [UploadErrorCode.fileNotFound] if
  /// [file] does not exist — a mistake worth surfacing at the call site rather
  /// than asynchronously later.
  Future<UploadTask> upload({
    required File file,
    UploadOptions options = const UploadOptions(),
    ProgressCallback? onProgress,
    StatusCallback? onStatusChanged,
    String? uploadId,
  }) async {
    _assertUsable();
    if (!file.existsSync()) {
      throw SmartUploadException.fileNotFound(file.path);
    }
    final int size = await file.length();
    if (size <= 0) {
      throw SmartUploadException.invalidFile('File is empty: ${file.path}');
    }

    final UploadTask task = UploadTask(
      id: uploadId ?? generateUploadId(),
      file: file,
      fileName: options.fileName ?? p.basename(file.path),
      fileSize: size,
      options: options,
      delegate: this,
      onProgress: onProgress,
      onStatusChanged: onStatusChanged,
    );

    _tasks[task.id] = task;
    _emit(UploadQueuedEvent(
      uploadId: task.id,
      fileName: task.fileName,
      fileSize: task.fileSize,
    ));
    _queue.enqueue(task, priority: options.priority);
    return task;
  }

  /// Queues several files at once.
  ///
  /// They share [options] and are started in order, respecting
  /// [SmartUploadConfig.maxConcurrentUploads].
  ///
  /// ```dart
  /// final List<UploadTask> tasks = await uploader.uploadMultiple(files: files);
  /// await Future.wait(tasks.map((UploadTask t) => t.done));
  /// ```
  Future<List<UploadTask>> uploadMultiple({
    required List<File> files,
    UploadOptions options = const UploadOptions(),
    ProgressCallback? onProgress,
    StatusCallback? onStatusChanged,
  }) async {
    final List<UploadTask> tasks = <UploadTask>[];
    for (final File file in files) {
      tasks.add(await upload(
        file: file,
        options: options,
        onProgress: onProgress,
        onStatusChanged: onStatusChanged,
      ));
    }
    return tasks;
  }

  /// Continues a previously persisted upload.
  ///
  /// Works both for a task from this session and for one whose process died —
  /// as long as [SmartUploadConfig.storage] outlives it, e.g.
  /// [FileUploadStorage]. The transfer picks up at the first chunk the server
  /// does not already hold.
  ///
  /// ```dart
  /// for (final UploadRecord record in await uploader.pendingUploads()) {
  ///   await uploader.resume(record.uploadId);
  /// }
  /// ```
  Future<UploadTask> resume(
    String uploadId, {
    ProgressCallback? onProgress,
    StatusCallback? onStatusChanged,
  }) async {
    _assertUsable();

    final UploadTask? existing = _tasks[uploadId];
    if (existing != null && existing.status == UploadStatus.paused) {
      await resumeTask(existing);
      return existing;
    }
    if (existing != null && !existing.isFinished) {
      return existing;
    }

    final UploadRecord? record =
        _records[uploadId] ?? await config.storage.read(uploadId);
    if (record == null) {
      throw SmartUploadException(
        'No persisted upload with id $uploadId',
        errorCode: UploadErrorCode.resumeFailed,
      );
    }
    final File source = File(record.sourcePath);
    if (!source.existsSync()) {
      await config.storage.delete(uploadId);
      throw SmartUploadException(
        'The source file for $uploadId is gone: ${record.sourcePath}',
        errorCode: UploadErrorCode.resumeFailed,
      );
    }

    final UploadTask task = UploadTask(
      id: record.uploadId,
      file: source,
      fileName: record.fileName,
      fileSize: record.fileSize,
      options: record.options,
      delegate: this,
      onProgress: onProgress,
      onStatusChanged: onStatusChanged,
    );
    _tasks[task.id] = task;
    _records[task.id] = record;
    _emit(UploadQueuedEvent(
      uploadId: task.id,
      fileName: task.fileName,
      fileSize: task.fileSize,
    ));
    _queue.enqueue(task, priority: record.options.priority);
    return task;
  }

  /// Every upload that was interrupted and can be resumed, newest first.
  ///
  /// Call this at startup to offer "continue where you left off".
  Future<List<UploadRecord>> pendingUploads() async {
    final List<UploadRecord> all = await config.storage.readAll();
    return all.where((UploadRecord r) => r.isResumable).toList(growable: false);
  }

  /// Starts the queue when [SmartUploadConfig.autoStart] was `false`.
  void start() => _queue.start();

  /// Suspends every queued and running upload.
  Future<void> pauseAll() async {
    _queue.stop();
    await Future.wait(<Future<void>>[
      for (final UploadTask task in _tasks.values)
        if (!task.isFinished && task.status != UploadStatus.paused)
          pauseTask(task),
    ]);
  }

  /// Resumes every paused upload.
  Future<void> resumeAll() async {
    _queue.start();
    for (final UploadTask task in _tasks.values.toList(growable: false)) {
      if (task.status == UploadStatus.paused) {
        await resumeTask(task);
      }
    }
  }

  /// Cancels every queued and running upload.
  Future<void> cancelAll() async {
    await Future.wait(<Future<void>>[
      for (final UploadTask task in _tasks.values.toList(growable: false))
        if (!task.isFinished) cancelTask(task),
    ]);
  }

  /// Forgets finished tasks so they stop showing up in [tasks].
  void clearFinished() {
    _tasks.removeWhere((_, UploadTask task) => task.isFinished);
  }

  @override
  Future<void> pauseTask(UploadTask task) async {
    if (task.isFinished || task.status == UploadStatus.paused) return;

    if (_queue.remove(task)) {
      TaskInternals.setStatus(task, UploadStatus.paused);
      _emit(UploadPausedEvent(uploadId: task.id));
      return;
    }
    TaskInternals.requestPause(task);
    await TaskInternals.waitForStatus(
      task,
      (UploadStatus s) => s == UploadStatus.paused || s.isTerminal,
    );
  }

  @override
  Future<void> resumeTask(UploadTask task) async {
    if (task.status != UploadStatus.paused) {
      if (task.status == UploadStatus.failed) {
        throw SmartUploadException(
          'Task ${task.id} already failed; call uploader.resume(id) to start '
          'a new task from its persisted state.',
          errorCode: UploadErrorCode.resumeFailed,
        );
      }
      return;
    }
    TaskInternals.clearPause(task);
    TaskInternals.setStatus(task, UploadStatus.queued);
    _emit(UploadResumedEvent(uploadId: task.id));
    _queue.start();
    _queue.enqueue(task, priority: task.options.priority);
  }

  @override
  Future<void> cancelTask(UploadTask task) async {
    if (task.isFinished) return;
    TaskInternals.requestCancel(task);

    // A task that was only waiting for a slot never reached the adapter, so it
    // can be torn down here and now.
    if (_queue.remove(task)) {
      await _discard(task);
      TaskInternals.fail(task, SmartUploadException.cancelled(),
          cancelled: true);
      _emit(UploadCancelledEvent(uploadId: task.id));
      return;
    }

    // A runner is in flight — possibly parked at a checkpoint waiting for
    // connectivity. It owns the teardown; the cancel signal wakes it. If it
    // unwinds without reaching a terminal state (it had already decided to
    // pause), finish the job here.
    final Future<void>? runner = _queue.runnerFor(task);
    if (runner != null) {
      await Future.any<void>(<Future<void>>[
        runner,
        TaskInternals.waitForStatus(task, (UploadStatus s) => s.isTerminal),
      ]);
      if (task.isFinished) return;
    }

    // Paused between runs: no runner, nothing in flight.
    await _discard(task);
    TaskInternals.fail(task, SmartUploadException.cancelled(), cancelled: true);
    _emit(UploadCancelledEvent(uploadId: task.id));
  }

  /// Releases the server-side session, temp file and record of a task that is
  /// cancelled before (or between) transfers.
  Future<void> _discard(UploadTask task) async {
    final UploadRecord? record =
        _records[task.id] ?? await config.storage.read(task.id);
    if (record == null) return;

    final UploadSession? session = record.session;
    if (session != null) {
      try {
        await adapter.cancel(session).timeout(config.sessionTimeout);
      } catch (_) {
        // Best effort: the local cancellation stands either way.
      }
    }
    final String? uploadPath = record.uploadPath;
    if (uploadPath != null && uploadPath != record.sourcePath) {
      try {
        final File temp = File(uploadPath);
        if (temp.existsSync()) await temp.delete();
      } on FileSystemException {
        // Temp files are reclaimed by the OS eventually.
      }
    }
    await config.storage.delete(task.id);
    _records.remove(task.id);
  }

  /// The queue's runner: executes one task and remembers its final record.
  Future<void> _run(UploadTask task) async {
    final UploadOutcome outcome;
    try {
      TaskInternals.clearPause(task);
      final UploadRecord? record =
          _records[task.id] ?? await config.storage.read(task.id);
      outcome = await _manager.execute(task, record: record);
    } catch (error, stackTrace) {
      // The manager handles its own failures; anything that still escapes
      // (a third-party storage or adapter misbehaving outside a call the
      // manager guards) must not leave `task.done` hanging forever.
      final SmartUploadException failure =
          SmartUploadException.wrap(error, stackTrace);
      TaskInternals.fail(task, failure);
      _emit(UploadFailedEvent(uploadId: task.id, error: failure));
      return;
    }

    switch (outcome) {
      case UploadOutcome.completed:
      case UploadOutcome.cancelled:
        _records.remove(task.id);
      case UploadOutcome.failed:
      case UploadOutcome.paused:
        final UploadRecord? latest = await config.storage.read(task.id);
        if (latest != null) _records[task.id] = latest;
    }
  }

  void _emit(UploadEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void _assertUsable() {
    if (_disposed) {
      throw StateError('This SmartUploader has been disposed');
    }
  }

  /// Cancels everything in flight and releases resources.
  ///
  /// Call this when the owning screen or app is torn down. The uploader cannot
  /// be used afterwards.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _queue.stop();
    await cancelAll();
    await config.networkMonitor.dispose();
    await _events.close();
  }
}
