import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_smart_upload/flutter_smart_upload.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

import 'support/test_support.dart';

/// Writes a noisy JPEG of the given dimensions, so compression has something
/// real to chew on.
File writeJpeg(Directory dir, String name, int width, int height) {
  final img.Image image = img.Image(width: width, height: height);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      image.setPixelRgb(x, y, (x * 7) % 256, (y * 13) % 256, (x * y) % 256);
    }
  }
  final File file = File('${dir.path}/$name');
  file.writeAsBytesSync(img.encodeJpg(image, quality: 100));
  return file;
}

File writePng(Directory dir, String name, int width, int height) {
  final img.Image image = img.Image(width: width, height: height);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      image.setPixelRgb(x, y, (x * 3) % 256, (y * 5) % 256, 128);
    }
  }
  final File file = File('${dir.path}/$name');
  file.writeAsBytesSync(img.encodePng(image));
  return file;
}

void main() {
  late Directory dir;
  late Directory work;

  setUp(() {
    dir = createTempDir();
    work = createTempDir('fsu_work');
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
    if (work.existsSync()) work.deleteSync(recursive: true);
  });

  group('ImageCompressor', () {
    test('resizes to fit the bounds and preserves aspect ratio', () async {
      final File file = writeJpeg(dir, 'big.jpg', 1200, 600);
      const ImageCompressor compressor = ImageCompressor(runInIsolate: false);

      final CompressionResult result = await compressor.compress(
        file: file,
        options: const UploadOptions(
          compress: true,
          maxWidth: 600,
          maxHeight: 600,
          quality: 80,
        ),
        contentType: 'image/jpeg',
        workDirectory: work,
      );

      expect(result.didCompress, isTrue);
      expect(result.width, 600);
      expect(result.height, 300);
      expect(result.compressedSize, lessThan(result.originalSize));
      expect(result.isTemporary, isTrue);
    });

    test('does not upscale an image that already fits', () async {
      final File file = writeJpeg(dir, 'small.jpg', 100, 80);
      const ImageCompressor compressor = ImageCompressor(runInIsolate: false);

      final CompressionResult result = await compressor.compress(
        file: file,
        options: const UploadOptions(
          compress: true,
          maxWidth: 4000,
          maxHeight: 4000,
        ),
        contentType: 'image/jpeg',
        workDirectory: work,
      );

      expect(result.width, 100);
      expect(result.height, 80);
    });

    test('quality reduces the output size', () async {
      final File file = writeJpeg(dir, 'quality.jpg', 400, 400);
      const ImageCompressor compressor = ImageCompressor(runInIsolate: false);

      Future<int> sizeAt(int quality) async => (await compressor.compress(
            file: file,
            options: UploadOptions(compress: true, quality: quality),
            contentType: 'image/jpeg',
            workDirectory: work,
          ))
              .compressedSize;

      expect(await sizeAt(30), lessThan(await sizeAt(95)));
    });

    test('keeps PNG sources lossless by default', () async {
      final File file = writePng(dir, 'art.png', 200, 200);
      const ImageCompressor compressor = ImageCompressor(runInIsolate: false);

      final CompressionResult result = await compressor.compress(
        file: file,
        options: const UploadOptions(compress: true, maxWidth: 100),
        contentType: 'image/png',
        workDirectory: work,
      );

      expect(result.contentType, 'image/png');
      expect(result.file.path, endsWith('.png'));
    });

    test('converts to JPEG on request', () async {
      final File file = writePng(dir, 'convert.png', 200, 200);
      const ImageCompressor compressor = ImageCompressor(runInIsolate: false);

      final CompressionResult result = await compressor.compress(
        file: file,
        options: const UploadOptions(
          compress: true,
          format: ImageOutputFormat.jpeg,
        ),
        contentType: 'image/png',
        workDirectory: work,
      );

      expect(result.contentType, 'image/jpeg');
      final Uint8List bytes = result.file.readAsBytesSync();
      expect(img.findDecoderForData(bytes), isA<img.JpegDecoder>());
    });

    test('strips EXIF metadata', () async {
      final img.Image image = img.Image(width: 64, height: 64);
      image.exif.imageIfd['Artist'] = 'secret';
      image.exif.gpsIfd.gpsLatitude = 51;
      final File file = File('${dir.path}/exif.jpg')
        ..writeAsBytesSync(img.encodeJpg(image, quality: 95));
      const ImageCompressor compressor = ImageCompressor(runInIsolate: false);

      final CompressionResult result = await compressor.compress(
        file: file,
        options: const UploadOptions(compress: true, stripMetadata: true),
        contentType: 'image/jpeg',
        workDirectory: work,
      );

      final img.Image? decoded = img.decodeJpg(result.file.readAsBytesSync());
      expect(decoded!.exif.gpsIfd.gpsLatitude, isNull);
    });

    test('leaves images above maxDecodePixels untouched', () async {
      final File file = writeJpeg(dir, 'huge.jpg', 300, 300);
      const ImageCompressor compressor = ImageCompressor(
        runInIsolate: false,
        maxDecodePixels: 1000,
      );

      final CompressionResult result = await compressor.compress(
        file: file,
        options: const UploadOptions(compress: true, maxWidth: 50),
        contentType: 'image/jpeg',
        workDirectory: work,
      );

      expect(result.didCompress, isFalse);
      expect(result.file.path, file.path);
    });

    test('canCompress only accepts supported images', () {
      const ImageCompressor compressor = ImageCompressor();
      final File jpeg = writeJpeg(dir, 'ok.jpg', 10, 10);
      const UploadOptions on = UploadOptions(compress: true);

      expect(compressor.canCompress(jpeg, 'image/jpeg', on), isTrue);
      expect(compressor.canCompress(jpeg, 'video/mp4', on), isFalse);
      expect(compressor.canCompress(jpeg, 'application/pdf', on), isFalse);
      expect(compressor.canCompress(jpeg, 'image/gif', on), isFalse);
      expect(
        compressor.canCompress(jpeg, 'image/jpeg', const UploadOptions()),
        isFalse,
        reason: 'compression must be opt-in',
      );
    });

    test('runs in a background isolate', () async {
      final File file = writeJpeg(dir, 'isolate.jpg', 500, 500);
      const ImageCompressor compressor = ImageCompressor();

      final CompressionResult result = await compressor.compress(
        file: file,
        options: const UploadOptions(compress: true, maxWidth: 100),
        contentType: 'image/jpeg',
        workDirectory: work,
      );

      expect(result.didCompress, isTrue);
      expect(result.width, 100);
    });
  });

  group('compression in the upload pipeline', () {
    test('uploads the compressed bytes and cleans up the temp file', () async {
      final File file = writeJpeg(dir, 'pipeline.jpg', 1000, 1000);
      final int originalSize = file.lengthSync();
      final MockUploadAdapter adapter = MockUploadAdapter();
      final SmartUploader uploader = SmartUploader(
        adapter: adapter,
        config: testConfig(
          chunkSize: 64 * 1024,
          compressor: const ImageCompressor(runInIsolate: false),
          tempDirectory: work,
        ),
      );

      final UploadTask task = await uploader.upload(
        file: file,
        options: const UploadOptions(
          compress: true,
          quality: 70,
          maxWidth: 400,
          maxHeight: 400,
        ),
      );
      final UploadResult result = await task.done;

      expect(adapter.requests.single.fileSize, lessThan(originalSize));
      expect(result.fileSize, adapter.requests.single.fileSize);
      expect(
        work.listSync().whereType<File>(),
        isEmpty,
        reason: 'the temporary compressed file must be deleted',
      );
      expect(file.existsSync(), isTrue, reason: 'the source is never touched');
      await uploader.dispose();
    });

    test('emits compressing status and a compressed event', () async {
      final File file = writeJpeg(dir, 'events.jpg', 600, 600);
      final SmartUploader uploader = SmartUploader(
        adapter: MockUploadAdapter(),
        config: testConfig(
          chunkSize: 64 * 1024,
          compressor: const ImageCompressor(runInIsolate: false),
          tempDirectory: work,
        ),
      );
      final List<UploadEvent> events = <UploadEvent>[];
      final sub = uploader.events.listen(events.add);
      final List<UploadStatus> states = <UploadStatus>[];

      await (await uploader.upload(
        file: file,
        options: const UploadOptions(compress: true, maxWidth: 200),
        onStatusChanged: states.add,
      ))
          .done;
      await Future<void>.delayed(Duration.zero);

      expect(states, contains(UploadStatus.compressing));
      final UploadCompressedEvent compressed =
          events.whereType<UploadCompressedEvent>().single;
      expect(compressed.compressedSize, lessThan(compressed.originalSize));
      expect(compressed.savedFraction, greaterThan(0));
      await sub.cancel();
      await uploader.dispose();
    });

    test('non-image files pass straight through', () async {
      final File file = createFile(dir, 'notes.pdf', 4096);
      final MockUploadAdapter adapter = MockUploadAdapter();
      final SmartUploader uploader = SmartUploader(
        adapter: adapter,
        config: testConfig(
          chunkSize: 4096,
          compressor: const ImageCompressor(runInIsolate: false),
          tempDirectory: work,
        ),
      );
      final List<UploadStatus> states = <UploadStatus>[];

      await (await uploader.upload(
        file: file,
        options: const UploadOptions(compress: true),
        onStatusChanged: states.add,
      ))
          .done;

      expect(states, isNot(contains(UploadStatus.compressing)));
      expect(adapter.assembled(), file.readAsBytesSync());
      await uploader.dispose();
    });

    test('falls back to the original when compression would grow it', () async {
      final File file = writePng(dir, 'tiny.png', 8, 8);
      final MockUploadAdapter adapter = MockUploadAdapter();
      final SmartUploader uploader = SmartUploader(
        adapter: adapter,
        config: testConfig(
          chunkSize: 1 << 20,
          compressor: const _GrowingCompressor(),
          tempDirectory: work,
        ),
      );

      await (await uploader.upload(
        file: file,
        options: const UploadOptions(compress: true),
      ))
          .done;

      expect(adapter.requests.single.fileSize, file.lengthSync());
      await uploader.dispose();
    });

    test('a failing compressor fails the upload with compression_failed',
        () async {
      final File file = createFile(dir, 'boom.jpg', 1024);
      final SmartUploader uploader = SmartUploader(
        adapter: MockUploadAdapter(),
        config: testConfig(
          compressor: const _ThrowingCompressor(),
          tempDirectory: work,
        ),
      );

      final UploadTask task = await uploader.upload(
        file: file,
        options: const UploadOptions(compress: true),
      );

      await expectLater(
        task.done,
        throwsA(isA<SmartUploadException>().having(
          (SmartUploadException e) => e.code,
          'code',
          'compression_failed',
        )),
      );
      await uploader.dispose();
    });
  });
}

/// A compressor whose output is always bigger than its input.
class _GrowingCompressor extends Compressor {
  const _GrowingCompressor();

  @override
  bool canCompress(File file, String contentType, UploadOptions options) =>
      options.compress;

  @override
  Future<CompressionResult> compress({
    required File file,
    required UploadOptions options,
    required String contentType,
    required Directory workDirectory,
  }) async {
    final int originalSize = await file.length();
    final File out = File('${workDirectory.path}/grown.bin')
      ..writeAsBytesSync(Uint8List(originalSize * 2));
    return CompressionResult(
      file: out,
      originalSize: originalSize,
      compressedSize: originalSize * 2,
      contentType: contentType,
      didCompress: true,
      isTemporary: true,
    );
  }
}

class _ThrowingCompressor extends Compressor {
  const _ThrowingCompressor();

  @override
  bool canCompress(File file, String contentType, UploadOptions options) =>
      options.compress;

  @override
  Future<CompressionResult> compress({
    required File file,
    required UploadOptions options,
    required String contentType,
    required Directory workDirectory,
  }) async =>
      throw StateError('encoder exploded');
}
