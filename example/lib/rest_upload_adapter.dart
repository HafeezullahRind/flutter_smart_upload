import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_smart_upload/flutter_smart_upload.dart';

/// A complete, real adapter for a chunked REST API, written with nothing but
/// `dart:io` — copy it, point it at your endpoints, and adjust the JSON.
///
/// The protocol it assumes:
///
/// ```text
/// POST   /uploads                      -> { "id": "...", "received": [0, 1] }
/// PUT    /uploads/{id}/chunks/{index}  -> 200, body is the raw chunk
/// GET    /uploads/{id}                 -> { "received": [0, 1] }
/// POST   /uploads/{id}/complete        -> { "url": "https://..." }
/// DELETE /uploads/{id}                 -> 204
/// ```
///
/// The important part is not the shape of the JSON but the error mapping at
/// the bottom: returning the right [UploadErrorCode] is what lets the
/// orchestrator retry a 503 and give up immediately on a 401.
class RestUploadAdapter extends UploadAdapter {
  RestUploadAdapter({
    required this.baseUrl,
    this.authToken,
    HttpClient? client,
  }) : _client = client ?? HttpClient();

  /// Root of the upload API, e.g. `https://api.example.com`.
  final Uri baseUrl;

  /// Bearer token sent with every request.
  final String? authToken;

  final HttpClient _client;

  @override
  Future<UploadSession> initialize(UploadRequest request) async {
    final Map<String, Object?> body = await _json(
      'POST',
      baseUrl.resolve('uploads'),
      body: jsonEncode(<String, Object?>{
        'fileName': request.fileName,
        'fileSize': request.fileSize,
        'contentType': request.contentType,
        'chunkSize': request.chunkSize,
        'totalChunks': request.totalChunks,
        'checksum': request.checksum,
        'metadata': request.metadata,
      }),
    );

    return UploadSession(
      uploadId: request.uploadId,
      sessionId: body['id']! as String,
      uploadedChunkIndices: _indices(body['received']),
      // Let the server dictate the chunk size when it cares.
      chunkSize: body['chunkSize'] as int?,
    );
  }

  @override
  Future<ChunkUploadResult> uploadChunk(
    UploadSession session,
    UploadChunk chunk,
  ) async {
    final HttpClientRequest request = await _open(
      'PUT',
      baseUrl.resolve('uploads/${session.sessionId}/chunks/${chunk.index}'),
    );
    request.headers.contentType = ContentType.binary;
    request.contentLength = chunk.size;
    request.headers.set('content-range', 'bytes ${chunk.byteRange}/*');
    if (chunk.checksum != null) {
      request.headers.set('x-chunk-checksum', chunk.checksum!);
    }

    // Streaming the chunk rather than buffering it again keeps the memory
    // profile the package works so hard for.
    await request.addStream(chunk.asStream());
    final HttpClientResponse response = await request.close();
    await _drain(response);
    _throwForStatus(response.statusCode, 'chunk ${chunk.index}');

    return ChunkUploadResult.accepted(
      chunk,
      etag: response.headers.value(HttpHeaders.etagHeader),
    );
  }

  @override
  Future<UploadResult> complete(UploadSession session) async {
    final Map<String, Object?> body = await _json(
      'POST',
      baseUrl.resolve('uploads/${session.sessionId}/complete'),
    );
    return UploadResult(
      uploadId: session.uploadId,
      url: body['url'] as String?,
      fileName: body['fileName'] as String?,
      data: body,
    );
  }

  @override
  Future<void> cancel(UploadSession session) async {
    try {
      final HttpClientRequest request = await _open(
        'DELETE',
        baseUrl.resolve('uploads/${session.sessionId}'),
      );
      await _drain(await request.close());
    } on Object {
      // Cleanup is best effort — never let it mask the cancellation.
    }
  }

  @override
  Future<UploadSession> restore(UploadSession session) async {
    // Ask the server what it actually holds. Trusting the local record risks
    // skipping a chunk whose request died in flight.
    final HttpClientRequest request = await _open(
      'GET',
      baseUrl.resolve('uploads/${session.sessionId}'),
    );
    final HttpClientResponse response = await request.close();
    final String raw = await utf8.decodeStream(response);

    if (response.statusCode == 404 || response.statusCode == 410) {
      throw SmartUploadException(
        'Upload session ${session.sessionId} no longer exists',
        errorCode: UploadErrorCode.resumeFailed,
      );
    }
    _throwForStatus(response.statusCode, 'restore');

    final Map<String, Object?> body = jsonDecode(raw) as Map<String, Object?>;
    return session.copyWith(uploadedChunkIndices: _indices(body['received']));
  }

  /// Frees the underlying connections.
  void close() => _client.close(force: true);

  // ------------------------------------------------------------------ plumbing

  Future<HttpClientRequest> _open(String method, Uri url) async {
    final HttpClientRequest request = await _client.openUrl(method, url);
    if (authToken != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $authToken');
    }
    return request;
  }

  Future<Map<String, Object?>> _json(
    String method,
    Uri url, {
    String? body,
  }) async {
    try {
      final HttpClientRequest request = await _open(method, url);
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(body);
      }
      final HttpClientResponse response = await request.close();
      final String raw = await utf8.decodeStream(response);
      _throwForStatus(response.statusCode, '$method $url');
      return raw.isEmpty
          ? <String, Object?>{}
          : jsonDecode(raw) as Map<String, Object?>;
    } on SocketException catch (e) {
      // A dead socket is transient by nature; tagging it as a network error
      // is what tells the retry policy to back off and try again.
      throw SmartUploadException.network(e.message, cause: e);
    } on HttpException catch (e) {
      throw SmartUploadException.network(e.message, cause: e);
    }
  }

  Future<void> _drain(HttpClientResponse response) =>
      response.drain<void>(null);

  Set<int> _indices(Object? raw) => <int>{
        ...?(raw as List<Object?>?)?.map((Object? e) => e! as int),
      };

  /// Maps HTTP status codes onto the error codes the retry policy understands.
  void _throwForStatus(int status, String what) {
    if (status >= 200 && status < 300) return;
    if (status == 401 || status == 403) {
      throw SmartUploadException.authentication('$what rejected ($status)');
    }
    if (status == 408 || status == 429) {
      throw SmartUploadException.timeout('$what throttled ($status)');
    }
    if (status >= 500) {
      throw SmartUploadException.server('$what failed ($status)');
    }
    throw SmartUploadException(
      '$what failed ($status)',
      errorCode: UploadErrorCode.invalidRequest,
    );
  }
}
