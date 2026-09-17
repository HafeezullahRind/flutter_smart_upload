import 'dart:convert';
import 'dart:io';

import 'package:flutter_smart_upload/flutter_smart_upload.dart';
import 'package:test/test.dart';

import 'support/test_support.dart';

void main() {
  late Directory dir;

  setUp(() => dir = createTempDir());
  tearDown(() => dir.deleteSync(recursive: true));

  group('MemoryUploadStorage', () {
    test('saves, reads, lists and deletes', () async {
      final MemoryUploadStorage storage = MemoryUploadStorage();
      final UploadRecord record = _record('a');

      await storage.save(record);
      expect((await storage.read('a'))!.uploadId, 'a');

      await storage.save(_record('b'));
      expect(await storage.readAll(), hasLength(2));

      await storage.delete('a');
      expect(await storage.read('a'), isNull);

      await storage.clear();
      expect(await storage.readAll(), isEmpty);
    });

    test('readAll returns newest first', () async {
      final MemoryUploadStorage storage = MemoryUploadStorage();
      final DateTime now = DateTime.now();
      await storage.save(
          _record('old', createdAt: now.subtract(const Duration(hours: 1))));
      await storage.save(_record('new', createdAt: now));

      expect(
        (await storage.readAll()).map((UploadRecord r) => r.uploadId),
        <String>['new', 'old'],
      );
    });
  });

  group('FileUploadStorage', () {
    test('survives being recreated over the same directory', () async {
      final Directory storeDir = Directory('${dir.path}/state');
      await FileUploadStorage(storeDir).save(_record('persisted'));

      final UploadRecord? read =
          await FileUploadStorage(storeDir).read('persisted');

      expect(read, isNotNull);
      expect(read!.fileName, 'file.bin');
      expect(read.uploadedChunkIndices, <int>{0, 1});
    });

    test('round-trips every field', () async {
      final FileUploadStorage storage =
          FileUploadStorage(Directory('${dir.path}/full'));
      final UploadRecord original = UploadRecord(
        uploadId: 'full',
        sourcePath: '/tmp/a.jpg',
        uploadPath: '/tmp/a_compressed.jpg',
        fileName: 'a.jpg',
        fileSize: 1000,
        uploadSize: 400,
        contentType: 'image/jpeg',
        status: UploadStatus.paused,
        checksum: 'abc',
        checksumAlgorithm: 'md5',
        chunkSize: 128,
        totalChunks: 4,
        uploadedChunkIndices: const <int>{0, 2},
        uploadedBytes: 256,
        session: const UploadSession(
          uploadId: 'full',
          sessionId: 'srv-1',
          uploadUrl: 'https://example.com/u/1',
          uploadedChunkIndices: <int>{0, 2},
          uploadedBytes: 256,
          headers: <String, String>{'x-token': 'abc'},
          data: <String, Object?>{
            'parts': <Object?>[1, 2]
          },
        ),
        options: const UploadOptions(
          compress: true,
          quality: 70,
          maxWidth: 800,
          metadata: <String, String>{'k': 'v'},
          checksum: ChecksumMode.file,
          priority: 5,
        ),
        errorMessage: 'boom',
        errorCode: 'server_error',
        attempts: 2,
        createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
        updatedAt: DateTime.utc(2026, 1, 2, 3, 4, 6),
      );

      await storage.save(original);
      final UploadRecord read = (await storage.read('full'))!;

      expect(read.toJson(), original.toJson());
      expect(read.session!.data['parts'], <Object?>[1, 2]);
      expect(read.options.quality, 70);
      expect(read.options.metadata['k'], 'v');
      expect(read.options.checksum, ChecksumMode.file);
      expect(read.status, UploadStatus.paused);
    });

    test('discards a corrupt record instead of failing every read', () async {
      final Directory storeDir = Directory('${dir.path}/corrupt')
        ..createSync(recursive: true);
      File('${storeDir.path}/broken.json').writeAsStringSync('{not json');
      final FileUploadStorage storage = FileUploadStorage(storeDir);
      await storage.save(_record('good'));

      final List<UploadRecord> all = await storage.readAll();

      expect(all.map((UploadRecord r) => r.uploadId), <String>['good']);
      expect(File('${storeDir.path}/broken.json').existsSync(), isFalse);
    });

    test('writes atomically, leaving no temp files behind', () async {
      final Directory storeDir = Directory('${dir.path}/atomic');
      final FileUploadStorage storage = FileUploadStorage(storeDir);

      await storage.save(_record('x'));
      await storage.save(_record('x'));

      final List<String> files = storeDir
          .listSync()
          .map((FileSystemEntity e) => e.path.split('/').last)
          .toList();
      expect(files, <String>['x.json']);
      expect(
        jsonDecode(File('${storeDir.path}/x.json').readAsStringSync()),
        isA<Map<String, Object?>>(),
      );
    });

    test('clear removes everything', () async {
      final FileUploadStorage storage =
          FileUploadStorage(Directory('${dir.path}/clear'));
      await storage.save(_record('a'));
      await storage.save(_record('b'));

      await storage.clear();

      expect(await storage.readAll(), isEmpty);
    });
  });

  group('resume', () {
    test('continues from the first chunk the server does not hold', () async {
      final File file = createRandomFile(dir, 'resume.bin', 8 * 1024);
      final MemoryUploadStorage storage = MemoryUploadStorage();
      final MockUploadAdapter adapter = MockUploadAdapter(
        permanentChunkFailure: 4,
      );
      final SmartUploader uploader = SmartUploader(
        adapter: adapter,
        config: testConfig(
          chunkSize: 1024,
          storage: storage,
          maxRetries: 0,
          deleteRecordOnSuccess: false,
        ),
      );

      final UploadTask failed = await uploader.upload(file: file);
      await expectLater(failed.done, throwsA(isA<SmartUploadException>()));

      final UploadRecord record = (await storage.read(failed.id))!;
      expect(record.status, UploadStatus.failed);
      expect(record.uploadedChunkIndices, <int>{0, 1, 2, 3});
      expect(record.uploadedBytes, 4096);

      // The server recovers; resume must not resend chunks 0-3.
      final MockUploadAdapter recovered = MockUploadAdapter();
      final SmartUploader second = SmartUploader(
        adapter: recovered,
        config: testConfig(
          chunkSize: 1024,
          storage: storage,
          deleteRecordOnSuccess: false,
        ),
      );

      final UploadTask resumed = await second.resume(failed.id);
      await resumed.done;

      expect(recovered.restoreCalls, 1);
      expect(recovered.initializeCalls, 0,
          reason: 'a live session is restored, not recreated');
      expect(recovered.receivedOrder, <int>[4, 5, 6, 7]);
      expect(resumed.status, UploadStatus.completed);
      await uploader.dispose();
      await second.dispose();
    });

    test('progress starts from the resumed baseline, not zero', () async {
      final File file = createFile(dir, 'baseline.bin', 8 * 1024);
      final MemoryUploadStorage storage = MemoryUploadStorage();
      final SmartUploader first = SmartUploader(
        adapter: MockUploadAdapter(permanentChunkFailure: 6),
        config: testConfig(chunkSize: 1024, storage: storage, maxRetries: 0),
      );

      final UploadTask failed = await first.upload(file: file);
      await expectLater(failed.done, throwsA(isA<SmartUploadException>()));

      final SmartUploader second = SmartUploader(
        adapter: MockUploadAdapter(),
        config: testConfig(chunkSize: 1024, storage: storage),
      );
      final List<UploadProgress> updates = <UploadProgress>[];
      final UploadTask resumed =
          await second.resume(failed.id, onProgress: updates.add);
      await resumed.done;

      expect(updates.first.uploadedBytes, 6 * 1024);
      expect(updates.first.percentage, closeTo(75, 0.01));
      expect(updates.last.percentage, 100);
      await first.dispose();
      await second.dispose();
    });

    test('survives a simulated app restart', () async {
      final File file = createRandomFile(dir, 'restart.bin', 6 * 1024);
      final Directory stateDir = Directory('${dir.path}/state');

      // First "app run": fails halfway and the process ends.
      final SmartUploader before = SmartUploader(
        adapter: MockUploadAdapter(permanentChunkFailure: 3),
        config: testConfig(
          chunkSize: 1024,
          storage: FileUploadStorage(stateDir),
          maxRetries: 0,
        ),
      );
      final UploadTask crashed = await before.upload(file: file);
      await expectLater(crashed.done, throwsA(isA<SmartUploadException>()));
      await before.dispose();

      // Second "app run": a brand new uploader, sharing only the directory.
      final MockUploadAdapter adapter = MockUploadAdapter();
      final SmartUploader after = SmartUploader(
        adapter: adapter,
        config: testConfig(
          chunkSize: 1024,
          storage: FileUploadStorage(stateDir),
        ),
      );

      final List<UploadRecord> pending = await after.pendingUploads();
      expect(pending, hasLength(1));
      expect(pending.single.fileName, 'restart.bin');

      final UploadTask resumed = await after.resume(pending.single.uploadId);
      await resumed.done;

      expect(adapter.receivedOrder, <int>[3, 4, 5]);
      expect(await after.pendingUploads(), isEmpty,
          reason: 'a completed upload is no longer pending');
      await after.dispose();
    });

    test('skips chunks the server reports as already stored', () async {
      final File file = createFile(dir, 'server-state.bin', 5 * 1024);
      final MockUploadAdapter adapter = MockUploadAdapter(
        reportUploadedChunks: const <int>{0, 1, 2},
      );
      final SmartUploader uploader = SmartUploader(
        adapter: adapter,
        config: testConfig(chunkSize: 1024),
      );

      await (await uploader.upload(file: file)).done;

      expect(adapter.receivedOrder, <int>[3, 4]);
      await uploader.dispose();
    });

    test('starts over when the server has forgotten the session', () async {
      final File file = createFile(dir, 'expired.bin', 4 * 1024);
      final MemoryUploadStorage storage = MemoryUploadStorage();
      final SmartUploader first = SmartUploader(
        adapter: MockUploadAdapter(permanentChunkFailure: 2),
        config: testConfig(chunkSize: 1024, storage: storage, maxRetries: 0),
      );
      final UploadTask failed = await first.upload(file: file);
      await expectLater(failed.done, throwsA(isA<SmartUploadException>()));

      final MockUploadAdapter adapter = MockUploadAdapter(resumeFails: true);
      final SmartUploader second = SmartUploader(
        adapter: adapter,
        config: testConfig(chunkSize: 1024, storage: storage),
      );

      final UploadTask resumed = await second.resume(failed.id);
      await resumed.done;

      expect(adapter.restoreCalls, 1);
      expect(adapter.initializeCalls, 1, reason: 'falls back to a new session');
      expect(adapter.receivedOrder, <int>[0, 1, 2, 3],
          reason: 'a fresh session means a fresh transfer');
      await first.dispose();
      await second.dispose();
    });

    test('refuses to resume when the file changed underneath', () async {
      final File file = createRandomFile(dir, 'mutable.bin', 4 * 1024);
      final MemoryUploadStorage storage = MemoryUploadStorage();
      final SmartUploader first = SmartUploader(
        adapter: MockUploadAdapter(permanentChunkFailure: 2),
        config: testConfig(
          chunkSize: 1024,
          storage: storage,
          maxRetries: 0,
          checksumMode: ChecksumMode.file,
        ),
      );
      final UploadTask failed = await first.upload(file: file);
      await expectLater(failed.done, throwsA(isA<SmartUploadException>()));

      createRandomFile(dir, 'mutable.bin', 4 * 1024, 99);

      final SmartUploader second = SmartUploader(
        adapter: MockUploadAdapter(),
        config: testConfig(
          chunkSize: 1024,
          storage: storage,
          checksumMode: ChecksumMode.file,
        ),
      );
      final UploadTask resumed = await second.resume(failed.id);

      await expectLater(
        resumed.done,
        throwsA(isA<SmartUploadException>().having(
          (SmartUploadException e) => e.code,
          'code',
          'checksum_mismatch',
        )),
      );
      await first.dispose();
      await second.dispose();
    });

    test('reports a missing source file rather than resuming blindly',
        () async {
      final File file = createFile(dir, 'deleted.bin', 2048);
      final MemoryUploadStorage storage = MemoryUploadStorage();
      final SmartUploader uploader = SmartUploader(
        adapter: MockUploadAdapter(permanentChunkFailure: 1),
        config: testConfig(chunkSize: 1024, storage: storage, maxRetries: 0),
      );
      final UploadTask failed = await uploader.upload(file: file);
      await expectLater(failed.done, throwsA(isA<SmartUploadException>()));

      file.deleteSync();

      expect(
        () => uploader.resume(failed.id),
        throwsA(isA<SmartUploadException>().having(
          (SmartUploadException e) => e.code,
          'code',
          'resume_failed',
        )),
      );
      await uploader.dispose();
    });

    test('resuming an unknown id fails clearly', () async {
      final SmartUploader uploader =
          SmartUploader(adapter: MockUploadAdapter(), config: testConfig());

      expect(
        () => uploader.resume('does-not-exist'),
        throwsA(isA<SmartUploadException>().having(
          (SmartUploadException e) => e.code,
          'code',
          'resume_failed',
        )),
      );
      await uploader.dispose();
    });

    test('a completed upload leaves no record behind by default', () async {
      final File file = createFile(dir, 'clean.bin', 2048);
      final MemoryUploadStorage storage = MemoryUploadStorage();
      final SmartUploader uploader = SmartUploader(
        adapter: MockUploadAdapter(),
        config: testConfig(chunkSize: 1024, storage: storage),
      );

      final UploadTask task = await uploader.upload(file: file);
      await task.done;

      expect(await storage.read(task.id), isNull);
      await uploader.dispose();
    });

    test('deleteRecordOnSuccess: false keeps a history entry', () async {
      final File file = createFile(dir, 'history.bin', 2048);
      final MemoryUploadStorage storage = MemoryUploadStorage();
      final SmartUploader uploader = SmartUploader(
        adapter: MockUploadAdapter(),
        config: testConfig(
          chunkSize: 1024,
          storage: storage,
          deleteRecordOnSuccess: false,
        ),
      );

      final UploadTask task = await uploader.upload(file: file);
      await task.done;

      final UploadRecord record = (await storage.read(task.id))!;
      expect(record.status, UploadStatus.completed);
      expect(await uploader.pendingUploads(), isEmpty);
      await uploader.dispose();
    });
  });
}

UploadRecord _record(String id, {DateTime? createdAt}) => UploadRecord(
      uploadId: id,
      sourcePath: '/tmp/file.bin',
      uploadPath: '/tmp/file.bin',
      fileName: 'file.bin',
      fileSize: 2048,
      uploadSize: 2048,
      contentType: 'application/octet-stream',
      status: UploadStatus.paused,
      chunkSize: 1024,
      totalChunks: 2,
      uploadedChunkIndices: const <int>{0, 1},
      uploadedBytes: 2048,
      createdAt: createdAt ?? DateTime.now(),
      updatedAt: createdAt ?? DateTime.now(),
    );
