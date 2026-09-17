import 'dart:async';
import 'dart:io';

import 'package:flutter_smart_upload/flutter_smart_upload.dart';
import 'package:test/test.dart';

import 'support/test_support.dart';

void main() {
  late Directory dir;

  setUp(() => dir = createTempDir());
  tearDown(() => dir.deleteSync(recursive: true));

  group('pause / resume', () {
    test('pauses mid-transfer and resumes from the next chunk', () async {
      final File file = createFile(dir, 'pause.bin', 8 * 1024);
      final MockUploadAdapter adapter = MockUploadAdapter();
      final MemoryUploadStorage storage = MemoryUploadStorage();
      final SmartUploader uploader = SmartUploader(
        adapter: adapter,
        config: testConfig(chunkSize: 1024, storage: storage),
      );

      late UploadTask task;
      adapter.onChunk = (UploadChunk chunk) async {
        if (chunk.index == 2) unawaited(task.pause());
      };

      task = await uploader.upload(file: file);
      await TaskInternalsProbe.waitFor(task, UploadStatus.paused);

      expect(task.status, UploadStatus.paused);
      final int sentBeforePause = adapter.storedChunks.length;
      expect(sentBeforePause, lessThan(8));

      adapter.onChunk = null;
      await task.resume();
      await task.done;

      expect(task.status, UploadStatus.completed);
      // Every chunk stored exactly once: nothing re-sent after the pause.
      expect(adapter.storedChunks.keys.toList()..sort(),
          List<int>.generate(8, (int i) => i));
      expect(adapter.assembled(), file.readAsBytesSync());
      await uploader.dispose();
    });

    test('pausing a queued task removes it from the queue', () async {
      final File first = createFile(dir, 'a.bin', 4096);
      final File second = createFile(dir, 'b.bin', 4096);
      final SmartUploader uploader = SmartUploader(
        adapter: MockUploadAdapter(
          chunkLatency: const Duration(milliseconds: 20),
        ),
        config: testConfig(chunkSize: 1024, maxConcurrentUploads: 1),
      );

      final UploadTask running = await uploader.upload(file: first);
      final UploadTask queued = await uploader.upload(file: second);

      await queued.pause();
      expect(queued.status, UploadStatus.paused);
      expect(uploader.queuedTasks, isNot(contains(queued)));

      await running.done;
      await queued.resume();
      await queued.done;
      expect(queued.status, UploadStatus.completed);
      await uploader.dispose();
    });

    test('pause emits paused and resume emits resumed', () async {
      final File file = createFile(dir, 'events.bin', 4096);
      final MockUploadAdapter adapter = MockUploadAdapter();
      final SmartUploader uploader =
          SmartUploader(adapter: adapter, config: testConfig(chunkSize: 1024));
      final List<UploadEvent> events = <UploadEvent>[];
      final StreamSubscription<UploadEvent> sub =
          uploader.events.listen(events.add);

      late UploadTask task;
      adapter.onChunk = (UploadChunk chunk) async {
        if (chunk.index == 1) unawaited(task.pause());
      };
      task = await uploader.upload(file: file);
      await TaskInternalsProbe.waitFor(task, UploadStatus.paused);
      adapter.onChunk = null;
      await task.resume();
      await task.done;
      await Future<void>.delayed(Duration.zero);

      expect(events.whereType<UploadPausedEvent>(), hasLength(1));
      expect(events.whereType<UploadResumedEvent>(), hasLength(1));
      await sub.cancel();
      await uploader.dispose();
    });

    test('pauseAll and resumeAll drive every task', () async {
      final List<File> files = <File>[
        for (int i = 0; i < 4; i++) createFile(dir, 'multi$i.bin', 4096),
      ];
      final SmartUploader uploader = SmartUploader(
        adapter: MockUploadAdapter(
          chunkLatency: const Duration(milliseconds: 5),
        ),
        config: testConfig(chunkSize: 1024, maxConcurrentUploads: 2),
      );

      final List<UploadTask> tasks =
          await uploader.uploadMultiple(files: files);
      await uploader.pauseAll();

      expect(
        tasks.every(
            (UploadTask t) => t.status == UploadStatus.paused || t.isFinished),
        isTrue,
      );

      await uploader.resumeAll();
      await Future.wait(tasks.map((UploadTask t) => t.done));
      expect(tasks.every((UploadTask t) => t.status == UploadStatus.completed),
          isTrue);
      await uploader.dispose();
    });
  });

  group('cancel', () {
    test('cancels mid-transfer, stops sending and tells the adapter', () async {
      final File file = createFile(dir, 'cancel.bin', 16 * 1024);
      final MockUploadAdapter adapter = MockUploadAdapter(
        chunkLatency: const Duration(milliseconds: 5),
      );
      final SmartUploader uploader =
          SmartUploader(adapter: adapter, config: testConfig(chunkSize: 1024));

      late UploadTask task;
      adapter.onChunk = (UploadChunk chunk) async {
        if (chunk.index == 3) unawaited(task.cancel());
      };

      task = await uploader.upload(file: file);
      await expectLater(
        task.done,
        throwsA(isA<SmartUploadException>().having(
          (SmartUploadException e) => e.code,
          'code',
          'upload_cancelled',
        )),
      );

      expect(task.status, UploadStatus.cancelled);
      expect(adapter.cancelCalls, 1);
      // The request already on the wire when cancel() lands cannot be unsent,
      // but nothing after it may start.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(adapter.receivedOrder.where((int i) => i > 3), isEmpty,
          reason: 'no further chunks after cancellation');
      expect(adapter.receivedOrder.length, lessThanOrEqualTo(4));
      await uploader.dispose();
    });

    test('cancels a queued task without starting it', () async {
      final File first = createFile(dir, 'first.bin', 4096);
      final File second = createFile(dir, 'second.bin', 4096);
      final MockUploadAdapter adapter = MockUploadAdapter(
        chunkLatency: const Duration(milliseconds: 20),
      );
      final SmartUploader uploader = SmartUploader(
        adapter: adapter,
        config: testConfig(chunkSize: 1024, maxConcurrentUploads: 1),
      );

      final UploadTask running = await uploader.upload(file: first);
      final UploadTask queued = await uploader.upload(file: second);
      await queued.cancel();

      expect(queued.status, UploadStatus.cancelled);
      await running.done;
      expect(adapter.requests, hasLength(1),
          reason: 'the cancelled task never reached the adapter');
      await uploader.dispose();
    });

    test('cancelling a paused task releases its state', () async {
      final File file = createFile(dir, 'paused-cancel.bin', 8192);
      final MockUploadAdapter adapter = MockUploadAdapter();
      final MemoryUploadStorage storage = MemoryUploadStorage();
      final SmartUploader uploader = SmartUploader(
        adapter: adapter,
        config: testConfig(chunkSize: 1024, storage: storage),
      );

      late UploadTask task;
      adapter.onChunk = (UploadChunk chunk) async {
        if (chunk.index == 2) unawaited(task.pause());
      };
      task = await uploader.upload(file: file);
      await TaskInternalsProbe.waitFor(task, UploadStatus.paused);

      await task.cancel();

      expect(task.status, UploadStatus.cancelled);
      expect(adapter.cancelCalls, 1);
      expect(await storage.read(task.id), isNull);
      await uploader.dispose();
    });

    test('cancelAll cancels everything in flight', () async {
      final List<File> files = <File>[
        for (int i = 0; i < 5; i++) createFile(dir, 'bulk$i.bin', 4096),
      ];
      final SmartUploader uploader = SmartUploader(
        adapter: MockUploadAdapter(
          chunkLatency: const Duration(milliseconds: 10),
        ),
        config: testConfig(chunkSize: 1024, maxConcurrentUploads: 2),
      );

      final List<UploadTask> tasks =
          await uploader.uploadMultiple(files: files);
      await uploader.cancelAll();

      expect(tasks.every((UploadTask t) => t.status == UploadStatus.cancelled),
          isTrue);
      await uploader.dispose();
    });

    test('cancelling a finished task is a no-op', () async {
      final File file = createFile(dir, 'done.bin', 512);
      final SmartUploader uploader =
          SmartUploader(adapter: MockUploadAdapter(), config: testConfig());

      final UploadTask task = await uploader.upload(file: file);
      await task.done;
      await task.cancel();

      expect(task.status, UploadStatus.completed);
      await uploader.dispose();
    });
  });
}

/// Small helper so tests can wait for a state without reaching into internals.
class TaskInternalsProbe {
  static Future<void> waitFor(UploadTask task, UploadStatus status) async {
    if (task.status == status) return;
    await task.statusStream.firstWhere((UploadStatus s) => s == status);
  }
}
