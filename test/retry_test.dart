import 'dart:io';

import 'package:flutter_smart_upload/flutter_smart_upload.dart';
import 'package:test/test.dart';

import 'support/test_support.dart';

void main() {
  late Directory dir;

  setUp(() => dir = createTempDir());
  tearDown(() => dir.deleteSync(recursive: true));

  group('chunk retries', () {
    test('retries only the failed chunk and keeps the others', () async {
      final File file = createFile(dir, 'retry.bin', 4096);
      final MockUploadAdapter adapter = MockUploadAdapter(
        transientChunkFailures: <int, int>{2: 2},
      );
      final SmartUploader uploader =
          SmartUploader(adapter: adapter, config: testConfig(chunkSize: 1024));

      await (await uploader.upload(file: file)).done;

      // Chunk 2 was sent three times; every other chunk exactly once.
      expect(adapter.receivedOrder, <int>[0, 1, 2, 2, 2, 3]);
      expect(adapter.storedChunks.keys.toList()..sort(), <int>[0, 1, 2, 3]);
      await uploader.dispose();
    });

    test('fails after exhausting retries and reports the cause', () async {
      final File file = createFile(dir, 'doomed.bin', 2048);
      final MockUploadAdapter adapter =
          MockUploadAdapter(permanentChunkFailure: 1);
      final SmartUploader uploader = SmartUploader(
        adapter: adapter,
        config: testConfig(chunkSize: 1024, maxRetries: 2),
      );

      final UploadTask task = await uploader.upload(file: file);

      await expectLater(
        task.done,
        throwsA(isA<SmartUploadException>()
            .having((SmartUploadException e) => e.code, 'code', 'server_error')
            .having((SmartUploadException e) => e.isRetryable, 'retryable',
                isTrue)),
      );
      expect(task.status, UploadStatus.failed);
      // Initial attempt plus two retries.
      expect(adapter.receivedOrder.where((int i) => i == 1), hasLength(3));
      await uploader.dispose();
    });

    test('does not retry permanent errors', () async {
      final File file = createFile(dir, 'auth.bin', 2048);
      final MockUploadAdapter adapter = MockUploadAdapter(
        permanentChunkFailure: 0,
        failChunkWith: SmartUploadException.authentication('bad token'),
      );
      final SmartUploader uploader = SmartUploader(
        adapter: adapter,
        config: testConfig(chunkSize: 1024, maxRetries: 5),
      );

      final UploadTask task = await uploader.upload(file: file);
      await expectLater(
        task.done,
        throwsA(isA<SmartUploadException>().having(
          (SmartUploadException e) => e.code,
          'code',
          'authentication_error',
        )),
      );
      expect(adapter.receivedOrder, <int>[0], reason: 'no retry attempts');
      await uploader.dispose();
    });

    test('retries a failing initialize', () async {
      final File file = createFile(dir, 'init.bin', 1024);
      final MockUploadAdapter adapter =
          MockUploadAdapter(initializeFailures: 2);
      final SmartUploader uploader =
          SmartUploader(adapter: adapter, config: testConfig());

      await (await uploader.upload(file: file)).done;

      expect(adapter.initializeCalls, 3);
      await uploader.dispose();
    });

    test('retries a failing complete', () async {
      final File file = createFile(dir, 'complete.bin', 1024);
      final MockUploadAdapter adapter = MockUploadAdapter(completeFailures: 1);
      final SmartUploader uploader =
          SmartUploader(adapter: adapter, config: testConfig());

      final UploadResult result =
          await (await uploader.upload(file: file)).done;

      expect(adapter.completeCalls, 2);
      expect(result.url, isNotNull);
      await uploader.dispose();
    });

    test('emits a retry event for every attempt', () async {
      final File file = createFile(dir, 'events.bin', 1024);
      final MockUploadAdapter adapter =
          MockUploadAdapter(transientChunkFailures: <int, int>{0: 2});
      final SmartUploader uploader =
          SmartUploader(adapter: adapter, config: testConfig());
      final List<UploadRetryEvent> retries = <UploadRetryEvent>[];
      final sub = uploader.events
          .where((UploadEvent e) => e is UploadRetryEvent)
          .cast<UploadRetryEvent>()
          .listen(retries.add);

      await (await uploader.upload(file: file)).done;
      await Future<void>.delayed(Duration.zero);

      expect(retries, hasLength(2));
      expect(retries.first.attempt, 1);
      expect(retries.last.attempt, 2);
      expect(retries.first.chunkIndex, 0);
      await sub.cancel();
      await uploader.dispose();
    });

    test('adapter can veto a retry', () async {
      final File file = createFile(dir, 'veto.bin', 1024);
      final SmartUploader uploader = SmartUploader(
        adapter: _NeverRetryAdapter(),
        config: testConfig(maxRetries: 5),
      );

      final UploadTask task = await uploader.upload(file: file);
      await expectLater(task.done, throwsA(isA<SmartUploadException>()));
      expect((uploader.adapter as _NeverRetryAdapter).attempts, 1);
      await uploader.dispose();
    });
  });

  group('ExponentialBackoffRetryPolicy', () {
    test('doubles the delay on each attempt', () {
      final ExponentialBackoffRetryPolicy policy =
          ExponentialBackoffRetryPolicy(
        initialDelay: const Duration(seconds: 2),
        jitter: 0,
      );

      Duration delay(int attempt) => policy.delayFor(RetryContext(
            attempt: attempt,
            error: SmartUploadException.server('x'),
            elapsed: Duration.zero,
          ));

      expect(delay(1), const Duration(seconds: 2));
      expect(delay(2), const Duration(seconds: 4));
      expect(delay(3), const Duration(seconds: 8));
    });

    test('caps the delay at maxDelay', () {
      final ExponentialBackoffRetryPolicy policy =
          ExponentialBackoffRetryPolicy(
        initialDelay: const Duration(seconds: 2),
        maxDelay: const Duration(seconds: 5),
        jitter: 0,
      );
      expect(
        policy.delayFor(RetryContext(
          attempt: 10,
          error: SmartUploadException.server('x'),
          elapsed: Duration.zero,
        )),
        const Duration(seconds: 5),
      );
    });

    test('applies jitter within bounds', () {
      final ExponentialBackoffRetryPolicy policy =
          ExponentialBackoffRetryPolicy(
        initialDelay: const Duration(seconds: 10),
        jitter: 0.2,
      );
      for (int i = 0; i < 50; i++) {
        final Duration delay = policy.delayFor(RetryContext(
          attempt: 1,
          error: SmartUploadException.server('x'),
          elapsed: Duration.zero,
        ));
        expect(delay.inMilliseconds, inInclusiveRange(8000, 12000));
      }
    });

    test('stops after maxRetries', () {
      final ExponentialBackoffRetryPolicy policy =
          ExponentialBackoffRetryPolicy(maxRetries: 2);
      RetryContext at(int attempt) => RetryContext(
            attempt: attempt,
            error: SmartUploadException.server('x'),
            elapsed: Duration.zero,
          );
      expect(policy.shouldRetry(at(1)), isTrue);
      expect(policy.shouldRetry(at(2)), isTrue);
      expect(policy.shouldRetry(at(3)), isFalse);
    });

    test('refuses permanent errors regardless of attempt', () {
      final ExponentialBackoffRetryPolicy policy =
          ExponentialBackoffRetryPolicy(maxRetries: 5);
      expect(
        policy.shouldRetry(RetryContext(
          attempt: 1,
          error: SmartUploadException.authentication('nope'),
          elapsed: Duration.zero,
        )),
        isFalse,
      );
    });

    test('NoRetryPolicy never retries', () {
      const NoRetryPolicy policy = NoRetryPolicy();
      expect(
        policy.shouldRetry(RetryContext(
          attempt: 1,
          error: SmartUploadException.server('x'),
          elapsed: Duration.zero,
        )),
        isFalse,
      );
    });
  });

  group('error classification', () {
    test('network, timeout and server errors are retryable', () {
      expect(SmartUploadException.network('x').isRetryable, isTrue);
      expect(SmartUploadException.timeout('x').isRetryable, isTrue);
      expect(SmartUploadException.server('x').isRetryable, isTrue);
    });

    test('auth, invalid file and cancellation are not', () {
      expect(SmartUploadException.authentication('x').isRetryable, isFalse);
      expect(SmartUploadException.invalidFile('x').isRetryable, isFalse);
      expect(SmartUploadException.cancelled().isRetryable, isFalse);
      expect(SmartUploadException.fileNotFound('x').isRetryable, isFalse);
    });

    test('retryability can be overridden', () {
      expect(
        SmartUploadException.authentication('refreshable')
            .asRetryable()
            .isRetryable,
        isTrue,
      );
    });

    test('wrap preserves an existing SmartUploadException', () {
      final SmartUploadException original = SmartUploadException.server('x');
      expect(identical(SmartUploadException.wrap(original), original), isTrue);
    });
  });
}

/// An adapter whose errors are always classified as permanent.
class _NeverRetryAdapter extends UploadAdapter {
  int attempts = 0;

  @override
  Future<UploadSession> initialize(UploadRequest request) async =>
      UploadSession(uploadId: request.uploadId);

  @override
  Future<ChunkUploadResult> uploadChunk(
    UploadSession session,
    UploadChunk chunk,
  ) async {
    attempts++;
    throw SmartUploadException.server('down');
  }

  @override
  Future<UploadResult> complete(UploadSession session) async =>
      UploadResult(uploadId: session.uploadId);

  @override
  Future<void> cancel(UploadSession session) async {}

  @override
  bool isRetryable(Object error) => false;
}
