import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_smart_upload/flutter_smart_upload.dart';
import 'package:test/test.dart';

import 'support/test_support.dart';

void main() {
  late Directory dir;
  late MockUploadAdapter adapter;

  setUp(() {
    dir = createTempDir();
    adapter = MockUploadAdapter();
  });

  tearDown(() => dir.deleteSync(recursive: true));

  group('single-file upload', () {
    test('uploads a small file in one chunk and reports the url', () async {
      final File file = createFile(dir, 'small.txt', 512);
      final SmartUploader uploader =
          SmartUploader(adapter: adapter, config: testConfig());

      final UploadTask task = await uploader.upload(file: file);
      expect(task.status, UploadStatus.queued);

      final UploadResult result = await task.done;

      expect(result.url, 'https://cdn.test/${task.id}');
      expect(task.status, UploadStatus.completed);
      expect(task.url, result.url);
      expect(adapter.receivedOrder, <int>[0]);
      expect(adapter.completeCalls, 1);
      expect(result.fileSize, 512);
      await uploader.dispose();
    });

    test('splits a large file into chunks of the configured size', () async {
      final File file = createFile(dir, 'large.bin', 10 * 1024 + 7);
      final SmartUploader uploader = SmartUploader(
        adapter: adapter,
        config: testConfig(chunkSize: 1024),
      );

      final UploadTask task = await uploader.upload(file: file);
      await task.done;

      // 10 full chunks plus a 7-byte tail.
      expect(adapter.receivedOrder.length, 11);
      expect(adapter.storedChunks[0]!.length, 1024);
      expect(adapter.storedChunks[10]!.length, 7);
      await uploader.dispose();
    });

    test('delivers chunks in ascending order and reassembles exactly',
        () async {
      final File file = createRandomFile(dir, 'random.bin', 5000);
      final SmartUploader uploader = SmartUploader(
        adapter: adapter,
        config: testConfig(chunkSize: 700),
      );

      await (await uploader.upload(file: file)).done;

      expect(
        adapter.receivedOrder,
        List<int>.generate(adapter.receivedOrder.length, (int i) => i),
        reason: 'chunks must arrive in ascending index order',
      );
      expect(adapter.assembled(), file.readAsBytesSync());
      await uploader.dispose();
    });

    test('honours a server-mandated chunk size', () async {
      final File file = createFile(dir, 'server-chunked.bin', 4096);
      final MockUploadAdapter server = MockUploadAdapter(serverChunkSize: 2048);
      final SmartUploader uploader = SmartUploader(
        adapter: server,
        config: testConfig(chunkSize: 512),
      );

      await (await uploader.upload(file: file)).done;

      expect(server.receivedOrder.length, 2);
      expect(server.storedChunks[0]!.length, 2048);
      await uploader.dispose();
    });

    test('passes file name, size and content type to the adapter', () async {
      final File file = createFile(dir, 'photo.jpg', 100);
      final SmartUploader uploader =
          SmartUploader(adapter: adapter, config: testConfig());

      await (await uploader.upload(file: file)).done;

      final UploadRequest request = adapter.requests.single;
      expect(request.fileName, 'photo.jpg');
      expect(request.fileSize, 100);
      expect(request.contentType, 'image/jpeg');
      expect(request.totalChunks, 1);
      await uploader.dispose();
    });

    test('applies UploadOptions overrides', () async {
      final File file = createFile(dir, 'doc.pdf', 3000);
      final SmartUploader uploader =
          SmartUploader(adapter: adapter, config: testConfig(chunkSize: 4096));

      await (await uploader.upload(
        file: file,
        options: const UploadOptions(
          fileName: 'renamed.pdf',
          contentType: 'application/x-custom',
          chunkSize: 1000,
          metadata: <String, String>{'album': 'holiday'},
        ),
      ))
          .done;

      final UploadRequest request = adapter.requests.single;
      expect(request.fileName, 'renamed.pdf');
      expect(request.contentType, 'application/x-custom');
      expect(request.chunkSize, 1000);
      expect(request.totalChunks, 3);
      expect(request.metadata['album'], 'holiday');
      await uploader.dispose();
    });
  });

  group('progress', () {
    test('reports byte-accurate progress that ends at 100%', () async {
      final File file = createFile(dir, 'progress.bin', 4096);
      final SmartUploader uploader = SmartUploader(
        adapter: MockUploadAdapter(
          chunkLatency: const Duration(milliseconds: 5),
        ),
        config: testConfig(chunkSize: 1024),
      );
      final List<UploadProgress> updates = <UploadProgress>[];

      final UploadTask task = await uploader.upload(
        file: file,
        onProgress: updates.add,
      );
      await task.done;

      expect(updates, isNotEmpty);
      expect(updates.first.uploadedBytes, 0);
      expect(updates.last.uploadedBytes, 4096);
      expect(updates.last.percentage, 100);
      expect(updates.last.fraction, 1.0);
      final List<int> byteCounts =
          updates.map((UploadProgress p) => p.uploadedBytes).toList();
      for (int i = 1; i < byteCounts.length; i++) {
        expect(byteCounts[i], greaterThanOrEqualTo(byteCounts[i - 1]),
            reason: 'progress must never go backwards');
      }
      expect(task.progress.percentage, 100);
      await uploader.dispose();
    });

    test('measures a non-zero transfer rate and an ETA', () async {
      final File file = createFile(dir, 'speed.bin', 8192);
      final SmartUploader uploader = SmartUploader(
        adapter: MockUploadAdapter(
          chunkLatency: const Duration(milliseconds: 10),
        ),
        config: testConfig(chunkSize: 1024),
      );
      final List<UploadProgress> updates = <UploadProgress>[];

      await (await uploader.upload(file: file, onProgress: updates.add)).done;

      final UploadProgress middle = updates[updates.length ~/ 2];
      expect(middle.bytesPerSecond, greaterThan(0));
      expect(middle.estimatedRemaining, isNotNull);
      expect(updates.last.elapsed, greaterThan(Duration.zero));
      await uploader.dispose();
    });

    test('progress is based on bytes, not chunk count', () async {
      // A 3.5-chunk file: chunk-counting would report 75% after three chunks,
      // byte-counting reports 3072/3584 = 85.7%.
      final File file = createFile(dir, 'uneven.bin', 3584);
      final SmartUploader uploader =
          SmartUploader(adapter: adapter, config: testConfig(chunkSize: 1024));
      final List<double> percentages = <double>[];

      await (await uploader.upload(
        file: file,
        onProgress: (UploadProgress p) => percentages.add(p.percentage),
      ))
          .done;

      expect(percentages, contains(closeTo(85.71, 0.01)));
      await uploader.dispose();
    });
  });

  group('status transitions', () {
    test('runs queued -> preparing -> uploading -> completed', () async {
      final File file = createFile(dir, 'states.bin', 1000);
      final SmartUploader uploader =
          SmartUploader(adapter: adapter, config: testConfig());
      final List<UploadStatus> states = <UploadStatus>[];

      final UploadTask task = await uploader.upload(
        file: file,
        onStatusChanged: states.add,
      );
      await task.done;

      expect(states, <UploadStatus>[
        UploadStatus.preparing,
        UploadStatus.uploading,
        UploadStatus.completed,
      ]);
      await uploader.dispose();
    });
  });

  group('events', () {
    test('publishes the full event sequence', () async {
      final File file = createFile(dir, 'events.bin', 2048);
      final SmartUploader uploader =
          SmartUploader(adapter: adapter, config: testConfig(chunkSize: 1024));
      final List<UploadEvent> events = <UploadEvent>[];
      final StreamSubscription<UploadEvent> sub =
          uploader.events.listen(events.add);

      await (await uploader.upload(file: file)).done;
      await Future<void>.delayed(Duration.zero);

      expect(events.whereType<UploadQueuedEvent>(), hasLength(1));
      expect(events.whereType<UploadPreparingEvent>(), hasLength(1));
      expect(events.whereType<UploadStartedEvent>(), hasLength(1));
      expect(events.whereType<UploadChunkCompletedEvent>(), hasLength(2));
      expect(events.whereType<UploadProgressEvent>(), isNotEmpty);
      expect(events.whereType<UploadCompletedEvent>(), hasLength(1));
      await sub.cancel();
      await uploader.dispose();
    });
  });

  group('invalid input', () {
    test('rejects a missing file at the call site', () async {
      final SmartUploader uploader =
          SmartUploader(adapter: adapter, config: testConfig());

      expect(
        () => uploader.upload(file: File('${dir.path}/nope.bin')),
        throwsA(isA<SmartUploadException>().having(
          (SmartUploadException e) => e.code,
          'code',
          'file_not_found',
        )),
      );
      await uploader.dispose();
    });

    test('rejects an empty file', () async {
      final File empty = File('${dir.path}/empty.bin')
        ..writeAsBytesSync(Uint8List(0));
      final SmartUploader uploader =
          SmartUploader(adapter: adapter, config: testConfig());

      expect(
        () => uploader.upload(file: empty),
        throwsA(isA<SmartUploadException>().having(
          (SmartUploadException e) => e.code,
          'code',
          'invalid_file',
        )),
      );
      await uploader.dispose();
    });
  });
}
