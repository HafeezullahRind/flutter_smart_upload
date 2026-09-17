import 'dart:async';
import 'dart:io';

import 'package:flutter_smart_upload/flutter_smart_upload.dart';
import 'package:test/test.dart';

import 'support/test_support.dart';

void main() {
  late Directory dir;

  setUp(() => dir = createTempDir());
  tearDown(() => dir.deleteSync(recursive: true));

  group('concurrency', () {
    test('never exceeds maxConcurrentUploads', () async {
      final List<File> files = <File>[
        for (int i = 0; i < 8; i++) createFile(dir, 'f$i.bin', 4096),
      ];
      final _ConcurrencyProbeAdapter adapter = _ConcurrencyProbeAdapter(
        delay: const Duration(milliseconds: 15),
      );
      final SmartUploader uploader = SmartUploader(
        adapter: adapter,
        config: testConfig(chunkSize: 1024, maxConcurrentUploads: 2),
      );

      final List<UploadTask> tasks =
          await uploader.uploadMultiple(files: files);
      await Future.wait(tasks.map((UploadTask t) => t.done));

      expect(adapter.peakConcurrency, lessThanOrEqualTo(2));
      expect(adapter.peakConcurrency, 2, reason: 'the limit should be used');
      await uploader.dispose();
    });

    test('a single slot serialises uploads completely', () async {
      final List<File> files = <File>[
        for (int i = 0; i < 4; i++) createFile(dir, 's$i.bin', 2048),
      ];
      final _ConcurrencyProbeAdapter adapter = _ConcurrencyProbeAdapter(
        delay: const Duration(milliseconds: 5),
      );
      final SmartUploader uploader = SmartUploader(
        adapter: adapter,
        config: testConfig(chunkSize: 1024, maxConcurrentUploads: 1),
      );

      final List<UploadTask> tasks =
          await uploader.uploadMultiple(files: files);
      await Future.wait(tasks.map((UploadTask t) => t.done));

      expect(adapter.peakConcurrency, 1);
      await uploader.dispose();
    });

    test('20 files with concurrency 2 leaves the rest queued', () async {
      final List<File> files = <File>[
        for (int i = 0; i < 20; i++) createFile(dir, 'q$i.bin', 2048),
      ];
      final SmartUploader uploader = SmartUploader(
        adapter: MockUploadAdapter(
          chunkLatency: const Duration(milliseconds: 20),
        ),
        config: testConfig(chunkSize: 1024, maxConcurrentUploads: 2),
      );

      final List<UploadTask> tasks =
          await uploader.uploadMultiple(files: files);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(uploader.activeTasks, hasLength(2));
      expect(uploader.queuedTasks, hasLength(18));
      expect(
        tasks.where((UploadTask t) => t.status == UploadStatus.queued),
        hasLength(18),
      );

      await Future.wait(tasks.map((UploadTask t) => t.done));
      await uploader.onIdle;
      expect(uploader.activeTasks, isEmpty);
      expect(uploader.queuedTasks, isEmpty);
      await uploader.dispose();
    });

    test('a failing upload frees its slot for the next one', () async {
      final List<File> files = <File>[
        for (int i = 0; i < 3; i++) createFile(dir, 'fail$i.bin', 1024),
      ];
      final SmartUploader uploader = SmartUploader(
        adapter: MockUploadAdapter(permanentChunkFailure: 0),
        config: testConfig(
          chunkSize: 1024,
          maxConcurrentUploads: 1,
          maxRetries: 0,
        ),
      );

      final List<UploadTask> tasks =
          await uploader.uploadMultiple(files: files);
      await Future.wait(
        tasks.map((UploadTask t) =>
            t.done.catchError((Object e) => UploadResult(uploadId: t.id))),
      );

      expect(tasks.every((UploadTask t) => t.status == UploadStatus.failed),
          isTrue);
      expect(uploader.onIdle, completes);
      await uploader.dispose();
    });
  });

  group('ordering', () {
    test('respects priority, then insertion order', () async {
      final SmartUploader uploader = SmartUploader(
        adapter: MockUploadAdapter(
          chunkLatency: const Duration(milliseconds: 10),
        ),
        config: testConfig(chunkSize: 4096, maxConcurrentUploads: 1),
      );
      final List<String> order = <String>[];
      final StreamSubscription<UploadEvent> sub = uploader.events
          .where((UploadEvent e) => e is UploadStartedEvent)
          .listen((UploadEvent e) => order.add(e.uploadId));

      // Occupy the single slot first so the rest really queue up.
      final UploadTask blocker = await uploader.upload(
        file: createFile(dir, 'blocker.bin', 4096),
      );
      final UploadTask low = await uploader.upload(
        file: createFile(dir, 'low.bin', 1024),
        options: const UploadOptions(priority: 0),
      );
      final UploadTask high = await uploader.upload(
        file: createFile(dir, 'high.bin', 1024),
        options: const UploadOptions(priority: 10),
      );
      final UploadTask alsoLow = await uploader.upload(
        file: createFile(dir, 'also-low.bin', 1024),
        options: const UploadOptions(priority: 0),
      );

      await Future.wait(<Future<UploadResult>>[
        blocker.done,
        low.done,
        high.done,
        alsoLow.done,
      ]);
      await Future<void>.delayed(Duration.zero);

      expect(order, <String>[blocker.id, high.id, low.id, alsoLow.id]);
      await sub.cancel();
      await uploader.dispose();
    });
  });

  group('uploader lifecycle', () {
    test('autoStart: false holds everything until start()', () async {
      final File file = createFile(dir, 'held.bin', 1024);
      final SmartUploadConfig config =
          testConfig(chunkSize: 1024).copyWith(autoStart: false);
      final MockUploadAdapter adapter = MockUploadAdapter();
      final SmartUploader uploader =
          SmartUploader(adapter: adapter, config: config);

      final UploadTask task = await uploader.upload(file: file);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(task.status, UploadStatus.queued);
      expect(adapter.initializeCalls, 0);

      uploader.start();
      await task.done;
      expect(task.status, UploadStatus.completed);
      await uploader.dispose();
    });

    test('tracks tasks and can forget finished ones', () async {
      final SmartUploader uploader =
          SmartUploader(adapter: MockUploadAdapter(), config: testConfig());

      final UploadTask task =
          await uploader.upload(file: createFile(dir, 'tracked.bin', 512));
      expect(uploader.task(task.id), same(task));
      await task.done;

      expect(uploader.tasks, hasLength(1));
      uploader.clearFinished();
      expect(uploader.tasks, isEmpty);
      await uploader.dispose();
    });

    test('rejects uploads after dispose', () async {
      final SmartUploader uploader =
          SmartUploader(adapter: MockUploadAdapter(), config: testConfig());
      await uploader.dispose();

      expect(
        () => uploader.upload(file: createFile(dir, 'late.bin', 100)),
        throwsA(isA<StateError>()),
      );
    });

    test('a storage that throws does not hang the task', () async {
      final File file = createFile(dir, 'bad-storage.bin', 1024);
      final SmartUploader uploader = SmartUploader(
        adapter: MockUploadAdapter(),
        config: testConfig(storage: _ExplodingStorage()),
      );

      final UploadTask task = await uploader.upload(file: file);

      // The failure surfaces on `done` instead of leaving it unresolved.
      await expectLater(task.done, throwsA(isA<SmartUploadException>()));
      expect(task.status, UploadStatus.failed);
      await uploader.dispose();
    });
  });
}

/// Counts how many uploads are inside the adapter at the same time.
class _ConcurrencyProbeAdapter extends UploadAdapter {
  _ConcurrencyProbeAdapter({this.delay = Duration.zero});

  final Duration delay;
  final Set<String> _inFlight = <String>{};
  int peakConcurrency = 0;

  @override
  Future<UploadSession> initialize(UploadRequest request) async {
    _inFlight.add(request.uploadId);
    peakConcurrency =
        peakConcurrency < _inFlight.length ? _inFlight.length : peakConcurrency;
    return UploadSession(uploadId: request.uploadId);
  }

  @override
  Future<ChunkUploadResult> uploadChunk(
    UploadSession session,
    UploadChunk chunk,
  ) async {
    peakConcurrency =
        peakConcurrency < _inFlight.length ? _inFlight.length : peakConcurrency;
    await Future<void>.delayed(delay);
    return ChunkUploadResult.accepted(chunk);
  }

  @override
  Future<UploadResult> complete(UploadSession session) async {
    _inFlight.remove(session.uploadId);
    return UploadResult(
        uploadId: session.uploadId, url: 'x://${session.uploadId}');
  }

  @override
  Future<void> cancel(UploadSession session) async {
    _inFlight.remove(session.uploadId);
  }
}

/// A storage whose every operation fails with an error the package does not
/// define, standing in for a misbehaving third-party implementation.
class _ExplodingStorage extends UploadStorage {
  @override
  Future<void> save(UploadRecord record) async =>
      throw StateError('disk on fire');

  @override
  Future<UploadRecord?> read(String uploadId) async =>
      throw StateError('disk on fire');

  @override
  Future<List<UploadRecord>> readAll() async =>
      throw StateError('disk on fire');

  @override
  Future<void> delete(String uploadId) async =>
      throw StateError('disk on fire');

  @override
  Future<void> clear() async => throw StateError('disk on fire');
}
