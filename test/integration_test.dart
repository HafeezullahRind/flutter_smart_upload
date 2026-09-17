import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_smart_upload/flutter_smart_upload.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

import 'support/test_support.dart';

/// End-to-end journeys that exercise several subsystems at once, the way a
/// real app does — compression feeding chunking feeding retry feeding resume.
void main() {
  late Directory dir;
  late Directory work;

  setUp(() {
    dir = createTempDir('fsu_integration');
    work = createTempDir('fsu_integration_work');
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
    if (work.existsSync()) work.deleteSync(recursive: true);
  });

  test('photo journey: compress, chunk, checksum, upload, verify', () async {
    final img.Image source = img.Image(width: 2400, height: 1600);
    for (int y = 0; y < source.height; y++) {
      for (int x = 0; x < source.width; x++) {
        source.setPixelRgb(x, y, (x * 7) % 256, (y * 11) % 256, (x + y) % 256);
      }
    }
    final File photo = File('${dir.path}/holiday.jpg')
      ..writeAsBytesSync(img.encodeJpg(source, quality: 100));
    final int originalSize = photo.lengthSync();

    final MockUploadAdapter adapter = MockUploadAdapter();
    final SmartUploader uploader = SmartUploader(
      adapter: adapter,
      config: testConfig(
        chunkSize: 64 * 1024,
        compressor: const ImageCompressor(runInIsolate: false),
        checksumMode: ChecksumMode.both,
        tempDirectory: work,
      ),
    );

    final List<UploadStatus> states = <UploadStatus>[];
    final UploadTask task = await uploader.upload(
      file: photo,
      options: const UploadOptions(
        compress: true,
        quality: 80,
        maxWidth: 1920,
        maxHeight: 1920,
      ),
      onStatusChanged: states.add,
    );
    final UploadResult result = await task.done;

    // Compressed well below the original.
    expect(result.fileSize, lessThan(originalSize ~/ 2));
    // Resized to fit the long edge.
    final img.Image uploaded = img.decodeJpg(adapter.assembled())!;
    expect(uploaded.width, 1920);
    expect(uploaded.height, 1280);
    // The whole-file digest covers exactly the bytes that were sent.
    expect(result.checksum, md5.convert(adapter.assembled()).toString());
    // Every chunk carried its own digest.
    expect(adapter.chunkChecksums.values, everyElement(isNotNull));
    expect(states, <UploadStatus>[
      UploadStatus.preparing,
      UploadStatus.compressing,
      UploadStatus.uploading,
      UploadStatus.completed,
    ]);
    expect(work.listSync(), isEmpty, reason: 'temp artefacts are cleaned up');
    await uploader.dispose();
  });

  test('bad-network journey: drop, retry, pause, offline, resume, finish',
      () async {
    final File file = createRandomFile(dir, 'video.mp4', 32 * 1024);
    final Directory stateDir = Directory('${dir.path}/state');
    final ManualNetworkMonitor network = ManualNetworkMonitor();
    final MockUploadAdapter adapter = MockUploadAdapter(
      // Chunk 3 fails twice before going through.
      transientChunkFailures: <int, int>{3: 2},
    );
    final SmartUploader uploader = SmartUploader(
      adapter: adapter,
      config: testConfig(
        chunkSize: 4 * 1024,
        storage: FileUploadStorage(stateDir),
        networkMonitor: network,
        waitForNetwork: true,
        networkWaitTimeout: const Duration(seconds: 5),
        checksumMode: ChecksumMode.file,
      ),
    );

    late UploadTask task;
    adapter.onChunk = (UploadChunk chunk) async {
      if (chunk.index == 5) network.online = false;
    };

    final List<UploadEvent> events = <UploadEvent>[];
    final StreamSubscription<UploadEvent> sub =
        uploader.events.listen(events.add);

    task = await uploader.upload(file: file);

    // Goes offline part-way and parks.
    await task.statusStream
        .firstWhere((UploadStatus s) => s == UploadStatus.paused);
    expect(task.isWaitingForNetwork, isTrue);
    final UploadRecord parked =
        (await FileUploadStorage(stateDir).read(task.id))!;
    expect(parked.uploadedChunkIndices, isNotEmpty);
    expect(parked.checksum, isNotNull);

    // Back online: finishes the job.
    network.online = true;
    final UploadResult result = await task.done;

    expect(task.status, UploadStatus.completed);
    expect(adapter.assembled(), file.readAsBytesSync());
    expect(result.url, isNotNull);
    // Chunk 3 was retried twice; nothing else was sent more than once.
    expect(adapter.receivedOrder.where((int i) => i == 3), hasLength(3));
    expect(
      adapter.storedChunks.keys.toList()..sort(),
      List<int>.generate(8, (int i) => i),
    );
    expect(events.whereType<UploadRetryEvent>(), hasLength(2));
    expect(
        events.whereType<UploadPausedEvent>().single.waitingForNetwork, isTrue);
    await sub.cancel();
    await uploader.dispose();
    await network.dispose();
  });

  test('batch journey: 10 files, 2 at a time, one cancelled mid-flight',
      () async {
    final List<File> files = <File>[
      for (int i = 0; i < 10; i++)
        createRandomFile(dir, 'f$i.bin', 8 * 1024, i),
    ];
    final MockUploadAdapter adapter = MockUploadAdapter(
      chunkLatency: const Duration(milliseconds: 2),
    );
    final SmartUploader uploader = SmartUploader(
      adapter: adapter,
      config: testConfig(
        chunkSize: 2 * 1024,
        maxConcurrentUploads: 2,
        storage: MemoryUploadStorage(),
      ),
    );

    final List<UploadTask> tasks = await uploader.uploadMultiple(files: files);
    await tasks[7].cancel();

    final List<Object?> outcomes = await Future.wait(
      tasks.map(
        (UploadTask t) =>
            t.done.then<Object?>((UploadResult r) => r).catchError(
                  (Object e) => e,
                ),
      ),
    );

    expect(outcomes.whereType<UploadResult>(), hasLength(9));
    expect(
      outcomes[7],
      isA<SmartUploadException>().having(
        (SmartUploadException e) => e.code,
        'code',
        'upload_cancelled',
      ),
    );
    expect(tasks[7].status, UploadStatus.cancelled);
    expect(
      tasks.where((UploadTask t) => t.status == UploadStatus.completed),
      hasLength(9),
    );
    await uploader.onIdle;
    expect(uploader.activeTasks, isEmpty);
    await uploader.dispose();
  });
}
