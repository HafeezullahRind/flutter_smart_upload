import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_smart_upload/flutter_smart_upload.dart';
import 'package:test/test.dart';

import 'support/test_support.dart';

void main() {
  group('UploadProgress', () {
    test('computes percentage, fraction and remaining bytes', () {
      const UploadProgress progress = UploadProgress(
        uploadedBytes: 250,
        totalBytes: 1000,
        elapsed: Duration(seconds: 1),
        bytesPerSecond: 250,
      );

      expect(progress.percentage, 25);
      expect(progress.fraction, 0.25);
      expect(progress.remainingBytes, 750);
      expect(progress.isComplete, isFalse);
    });

    test('handles a zero-length payload without dividing by zero', () {
      const UploadProgress progress = UploadProgress.initial(0);

      expect(progress.percentage, 0);
      expect(progress.fraction, 0);
      expect(progress.isComplete, isFalse);
    });

    test('is a value type', () {
      const UploadProgress a = UploadProgress(
        uploadedBytes: 1,
        totalBytes: 2,
        elapsed: Duration.zero,
      );
      const UploadProgress b = UploadProgress(
        uploadedBytes: 1,
        totalBytes: 2,
        elapsed: Duration.zero,
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.copyWith(uploadedBytes: 2), isNot(a));
    });
  });

  group('UploadStatus', () {
    test('classifies terminal, active and resumable states', () {
      expect(UploadStatus.completed.isTerminal, isTrue);
      expect(UploadStatus.failed.isTerminal, isTrue);
      expect(UploadStatus.cancelled.isTerminal, isTrue);
      expect(UploadStatus.uploading.isTerminal, isFalse);

      expect(UploadStatus.uploading.isActive, isTrue);
      expect(UploadStatus.compressing.isActive, isTrue);
      expect(UploadStatus.queued.isActive, isFalse);

      expect(UploadStatus.paused.isResumable, isTrue);
      expect(UploadStatus.failed.isResumable, isTrue);
      expect(UploadStatus.completed.isResumable, isFalse);
    });
  });

  group('UploadChunk', () {
    test('derives size, end, ordering flags and a byte range', () {
      final UploadChunk chunk = UploadChunk(
        index: 1,
        totalChunks: 3,
        start: 1000,
        bytes: Uint8List(400),
      );

      expect(chunk.size, 400);
      expect(chunk.end, 1400);
      expect(chunk.byteRange, '1000-1399');
      expect(chunk.isLast, isFalse);
      expect(chunk.isOnly, isFalse);
      expect(chunk.withChecksum('abc').checksum, 'abc');
    });

    test('asStream yields the payload once', () async {
      final UploadChunk chunk = UploadChunk(
        index: 0,
        totalChunks: 1,
        start: 0,
        bytes: Uint8List.fromList(<int>[1, 2, 3]),
      );

      expect(await chunk.asStream().toList(), <List<int>>[
        <int>[1, 2, 3]
      ]);
    });
  });

  group('UploadSession', () {
    test('round-trips through JSON', () {
      const UploadSession session = UploadSession(
        uploadId: 'u1',
        sessionId: 's1',
        uploadUrl: 'https://example.com',
        chunkSize: 1024,
        uploadedChunkIndices: <int>{0, 3},
        uploadedBytes: 2048,
        headers: <String, String>{'a': 'b'},
        data: <String, Object?>{
          'n': 1,
          'list': <Object?>['x']
        },
      );

      final UploadSession restored = UploadSession.fromJson(session.toJson());

      expect(restored.sessionId, 's1');
      expect(restored.uploadUrl, 'https://example.com');
      expect(restored.chunkSize, 1024);
      expect(restored.uploadedChunkIndices, <int>{0, 3});
      expect(restored.headers, <String, String>{'a': 'b'});
      expect(restored.data['n'], 1);
      expect(restored.toJson(), session.toJson());
    });

    test('withChunkUploaded accumulates indices and bytes', () {
      const UploadSession session = UploadSession(uploadId: 'u');

      final UploadSession updated =
          session.withChunkUploaded(0, 100).withChunkUploaded(1, 50);

      expect(updated.uploadedChunkIndices, <int>{0, 1});
      expect(updated.uploadedBytes, 150);
    });

    test('knows when it has expired', () {
      final UploadSession expired = UploadSession(
        uploadId: 'u',
        expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
      );
      final UploadSession live = UploadSession(
        uploadId: 'u',
        expiresAt: DateTime.now().add(const Duration(minutes: 1)),
      );

      expect(expired.isExpired, isTrue);
      expect(live.isExpired, isFalse);
      expect(const UploadSession(uploadId: 'u').isExpired, isFalse);
    });
  });

  group('UploadOptions', () {
    test('round-trips through JSON', () {
      const UploadOptions options = UploadOptions(
        compress: true,
        quality: 70,
        maxWidth: 1920,
        maxHeight: 1080,
        format: ImageOutputFormat.jpeg,
        stripMetadata: false,
        fileName: 'a.jpg',
        contentType: 'image/jpeg',
        metadata: <String, String>{'album': 'x'},
        chunkSize: 4096,
        checksum: ChecksumMode.both,
        priority: 3,
        skipCompressionIfLarger: false,
      );

      expect(
          UploadOptions.fromJson(options.toJson()).toJson(), options.toJson());
    });

    test('rejects impossible values', () {
      expect(() => UploadOptions(quality: 0), throwsA(isA<AssertionError>()));
      expect(() => UploadOptions(quality: 101), throwsA(isA<AssertionError>()));
      expect(() => UploadOptions(maxWidth: 0), throwsA(isA<AssertionError>()));
      expect(() => UploadOptions(chunkSize: 0), throwsA(isA<AssertionError>()));
    });

    test('presets are sensible', () {
      expect(UploadOptions.image.compress, isTrue);
      expect(UploadOptions.image.maxWidth, 1920);
      expect(UploadOptions.raw.compress, isFalse);
    });

    test('copyWith replaces only what it is given', () {
      const UploadOptions base = UploadOptions(quality: 50, priority: 2);
      final UploadOptions copy = base.copyWith(quality: 90);

      expect(copy.quality, 90);
      expect(copy.priority, 2);
    });
  });

  group('ChecksumMode', () {
    test('describes what it includes', () {
      expect(ChecksumMode.none.includesFile, isFalse);
      expect(ChecksumMode.file.includesFile, isTrue);
      expect(ChecksumMode.chunk.includesChunk, isTrue);
      expect(ChecksumMode.both.includesFile, isTrue);
      expect(ChecksumMode.both.includesChunk, isTrue);
    });
  });

  group('SmartUploadConfig', () {
    test('defaults are production-sensible', () {
      final SmartUploadConfig config = SmartUploadConfig();

      expect(config.chunkSize, 2 * 1024 * 1024);
      expect(config.maxConcurrentUploads, 2);
      expect(config.maxRetries, 3);
      expect(config.retryDelay, const Duration(seconds: 2));
      expect(config.retryPolicy, isA<ExponentialBackoffRetryPolicy>());
      expect(config.checksumMode, ChecksumMode.none);
      expect(config.storage, isA<MemoryUploadStorage>());
      expect(config.compressor, isA<NoopCompressor>());
      expect(config.autoStart, isTrue);
    });

    test('derives the default retry policy from maxRetries and retryDelay', () {
      final SmartUploadConfig config = SmartUploadConfig(
        maxRetries: 5,
        retryDelay: const Duration(milliseconds: 500),
      );

      expect(config.retryPolicy.maxRetries, 5);
    });

    test('rejects impossible values', () {
      expect(() => SmartUploadConfig(chunkSize: 0),
          throwsA(isA<AssertionError>()));
      expect(() => SmartUploadConfig(maxConcurrentUploads: 0),
          throwsA(isA<AssertionError>()));
      expect(() => SmartUploadConfig(maxRetries: -1),
          throwsA(isA<AssertionError>()));
    });

    test('copyWith preserves untouched fields', () {
      final SmartUploadConfig config =
          SmartUploadConfig(chunkSize: 4096).copyWith(maxRetries: 9);

      expect(config.chunkSize, 4096);
      expect(config.maxRetries, 9);
    });
  });

  group('UploadResult', () {
    test('copyWith fills in orchestrator-owned fields', () {
      const UploadResult result = UploadResult(uploadId: 'u', url: 'x://a');

      final UploadResult enriched = result.copyWith(
        fileName: 'a.bin',
        fileSize: 100,
        duration: const Duration(seconds: 2),
      );

      expect(enriched.url, 'x://a');
      expect(enriched.fileName, 'a.bin');
      expect(enriched.fileSize, 100);
      expect(enriched.duration, const Duration(seconds: 2));
    });
  });

  group('InMemoryUploadAdapter', () {
    late Directory dir;
    setUp(() => dir = createTempDir());
    tearDown(() => dir.deleteSync(recursive: true));

    test('completes an upload and can reassemble the bytes', () async {
      final File file = createRandomFile(dir, 'demo.bin', 3000);
      final InMemoryUploadAdapter adapter =
          InMemoryUploadAdapter(retainBytes: true);
      final SmartUploader uploader = SmartUploader(
        adapter: adapter,
        config: testConfig(chunkSize: 1000),
      );

      final UploadTask task = await uploader.upload(file: file);
      final UploadResult result = await task.done;

      expect(result.url, 'memory://uploads/${task.id}');
      expect(adapter.bytesReceived(task.id), 3000);
      expect(adapter.bytesOf(task.id), file.readAsBytesSync());
      expect(adapter.completedUploads, contains(task.id));
      await uploader.dispose();
    });

    test('discards payloads by default', () async {
      final File file = createFile(dir, 'nobytes.bin', 2000);
      final InMemoryUploadAdapter adapter = InMemoryUploadAdapter();
      final SmartUploader uploader = SmartUploader(
        adapter: adapter,
        config: testConfig(chunkSize: 1000),
      );

      final UploadTask task = await uploader.upload(file: file);
      await task.done;

      expect(adapter.bytesReceived(task.id), 2000);
      expect(adapter.bytesOf(task.id), isNull);
      await uploader.dispose();
    });
  });
}
