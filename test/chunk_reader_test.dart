import 'dart:io';

import 'package:flutter_smart_upload/flutter_smart_upload.dart';
import 'package:flutter_smart_upload/src/io/chunk_reader.dart';
import 'package:test/test.dart';

import 'support/test_support.dart';

void main() {
  late Directory dir;

  setUp(() => dir = createTempDir());
  tearDown(() => dir.deleteSync(recursive: true));

  group('ChunkReader', () {
    test('splits into full chunks plus a remainder', () async {
      final File file = createFile(dir, 'split.bin', 2500);
      final ChunkReader reader = await ChunkReader.open(file, chunkSize: 1000);

      expect(reader.totalChunks, 3);
      expect(reader.sizeOf(0), 1000);
      expect(reader.sizeOf(2), 500);
      expect(reader.startOf(2), 2000);
      await reader.close();
    });

    test('a file smaller than one chunk yields exactly one chunk', () async {
      final File file = createFile(dir, 'tiny.bin', 10);
      final ChunkReader reader = await ChunkReader.open(file, chunkSize: 1000);

      expect(reader.totalChunks, 1);
      final UploadChunk chunk = await reader.read(0);
      expect(chunk.size, 10);
      expect(chunk.isLast, isTrue);
      expect(chunk.isOnly, isTrue);
      await reader.close();
    });

    test('a file that is an exact multiple has no empty trailing chunk',
        () async {
      final File file = createFile(dir, 'exact.bin', 2000);
      final ChunkReader reader = await ChunkReader.open(file, chunkSize: 1000);

      expect(reader.totalChunks, 2);
      await reader.close();
    });

    test('chunks carry correct offsets and reassemble to the original',
        () async {
      final File file = createRandomFile(dir, 'assemble.bin', 4321);
      final ChunkReader reader = await ChunkReader.open(file, chunkSize: 1000);
      final List<int> assembled = <int>[];

      for (int i = 0; i < reader.totalChunks; i++) {
        final UploadChunk chunk = await reader.read(i);
        expect(chunk.start, i * 1000);
        expect(chunk.end, chunk.start + chunk.size);
        expect(chunk.index, i);
        assembled.addAll(chunk.bytes);
      }

      expect(assembled, file.readAsBytesSync());
      await reader.close();
    });

    test('supports out-of-order reads, which is what resume needs', () async {
      final File file = createRandomFile(dir, 'seek.bin', 3000);
      final ChunkReader reader = await ChunkReader.open(file, chunkSize: 1000);

      final UploadChunk third = await reader.read(2);
      final UploadChunk first = await reader.read(0);

      expect(third.bytes, file.readAsBytesSync().sublist(2000, 3000));
      expect(first.bytes, file.readAsBytesSync().sublist(0, 1000));
      await reader.close();
    });

    test('byteRange is the HTTP Content-Range form', () async {
      final File file = createFile(dir, 'range.bin', 2500);
      final ChunkReader reader = await ChunkReader.open(file, chunkSize: 1000);

      expect((await reader.read(0)).byteRange, '0-999');
      expect((await reader.read(2)).byteRange, '2000-2499');
      await reader.close();
    });

    test('readFrom streams lazily from an arbitrary index', () async {
      final File file = createFile(dir, 'stream.bin', 5000);
      final ChunkReader reader = await ChunkReader.open(file, chunkSize: 1000);

      final List<int> indices = <int>[];
      await for (final UploadChunk chunk in reader.readFrom(3)) {
        indices.add(chunk.index);
      }

      expect(indices, <int>[3, 4]);
      await reader.close();
    });

    test('rejects a missing file, an empty file and a bad index', () async {
      expect(
        () => ChunkReader.open(File('${dir.path}/absent'), chunkSize: 10),
        throwsA(isA<SmartUploadException>().having(
            (SmartUploadException e) => e.code, 'code', 'file_not_found')),
      );

      final File empty = File('${dir.path}/empty.bin')
        ..writeAsBytesSync(<int>[]);
      expect(
        () => ChunkReader.open(empty, chunkSize: 10),
        throwsA(isA<SmartUploadException>().having(
            (SmartUploadException e) => e.code, 'code', 'invalid_file')),
      );

      final ChunkReader reader = await ChunkReader.open(
        createFile(dir, 'ok.bin', 100),
        chunkSize: 100,
      );
      expect(
        () => reader.read(5),
        throwsA(isA<SmartUploadException>().having(
            (SmartUploadException e) => e.code, 'code', 'invalid_request')),
      );
      await reader.close();
    });

    test('reading after close fails loudly', () async {
      final ChunkReader reader = await ChunkReader.open(
        createFile(dir, 'closed.bin', 100),
        chunkSize: 50,
      );
      await reader.close();
      await reader.close();

      expect(() => reader.read(0), throwsA(isA<SmartUploadException>()));
    });
  });
}
