import 'dart:async';
import 'dart:math';

import 'package:flutter_smart_upload/flutter_smart_upload.dart';

/// A pretend backend, so the example runs without a server.
///
/// It behaves like a slow, slightly unreliable upload endpoint: chunks take
/// time proportional to their size, and a configurable share of requests fail
/// transiently so you can watch the retry and resume machinery work.
class DemoUploadAdapter extends UploadAdapter {
  DemoUploadAdapter({
    this.bytesPerSecond = 3 * 1024 * 1024,
    this.failureRate = 0.0,
  });

  /// Simulated upload speed.
  final int bytesPerSecond;

  /// Probability in `0..1` that any given chunk fails with a server error.
  final double failureRate;

  final Random _random = Random();
  final Map<String, Set<int>> _stored = <String, Set<int>>{};

  @override
  Future<UploadSession> initialize(UploadRequest request) async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final Set<int> stored =
        _stored.putIfAbsent(request.uploadId, () => <int>{});
    return UploadSession(
      uploadId: request.uploadId,
      sessionId: 'demo-${request.uploadId}',
      // Reporting what the server already holds is what lets a resumed upload
      // skip straight to the first missing chunk.
      uploadedChunkIndices: Set<int>.of(stored),
    );
  }

  @override
  Future<ChunkUploadResult> uploadChunk(
    UploadSession session,
    UploadChunk chunk,
  ) async {
    await Future<void>.delayed(
      Duration(microseconds: chunk.size * 1000000 ~/ bytesPerSecond),
    );
    if (_random.nextDouble() < failureRate) {
      throw SmartUploadException.server(
        'Simulated 503 on chunk ${chunk.index}',
      );
    }
    _stored.putIfAbsent(session.uploadId, () => <int>{}).add(chunk.index);
    return ChunkUploadResult.accepted(chunk, etag: 'demo-${chunk.index}');
  }

  @override
  Future<UploadResult> complete(UploadSession session) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return UploadResult(
      uploadId: session.uploadId,
      url: 'https://demo.invalid/files/${session.uploadId}',
    );
  }

  @override
  Future<void> cancel(UploadSession session) async {
    _stored.remove(session.uploadId);
  }
}
