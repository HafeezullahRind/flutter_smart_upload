# Changelog

## 0.1.0

First release.

### Core

- `SmartUploader` — queue, retry, progress, persistence and lifecycle in one
  facade.
- `UploadAdapter` — the four-method seam between this package and any backend.
  No HTTP client, no vendor SDK, no assumptions about your protocol.
- `UploadTask` — per-upload handle with `pause()`, `resume()`, `cancel()`,
  `done`, and status/progress streams.

### Reliability

- Chunked uploads with a configurable size (default 2 MB), read through a
  single `RandomAccessFile` so peak memory is one chunk regardless of file size.
- Per-chunk retry with exponential backoff and jitter; permanent errors
  (auth, invalid file, malformed request) are never retried.
- Resumable uploads: state is persisted after every acknowledged chunk and
  transfers continue at the first chunk the server does not hold.
- Pause, resume and cancel, individually or across the whole queue.
- Concurrency-limited, priority-aware queue.
- Connectivity-aware: uploads park while offline instead of retrying into a
  dead connection.

### Optimisation

- `ImageCompressor` — resize, re-encode and strip EXIF in a background
  isolate, with a pixel-count guard for low-memory devices.
- Opt-in checksums: MD5, SHA-256, base64 MD5 and a free stat-based
  fingerprint. Resume verifies the file has not changed.

### Persistence

- `MemoryUploadStorage` (default) and `FileUploadStorage` (atomic JSON files,
  survives app restarts), behind a replaceable `UploadStorage` interface.

### Developer experience

- Sealed `UploadEvent` hierarchy for exhaustive `switch`.
- Typed `SmartUploadException` with stable error codes and retryability.
- `InMemoryUploadAdapter` for tests and demos.
- Example app covering single and multiple uploads, progress with speed and
  ETA, pause/resume/cancel/retry, simulated flaky server and offline mode.
- 133 tests covering chunking, ordering, retries, resume, persistence,
  cancellation, concurrency, compression, checksums and memory behaviour,
  plus widget tests for the example.
