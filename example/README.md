# flutter_smart_upload example

A small app that exercises the whole package against an in-process fake
backend, so it runs with no server at all.

```sh
flutter run
```

## What it shows

* **Single and multiple uploads** — pick files, or add a 24 MB demo file to
  watch chunking work on something large.
* **Live progress** — percentage, transferred bytes, speed and estimated time
  remaining, driven by `UploadTask.progressStream`.
* **Queue behaviour** — `maxConcurrentUploads: 2`, so the third file onward
  waits and starts automatically as slots free up.
* **Pause / resume / cancel / retry** — per row and for the whole queue.
* **Image compression** — toggle it and watch the "saved n%" line in the event
  bar.
* **Flaky server** — fails 25% of chunks so you can see retries with
  exponential backoff, and resume from the last good chunk.
* **Offline mode** — parks transfers while "disconnected", then continues.
* **Resume after restart** — state is kept in `FileUploadStorage`; kill the app
  mid-upload, relaunch, and it offers to continue.

## Files worth reading

| File | Why |
|---|---|
| [`lib/main.dart`](lib/main.dart) | How the uploader is configured and wired to a UI |
| [`lib/upload_tile.dart`](lib/upload_tile.dart) | Rendering progress, speed and ETA from the task streams |
| [`lib/rest_upload_adapter.dart`](lib/rest_upload_adapter.dart) | A complete, real adapter for a chunked REST API, written with only `dart:io` — including the HTTP-status-to-error-code mapping that drives retries |
| [`lib/demo_upload_adapter.dart`](lib/demo_upload_adapter.dart) | The fake backend, with simulated latency and failures |

## Using your own backend

Replace one line in `_createUploader()`:

```dart
adapter: RestUploadAdapter(baseUrl: Uri.parse('https://api.example.com/')),
```

Nothing else in the app changes.
