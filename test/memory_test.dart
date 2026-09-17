@Tags(<String>['memory'])
library;

import 'dart:io';

import 'package:flutter_smart_upload/flutter_smart_upload.dart';
import 'package:test/test.dart';

import 'support/test_support.dart';

/// Writes a file of [size] bytes without ever holding it in memory.
File writeLargeFile(Directory dir, String name, int size) {
  final File file = File('${dir.path}/$name');
  final RandomAccessFile handle = file.openSync(mode: FileMode.write);
  final List<int> block = List<int>.filled(1024 * 1024, 42);
  int written = 0;
  while (written < size) {
    final int take =
        size - written < block.length ? size - written : block.length;
    handle.writeFromSync(block, 0, take);
    written += take;
  }
  handle.closeSync();
  return file;
}

void main() {
  late Directory dir;

  setUp(() => dir = createTempDir());
  tearDown(() => dir.deleteSync(recursive: true));

  group('memory efficiency', () {
    test('hands the adapter one chunk at a time, whatever the file size',
        () async {
      const int fileSize = 16 * 1024 * 1024;
      const int chunkSize = 1024 * 1024;
      final File file = writeLargeFile(dir, 'large.bin', fileSize);

      int biggestChunk = 0;
      int chunksSeen = 0;
      final _DiscardingAdapter adapter = _DiscardingAdapter(
        onChunk: (UploadChunk chunk) {
          chunksSeen++;
          if (chunk.size > biggestChunk) biggestChunk = chunk.size;
        },
      );
      final SmartUploader uploader = SmartUploader(
        adapter: adapter,
        config: testConfig(chunkSize: chunkSize),
      );

      await (await uploader.upload(file: file)).done;

      expect(chunksSeen, fileSize ~/ chunkSize);
      expect(biggestChunk, chunkSize,
          reason: 'no buffer larger than one chunk is ever produced');
      expect(adapter.received, fileSize);
      await uploader.dispose();
    });

    test('RSS stays far below the file size while uploading', () async {
      const int fileSize = 64 * 1024 * 1024;
      const int chunkSize = 1024 * 1024;
      final File file = writeLargeFile(dir, 'huge.bin', fileSize);

      final int before = ProcessInfo.currentRss;
      final SmartUploader uploader = SmartUploader(
        adapter: _DiscardingAdapter(),
        config: testConfig(chunkSize: chunkSize),
      );

      await (await uploader.upload(file: file)).done;
      final int growth = ProcessInfo.currentRss - before;

      // Reading the file into memory would cost 64 MB; the streaming path
      // should not come close.
      expect(
        growth,
        lessThan(24 * 1024 * 1024),
        reason: 'RSS grew by ${(growth / 1024 / 1024).toStringAsFixed(1)} MB '
            'while uploading a 64 MB file',
      );
      await uploader.dispose();
    },
        // RSS is process-wide, and `dart test` runs suites in parallel
        // isolates of one process, so a neighbouring suite's allocations would
        // be counted here. Run this one on its own:
        //   FSU_MEMORY_TEST=1 dart test test/memory_test.dart
        skip: Platform.environment['FSU_MEMORY_TEST'] == null
            ? 'Set FSU_MEMORY_TEST=1 and run this suite alone (RSS is '
                'process-wide).'
            : null);
  });
}

/// An adapter that counts bytes and immediately forgets them.
class _DiscardingAdapter extends UploadAdapter {
  _DiscardingAdapter({this.onChunk});

  final void Function(UploadChunk chunk)? onChunk;
  int received = 0;

  @override
  Future<UploadSession> initialize(UploadRequest request) async =>
      UploadSession(uploadId: request.uploadId);

  @override
  Future<ChunkUploadResult> uploadChunk(
    UploadSession session,
    UploadChunk chunk,
  ) async {
    onChunk?.call(chunk);
    received += chunk.size;
    return ChunkUploadResult.accepted(chunk);
  }

  @override
  Future<UploadResult> complete(UploadSession session) async =>
      UploadResult(uploadId: session.uploadId, url: 'x://done');

  @override
  Future<void> cancel(UploadSession session) async {}
}
