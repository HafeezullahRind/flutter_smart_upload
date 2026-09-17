import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_smart_upload/flutter_smart_upload.dart';
import 'package:test/test.dart';

import 'support/test_support.dart';

void main() {
  late Directory dir;

  setUp(() => dir = createTempDir());
  tearDown(() => dir.deleteSync(recursive: true));

  group('providers', () {
    test('MD5 matches crypto over the same bytes', () async {
      final File file = createRandomFile(dir, 'hash.bin', 5000);
      const Md5ChecksumProvider provider = Md5ChecksumProvider();

      expect(
        await provider.calculate(file),
        md5.convert(file.readAsBytesSync()).toString(),
      );
      expect(provider.algorithm, 'md5');
    });

    test('SHA-256 matches crypto over the same bytes', () async {
      final File file = createRandomFile(dir, 'sha.bin', 5000);
      const Sha256ChecksumProvider provider = Sha256ChecksumProvider();

      expect(
        await provider.calculate(file),
        sha256.convert(file.readAsBytesSync()).toString(),
      );
    });

    test('base64 MD5 is the Content-MD5 form', () async {
      final File file = createRandomFile(dir, 'b64.bin', 1000);

      expect(
        await const Md5Base64ChecksumProvider().calculate(file),
        base64Encode(md5.convert(file.readAsBytesSync()).bytes),
      );
    });

    test('file-stat fingerprint changes when the file changes', () async {
      final File file = createFile(dir, 'stat.bin', 100);
      const FileStatChecksumProvider provider = FileStatChecksumProvider();

      final String before = await provider.calculate(file);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      file.writeAsBytesSync(List<int>.filled(200, 1));

      expect(await provider.calculate(file), isNot(before));
    });

    test('a missing file raises file_not_found', () {
      expect(
        () => const Md5ChecksumProvider().calculate(File('${dir.path}/no')),
        throwsA(isA<SmartUploadException>().having(
          (SmartUploadException e) => e.code,
          'code',
          'file_not_found',
        )),
      );
    });

    test('hashes a large file without loading it into memory', () async {
      final File file = createFile(dir, 'large.bin', 8 * 1024 * 1024);
      final String digest = await const Md5ChecksumProvider().calculate(file);
      expect(digest, hasLength(32));
    });
  });

  group('checksum modes', () {
    test('none computes nothing', () async {
      final File file = createFile(dir, 'plain.bin', 2048);
      final MockUploadAdapter adapter = MockUploadAdapter();
      final SmartUploader uploader = SmartUploader(
        adapter: adapter,
        config: testConfig(chunkSize: 1024),
      );

      await (await uploader.upload(file: file)).done;

      expect(adapter.requests.single.checksum, isNull);
      expect(adapter.chunkChecksums.values, everyElement(isNull));
      await uploader.dispose();
    });

    test('file mode hands the whole-file digest to the adapter', () async {
      final File file = createRandomFile(dir, 'whole.bin', 2048);
      final MockUploadAdapter adapter = MockUploadAdapter();
      final SmartUploader uploader = SmartUploader(
        adapter: adapter,
        config: testConfig(chunkSize: 1024, checksumMode: ChecksumMode.file),
      );

      final UploadResult result =
          await (await uploader.upload(file: file)).done;

      expect(
        adapter.requests.single.checksum,
        md5.convert(file.readAsBytesSync()).toString(),
      );
      expect(result.checksum, adapter.requests.single.checksum);
      await uploader.dispose();
    });

    test('chunk mode digests every chunk', () async {
      final File file = createRandomFile(dir, 'chunks.bin', 3000);
      final MockUploadAdapter adapter = MockUploadAdapter();
      final SmartUploader uploader = SmartUploader(
        adapter: adapter,
        config: testConfig(chunkSize: 1000, checksumMode: ChecksumMode.chunk),
      );

      await (await uploader.upload(file: file)).done;

      expect(adapter.chunkChecksums, hasLength(3));
      for (final MapEntry<int, String?> entry
          in adapter.chunkChecksums.entries) {
        expect(
          entry.value,
          md5.convert(adapter.storedChunks[entry.key]!).toString(),
        );
      }
      expect(adapter.requests.single.checksum, isNull,
          reason: 'chunk mode must not pay for a whole-file hash');
      await uploader.dispose();
    });

    test('both modes can be combined', () async {
      final File file = createRandomFile(dir, 'both.bin', 2000);
      final MockUploadAdapter adapter = MockUploadAdapter();
      final SmartUploader uploader = SmartUploader(
        adapter: adapter,
        config: testConfig(chunkSize: 1000, checksumMode: ChecksumMode.both),
      );

      await (await uploader.upload(file: file)).done;

      expect(adapter.requests.single.checksum, isNotNull);
      expect(adapter.chunkChecksums.values, everyElement(isNotNull));
      await uploader.dispose();
    });

    test('per-upload options override the global mode', () async {
      final File file = createRandomFile(dir, 'override.bin', 1000);
      final MockUploadAdapter adapter = MockUploadAdapter();
      final SmartUploader uploader = SmartUploader(
        adapter: adapter,
        config: testConfig(chunkSize: 1000),
      );

      await (await uploader.upload(
        file: file,
        options: const UploadOptions(checksum: ChecksumMode.file),
      ))
          .done;

      expect(adapter.requests.single.checksum, isNotNull);
      await uploader.dispose();
    });

    test('a custom provider is used verbatim', () async {
      final File file = createFile(dir, 'custom.bin', 500);
      final MockUploadAdapter adapter = MockUploadAdapter();
      final SmartUploader uploader = SmartUploader(
        adapter: adapter,
        config: testConfig(
          checksumMode: ChecksumMode.file,
          checksumProvider: const _ConstantChecksumProvider(),
        ),
      );

      await (await uploader.upload(file: file)).done;

      expect(adapter.requests.single.checksum, 'constant');
      await uploader.dispose();
    });
  });
}

class _ConstantChecksumProvider extends ChecksumProvider {
  const _ConstantChecksumProvider();

  @override
  String get algorithm => 'constant';

  @override
  Future<String> calculate(File file) async => 'constant';

  @override
  Future<String> calculateBytes(List<int> bytes) async => 'constant';
}
