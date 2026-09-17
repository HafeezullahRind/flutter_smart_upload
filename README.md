# flutter_smart_upload

Backend-agnostic, memory-efficient file uploads for Flutter.

Chunked. Resumable. Retrying. Pausable. Queued. Compressed. And it does not
know — or care — what your server looks like.

[![style: lints](https://img.shields.io/badge/style-lints-blue)](https://pub.dev/packages/lints)

```dart
final SmartUploader uploader = SmartUploader(adapter: MyApiUploadAdapter());

final UploadTask task = await uploader.upload(
  file: File('/path/to/video.mp4'),
  onProgress: (UploadProgress p) => print('${p.percentage.round()}%'),
);

final UploadResult result = await task.done;
print(result.url);
```

## Why

Uploading a 400 MB video from a phone on a train is not an HTTP problem. It is
a *reliability* problem: the connection drops in tunnels, the OS kills
backgrounded apps, the user pauses to take a call, and a 12-megapixel photo
does not need to be sent at full resolution anyway. This package owns all of
that. Your adapter owns the bytes-on-the-wire.

* **No backend lock-in.** No Firebase, no Supabase, no S3 SDK. One interface,
  four methods.
* **Not another HTTP client.** It orchestrates; your adapter transports.
* **Memory first.** One chunk resident at a time, whatever the file size.
  `file.readAsBytes()` appears nowhere in this package.

## Features

| | |
|---|---|
| Chunked uploads | Configurable size, default 2 MB, read via random access |
| Resumable uploads | Survives crashes, restarts and offline periods |
| Retry | Exponential backoff with jitter, and never on permanent errors |
| Pause / resume / cancel | Per task or across the whole queue |
| Queue | Concurrency limit with priorities |
| Progress | Real bytes, smoothed speed, ETA |
| Compression | Isolate-based image resize and re-encode, EXIF stripped |
| Checksums | MD5, SHA-256, custom — all opt-in |
| Network awareness | Parks uploads while offline instead of hammering the server |
| Events | One typed, exhaustively switchable stream |

## Install

```yaml
dependencies:
  flutter_smart_upload: ^0.1.0
```

## 1. Write an adapter

This is the only thing the package cannot do for you. Four methods:

```dart
class MyApiUploadAdapter implements UploadAdapter {
  @override
  Future<UploadSession> initialize(UploadRequest request) async {
    final Response res = await dio.post('/uploads', data: <String, Object?>{
      'name': request.fileName,
      'size': request.fileSize,
      'chunks': request.totalChunks,
    });
    return UploadSession(
      uploadId: request.uploadId,
      sessionId: res.data['id'] as String,
      // Chunks the server already holds are skipped automatically.
      uploadedChunkIndices: <int>{...?res.data['received']?.cast<int>()},
    );
  }

  @override
  Future<ChunkUploadResult> uploadChunk(
    UploadSession session,
    UploadChunk chunk,
  ) async {
    await dio.put(
      '/uploads/${session.sessionId}/parts/${chunk.index}',
      data: Stream<List<int>>.fromIterable(<List<int>>[chunk.bytes]),
      options: Options(headers: <String, Object?>{
        'content-range': 'bytes ${chunk.byteRange}/${session.data['size']}',
      }),
    );
    return ChunkUploadResult.accepted(chunk);
  }

  @override
  Future<UploadResult> complete(UploadSession session) async {
    final Response res =
        await dio.post('/uploads/${session.sessionId}/complete');
    return UploadResult(
      uploadId: session.uploadId,
      url: res.data['url'] as String,
    );
  }

  @override
  Future<void> cancel(UploadSession session) =>
      dio.delete('/uploads/${session.sessionId}');
}
```

A complete adapter written with nothing but `dart:io` is in
[`example/lib/rest_upload_adapter.dart`](example/lib/rest_upload_adapter.dart).

### Throw the right error

Error codes drive the retry loop. Get these right and everything else follows:

```dart
if (res.statusCode == 401) throw SmartUploadException.authentication('…'); // never retried
if (res.statusCode >= 500) throw SmartUploadException.server('…');         // retried
if (socketDied)            throw SmartUploadException.network('…');        // retried, waits for connectivity
```

Not throwing a typed error is fine too — anything else from `uploadChunk` is
treated as a retryable chunk failure.

## 2. Configure the uploader

Every option has a sane default; this is the whole surface:

```dart
final SmartUploader uploader = SmartUploader(
  adapter: MyApiUploadAdapter(),
  config: SmartUploadConfig(
    chunkSize: 2 * 1024 * 1024,      // 2 MB
    maxConcurrentUploads: 2,
    maxRetries: 3,
    retryDelay: Duration(seconds: 2), // 2s → 4s → 8s
    compressor: const ImageCompressor(),
    storage: FileUploadStorage(stateDir),
    networkMonitor: myConnectivityBridge,
    checksumMode: ChecksumMode.file,
  ),
);
```

## 3. Upload

```dart
final UploadTask task = await uploader.upload(
  file: file,
  options: const UploadOptions(
    compress: true,
    quality: 80,
    maxWidth: 1920,
    maxHeight: 1920,
  ),
  onProgress: (UploadProgress p) {
    print('${p.percentage.toStringAsFixed(0)}% · '
        '${p.bytesPerSecond ~/ 1024} KB/s · ${p.estimatedRemaining} left');
  },
  onStatusChanged: (UploadStatus status) => print(status),
);
```

`upload()` returns as soon as the task is queued — that is what makes
`task.pause()` reachable. Await the result separately:

```dart
final UploadResult result = await task.done;   // throws SmartUploadException
print(result.url);
```

### Many files

```dart
final List<UploadTask> tasks = await uploader.uploadMultiple(files: files);
await Future.wait(tasks.map((UploadTask t) => t.done));
```

With `maxConcurrentUploads: 2`, twenty files look like this:

```text
photo1.jpg    █████████░  90%   uploading
photo2.jpg    ██████░░░░  60%   uploading
video.mp4     ░░░░░░░░░░   0%   queued
document.pdf  ░░░░░░░░░░   0%   queued
```

Raise `UploadOptions.priority` to jump the line.

### Control

```dart
await task.pause();   // stops at the next chunk boundary; nothing is re-sent
await task.resume();  // picks up at the first chunk the server lacks
await task.cancel();  // stops requests, tells the adapter, cleans up
```

### Resume after a restart

Give the uploader durable storage and interrupted uploads outlive the process:

```dart
final SmartUploader uploader = SmartUploader(
  adapter: MyApiUploadAdapter(),
  config: SmartUploadConfig(
    storage: FileUploadStorage(
      Directory(p.join((await getApplicationSupportDirectory()).path, 'uploads')),
    ),
  ),
);

for (final UploadRecord record in await uploader.pendingUploads()) {
  await uploader.resume(record.uploadId);   // continues from the first gap
}
```

Override `UploadAdapter.restore` to ask the server what it actually holds —
always more trustworthy than the local record, which can be stale if the
process died mid-request.

### Events

One typed stream for everything. The hierarchy is `sealed`, so the compiler
checks your `switch`:

```dart
uploader.events.listen((UploadEvent event) {
  switch (event) {
    case UploadProgressEvent(:final UploadProgress progress):
      bar.value = progress.fraction;
    case UploadRetryEvent(:final int attempt, :final Duration delay):
      log('retry $attempt in ${delay.inSeconds}s');
    case UploadCompletedEvent(:final UploadResult result):
      log('done: ${result.url}');
    case UploadFailedEvent(:final SmartUploadException error):
      log('failed: ${error.code}');
    default:
      log(event.status.name);
  }
});
```

Full list: `UploadQueuedEvent`, `UploadPreparingEvent`,
`UploadCompressingEvent`, `UploadCompressedEvent`, `UploadStartedEvent`,
`UploadProgressEvent`, `UploadChunkCompletedEvent`, `UploadPausedEvent`,
`UploadResumedEvent`, `UploadRetryEvent`, `UploadCompletedEvent`,
`UploadFailedEvent`, `UploadCancelledEvent`.

## Image compression

```dart
SmartUploadConfig(compressor: const ImageCompressor());

await uploader.upload(
  file: photo,
  options: const UploadOptions(
    compress: true,
    quality: 80,
    maxWidth: 1920,
    maxHeight: 1920,
    stripMetadata: true,   // drops EXIF, including GPS
  ),
);
```

Decoding runs in a background isolate, so the decode heap dies with the isolate
and never touches your app's. Images above `maxDecodePixels` (24 MP by default)
pass through untouched rather than risking an out-of-memory kill on a low-end
device. Non-image files always pass through.

For the tightest memory budget, plug in a platform-native compressor:

```dart
class NativeImageCompressor implements Compressor { /* flutter_image_compress */ }
SmartUploadConfig(compressor: NativeImageCompressor());
```

## Network awareness

The package does not depend on any connectivity package. Bridge yours:

```dart
SmartUploadConfig(
  networkMonitor: StreamNetworkMonitor(
    Connectivity().onConnectivityChanged.map(
      (List<ConnectivityResult> r) => !r.contains(ConnectivityResult.none),
    ),
  ),
  waitForNetwork: true,
);
```

Offline, an upload parks at a chunk boundary (`UploadStatus.paused`, with
`task.isWaitingForNetwork == true`) and sends nothing until connectivity
returns. No retry storm, no radio wake-ups.

## Checksums

Off by default — hashing a 500 MB video costs a full extra read.

```dart
SmartUploadConfig(
  checksumMode: ChecksumMode.file,          // or .chunk, or .both
  checksumProvider: const Sha256ChecksumProvider(),
);
```

Bundled: `Md5ChecksumProvider`, `Sha256ChecksumProvider`,
`Md5Base64ChecksumProvider` (the `Content-MD5` form), and
`FileStatChecksumProvider` (a free fingerprint from size + mtime, enough to
detect that a file changed before resuming).

With `ChecksumMode.file`, resuming re-hashes the source and refuses to continue
if the bytes changed underneath — you get `checksum_mismatch` instead of a
corrupt object on your server.

## Errors

```dart
try {
  await task.done;
} on SmartUploadException catch (e) {
  print(e.code);        // 'network_error'
  print(e.isRetryable); // true
}
```

| Code | Retryable |
|---|---|
| `network_error`, `timeout`, `server_error`, `chunk_upload_failed` | yes |
| `authentication_error`, `invalid_file`, `file_not_found`, `invalid_request` | no |
| `compression_failed`, `checksum_mismatch`, `resume_failed`, `storage_error` | no |
| `upload_cancelled` | no |

Custom policies get the final say:

```dart
class BusinessHoursRetryPolicy extends RetryPolicy {
  @override
  int get maxRetries => 5;

  @override
  bool shouldRetry(RetryContext context) =>
      context.error.isRetryable && context.elapsed < const Duration(minutes: 10);

  @override
  Duration delayFor(RetryContext context) =>
      Duration(seconds: 1 << context.attempt);
}
```

## Memory

The design constraint that shapes everything else:

* Chunks are read through a single `RandomAccessFile` with `setPosition` +
  `read`. Peak heap for the transfer path is one chunk per concurrent upload —
  ~4 MB at defaults, whether the file is 3 MB or 3 GB.
* Checksums stream the file through `hash.bind(file.openRead())`.
* Compression happens in a throwaway isolate, with a pixel-count guard.
* File handles are closed on every path — completion, pause, failure,
  cancellation.

A regression test uploads a 64 MB file and asserts the process RSS grows by
less than 24 MB:

```sh
FSU_MEMORY_TEST=1 dart test test/memory_test.dart
```

## Architecture

```text
                 Flutter App
                      │
                      ▼
                SmartUploader ──────► events (typed stream)
                      │
        ┌─────────────┼─────────────┐
        ▼             ▼             ▼
   Compression      Queue        Retry policy
   (isolate)     (concurrency)   (backoff)
        │             │             │
        └─────────────┼─────────────┘
                      ▼
                UploadManager ◄──► UploadStorage (resume state)
                      │
                      ▼
                UploadAdapter          ← you implement this
                      │
        ┌─────────────┼─────────────┐
        ▼             ▼             ▼
      REST           S3           anything
```

```text
lib/
├── flutter_smart_upload.dart      public API
└── src/
    ├── core/         SmartUploader, UploadManager, UploadQueue, UploadTask
    ├── models/       request, session, chunk, progress, result, status, events
    ├── adapters/     UploadAdapter, InMemoryUploadAdapter
    ├── compression/  Compressor, ImageCompressor
    ├── persistence/  UploadStorage, memory + file implementations
    ├── checksum/     ChecksumProvider and implementations
    ├── retry/        RetryPolicy, exponential backoff
    ├── network/      NetworkMonitor bridges
    ├── io/           ChunkReader
    └── util/         progress tracking, MIME types, ids
```

## Example app

```sh
cd example && flutter run
```

Single and multiple uploads, live progress with speed and ETA,
pause/resume/cancel/retry, plus switches to simulate a flaky server and a
dropped connection — all against an in-process fake backend, so it runs with no
server at all.

## Testing your own adapter

`InMemoryUploadAdapter` ships with the package for tests and demos:

```dart
final adapter = InMemoryUploadAdapter(retainBytes: true);
final uploader = SmartUploader(adapter: adapter);
await (await uploader.upload(file: file)).done;
expect(adapter.bytesOf(task.id), file.readAsBytesSync());
```

## Notes and limits

* `upload()` resolves when the task is **queued**, not when it finishes. Await
  `task.done` for the result.
* A **failed** task is terminal. `uploader.resume(id)` builds a fresh task from
  the persisted record — which still knows which chunks landed.
* `uploadChunk` must be **idempotent**: retries and resumes can deliver the
  same chunk twice.
* Cancellation stops *further* requests. A request already on the wire cannot
  be unsent; the adapter's `cancel` is called to clean up server-side.
* This is not a background-transfer service. It is background-*friendly*
  (state is durable, resume is cheap), but iOS/Android will still suspend your
  process; resume on next launch via `pendingUploads()`.

## License

MIT — see [LICENSE](LICENSE).
