import 'dart:async';
import 'dart:io';

import 'package:flutter_smart_upload/flutter_smart_upload.dart';
import 'package:test/test.dart';

import 'support/test_support.dart';

void main() {
  late Directory dir;

  setUp(() => dir = createTempDir());
  tearDown(() => dir.deleteSync(recursive: true));

  group('monitors', () {
    test('ManualNetworkMonitor reports and notifies', () async {
      final ManualNetworkMonitor monitor = ManualNetworkMonitor();
      final List<bool> seen = <bool>[];
      final StreamSubscription<bool> sub =
          monitor.onConnectivityChanged.listen(seen.add);

      expect(await monitor.isOnline(), isTrue);
      monitor.online = false;
      monitor.online = false; // no duplicate event
      monitor.online = true;
      await Future<void>.delayed(Duration.zero);

      expect(seen, <bool>[false, true]);
      expect(await monitor.isOnline(), isTrue);
      await sub.cancel();
      await monitor.dispose();
    });

    test('StreamNetworkMonitor mirrors its source', () async {
      final StreamController<bool> source = StreamController<bool>();
      final StreamNetworkMonitor monitor = StreamNetworkMonitor(source.stream);
      final List<bool> seen = <bool>[];
      final StreamSubscription<bool> sub =
          monitor.onConnectivityChanged.listen(seen.add);

      source.add(false);
      await Future<void>.delayed(Duration.zero);
      expect(await monitor.isOnline(), isFalse);

      source.add(true);
      await Future<void>.delayed(Duration.zero);
      expect(seen, <bool>[false, true]);

      await sub.cancel();
      await monitor.dispose();
      await source.close();
    });

    test('AlwaysOnlineNetworkMonitor is always online', () async {
      expect(await const AlwaysOnlineNetworkMonitor().isOnline(), isTrue);
    });
  });

  group('offline handling', () {
    test('parks the upload while offline and resumes when back', () async {
      final File file = createFile(dir, 'offline.bin', 8 * 1024);
      final ManualNetworkMonitor monitor = ManualNetworkMonitor();
      final MockUploadAdapter adapter = MockUploadAdapter();
      final SmartUploader uploader = SmartUploader(
        adapter: adapter,
        config: testConfig(
          chunkSize: 1024,
          networkMonitor: monitor,
          waitForNetwork: true,
          networkWaitTimeout: const Duration(seconds: 5),
        ),
      );

      adapter.onChunk = (UploadChunk chunk) async {
        if (chunk.index == 2) monitor.online = false;
      };

      final UploadTask task = await uploader.upload(file: file);
      await task.statusStream.firstWhere(
        (UploadStatus s) => s == UploadStatus.paused,
      );

      expect(task.isWaitingForNetwork, isTrue);
      final int sentWhileOffline = adapter.receivedOrder.length;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(adapter.receivedOrder.length, sentWhileOffline,
          reason: 'nothing is sent while the device is offline');

      monitor.online = true;
      await task.done;

      expect(task.status, UploadStatus.completed);
      expect(task.isWaitingForNetwork, isFalse);
      expect(adapter.storedChunks.keys.toList()..sort(),
          List<int>.generate(8, (int i) => i));
      await uploader.dispose();
      await monitor.dispose();
    });

    test('emits paused with waitingForNetwork, then resumed', () async {
      final File file = createFile(dir, 'events.bin', 4 * 1024);
      final ManualNetworkMonitor monitor = ManualNetworkMonitor();
      final MockUploadAdapter adapter = MockUploadAdapter();
      final SmartUploader uploader = SmartUploader(
        adapter: adapter,
        config: testConfig(
          chunkSize: 1024,
          networkMonitor: monitor,
          waitForNetwork: true,
        ),
      );
      final List<UploadEvent> events = <UploadEvent>[];
      final StreamSubscription<UploadEvent> sub =
          uploader.events.listen(events.add);

      adapter.onChunk = (UploadChunk chunk) async {
        if (chunk.index == 1) monitor.online = false;
      };

      final UploadTask task = await uploader.upload(file: file);
      await task.statusStream
          .firstWhere((UploadStatus s) => s == UploadStatus.paused);
      monitor.online = true;
      await task.done;
      await Future<void>.delayed(Duration.zero);

      final UploadPausedEvent paused =
          events.whereType<UploadPausedEvent>().single;
      expect(paused.waitingForNetwork, isTrue);
      expect(events.whereType<UploadResumedEvent>(), hasLength(1));
      await sub.cancel();
      await uploader.dispose();
      await monitor.dispose();
    });

    test('fails with network_error if connectivity never returns', () async {
      final File file = createFile(dir, 'never.bin', 4 * 1024);
      final ManualNetworkMonitor monitor = ManualNetworkMonitor();
      final MockUploadAdapter adapter = MockUploadAdapter();
      final SmartUploader uploader = SmartUploader(
        adapter: adapter,
        config: testConfig(
          chunkSize: 1024,
          maxRetries: 0,
          networkMonitor: monitor,
          waitForNetwork: true,
          networkWaitTimeout: const Duration(milliseconds: 150),
        ),
      );

      adapter.onChunk = (UploadChunk chunk) async {
        if (chunk.index == 1) monitor.online = false;
      };

      final UploadTask task = await uploader.upload(file: file);

      await expectLater(
        task.done,
        throwsA(isA<SmartUploadException>().having(
          (SmartUploadException e) => e.code,
          'code',
          'network_error',
        )),
      );
      await uploader.dispose();
      await monitor.dispose();
    });

    test('a network error waits for connectivity instead of backing off',
        () async {
      final File file = createFile(dir, 'retry-offline.bin', 3 * 1024);
      final ManualNetworkMonitor monitor = ManualNetworkMonitor();
      final _FlakyNetworkAdapter adapter = _FlakyNetworkAdapter(
        failAt: 1,
        onFail: () => monitor.online = false,
      );
      final SmartUploader uploader = SmartUploader(
        adapter: adapter,
        config: testConfig(
          chunkSize: 1024,
          networkMonitor: monitor,
          waitForNetwork: true,
          networkWaitTimeout: const Duration(seconds: 5),
        ),
      );

      final UploadTask task = await uploader.upload(file: file);
      await task.statusStream
          .firstWhere((UploadStatus s) => s == UploadStatus.paused);
      expect(task.isWaitingForNetwork, isTrue);

      monitor.online = true;
      await task.done;

      expect(task.status, UploadStatus.completed);
      expect(adapter.attempts[1], 2, reason: 'the failed chunk is retried');
      await uploader.dispose();
      await monitor.dispose();
    });

    test('cancelling while offline still works', () async {
      final File file = createFile(dir, 'cancel-offline.bin', 4 * 1024);
      final ManualNetworkMonitor monitor = ManualNetworkMonitor();
      final MockUploadAdapter adapter = MockUploadAdapter();
      final SmartUploader uploader = SmartUploader(
        adapter: adapter,
        config: testConfig(
          chunkSize: 1024,
          networkMonitor: monitor,
          waitForNetwork: true,
          networkWaitTimeout: const Duration(seconds: 10),
        ),
      );

      adapter.onChunk = (UploadChunk chunk) async {
        if (chunk.index == 1) monitor.online = false;
      };

      final UploadTask task = await uploader.upload(file: file);
      await task.statusStream
          .firstWhere((UploadStatus s) => s == UploadStatus.paused);

      await task.cancel();

      expect(task.status, UploadStatus.cancelled);
      await uploader.dispose();
      await monitor.dispose();
    });
  });
}

/// Fails one chunk once, running a side effect (going offline) as it does.
class _FlakyNetworkAdapter extends UploadAdapter {
  _FlakyNetworkAdapter({required this.failAt, required this.onFail});

  final int failAt;
  final void Function() onFail;
  final Map<int, int> attempts = <int, int>{};
  bool _failed = false;

  @override
  Future<UploadSession> initialize(UploadRequest request) async =>
      UploadSession(uploadId: request.uploadId);

  @override
  Future<ChunkUploadResult> uploadChunk(
    UploadSession session,
    UploadChunk chunk,
  ) async {
    attempts[chunk.index] = (attempts[chunk.index] ?? 0) + 1;
    if (chunk.index == failAt && !_failed) {
      _failed = true;
      onFail();
      throw SmartUploadException.network('connection reset');
    }
    return ChunkUploadResult.accepted(chunk);
  }

  @override
  Future<UploadResult> complete(UploadSession session) async =>
      UploadResult(uploadId: session.uploadId, url: 'x://ok');

  @override
  Future<void> cancel(UploadSession session) async {}
}
