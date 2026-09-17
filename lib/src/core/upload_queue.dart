import 'dart:async';

import 'package:meta/meta.dart';

import 'upload_task.dart';

/// A concurrency-limited, priority-aware FIFO queue of uploads.
///
/// With `maxConcurrentUploads: 2` and twenty files added, two transfer and
/// eighteen wait; each time one finishes the next is started. Higher
/// [UploadOptions.priority] jumps the line, and equal priorities keep
/// insertion order.
@internal
class UploadQueue {
  /// Creates a queue that runs at most [maxConcurrent] uploads through
  /// [runner].
  UploadQueue({
    required this.maxConcurrent,
    required Future<void> Function(UploadTask task) runner,
    bool started = true,
  })  : assert(maxConcurrent > 0, 'maxConcurrent must be greater than zero'),
        _runner = runner,
        _started = started;

  /// Maximum simultaneous transfers.
  final int maxConcurrent;

  final Future<void> Function(UploadTask task) _runner;
  final List<_Entry> _pending = <_Entry>[];
  final Set<UploadTask> _active = <UploadTask>{};
  final Map<UploadTask, Future<void>> _runners = <UploadTask, Future<void>>{};
  final List<Completer<void>> _idleWaiters = <Completer<void>>[];

  bool _started;
  int _sequence = 0;

  /// Tasks currently transferring.
  Set<UploadTask> get active => Set<UploadTask>.unmodifiable(_active);

  /// Tasks waiting for a slot, in the order they will be started.
  List<UploadTask> get pending =>
      _pending.map((_Entry e) => e.task).toList(growable: false);

  /// Number of transfers in flight.
  int get activeCount => _active.length;

  /// Number of tasks waiting.
  int get pendingCount => _pending.length;

  /// Whether nothing is running or waiting.
  bool get isIdle => _active.isEmpty && _pending.isEmpty;

  /// Whether the queue is allowed to start new transfers.
  bool get isStarted => _started;

  /// Adds [task] to the queue and starts it if a slot is free.
  ///
  /// Re-enqueueing a task that is still finishing its previous run is safe:
  /// it waits until that run has released its slot.
  void enqueue(UploadTask task, {int priority = 0}) {
    if (contains(task)) return;
    _pending.add(_Entry(task: task, priority: priority, sequence: _sequence++));
    // Highest priority first; ties broken by insertion order so the queue
    // stays predictable.
    _pending.sort((_Entry a, _Entry b) {
      final int byPriority = b.priority.compareTo(a.priority);
      return byPriority != 0 ? byPriority : a.sequence.compareTo(b.sequence);
    });
    _pump();
  }

  /// Whether [task] is waiting for a slot.
  bool contains(UploadTask task) =>
      _pending.any((_Entry e) => identical(e.task, task));

  /// Whether [task] is transferring right now.
  bool isActive(UploadTask task) => _active.contains(task);

  /// The future of [task]'s in-flight run, or `null` if it is not running.
  ///
  /// Lets callers wait for a runner to unwind before tearing its task down.
  Future<void>? runnerFor(UploadTask task) => _runners[task];

  /// Removes [task] from the waiting list. Returns whether it was there.
  bool remove(UploadTask task) {
    final int before = _pending.length;
    _pending.removeWhere((_Entry e) => identical(e.task, task));
    final bool removed = _pending.length != before;
    if (removed) _notifyIfIdle();
    return removed;
  }

  /// Allows the queue to start transfers again after [stop].
  void start() {
    if (_started) return;
    _started = true;
    _pump();
  }

  /// Stops starting new transfers. Running ones are unaffected.
  void stop() => _started = false;

  /// Empties the waiting list, returning the tasks that were dropped.
  List<UploadTask> clearPending() {
    final List<UploadTask> dropped =
        _pending.map((_Entry e) => e.task).toList(growable: false);
    _pending.clear();
    _notifyIfIdle();
    return dropped;
  }

  /// Completes once nothing is running or waiting.
  Future<void> get onIdle {
    if (isIdle) return Future<void>.value();
    final Completer<void> completer = Completer<void>();
    _idleWaiters.add(completer);
    return completer.future;
  }

  void _pump() {
    if (!_started) return;
    while (_active.length < maxConcurrent && _pending.isNotEmpty) {
      // A task can be re-enqueued (by `resume()`) while its previous run is
      // still unwinding. Leave it waiting until its slot is actually
      // released, rather than running it twice.
      final int next =
          _pending.indexWhere((_Entry e) => !_active.contains(e.task));
      if (next < 0) return;
      final _Entry entry = _pending.removeAt(next);
      _active.add(entry.task);
      // Errors are the runner's responsibility; the queue only cares that the
      // slot is released.
      final Future<void> run = _runner(entry.task).whenComplete(() {
        _active.remove(entry.task);
        _runners.remove(entry.task);
        _notifyIfIdle();
        _pump();
      });
      _runners[entry.task] = run;
      unawaited(run);
    }
    _notifyIfIdle();
  }

  void _notifyIfIdle() {
    if (!isIdle || _idleWaiters.isEmpty) return;
    final List<Completer<void>> waiters =
        List<Completer<void>>.of(_idleWaiters);
    _idleWaiters.clear();
    for (final Completer<void> completer in waiters) {
      if (!completer.isCompleted) completer.complete();
    }
  }
}

class _Entry {
  _Entry({required this.task, required this.priority, required this.sequence});

  final UploadTask task;
  final int priority;
  final int sequence;
}
