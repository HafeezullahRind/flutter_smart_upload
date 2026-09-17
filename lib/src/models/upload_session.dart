import 'package:meta/meta.dart';

/// The adapter's handle on a server-side upload, returned by
/// `UploadAdapter.initialize`.
///
/// A session is JSON-serialisable so that it can be persisted and restored
/// after the process dies. Keep [data] limited to JSON primitives, lists and
/// maps — it is written verbatim to storage.
@immutable
class UploadSession {
  /// Creates a session.
  const UploadSession({
    required this.uploadId,
    this.sessionId,
    this.uploadUrl,
    this.chunkSize,
    this.uploadedChunkIndices = const <int>{},
    this.uploadedBytes = 0,
    this.headers = const <String, String>{},
    this.data = const <String, Object?>{},
    this.expiresAt,
  });

  /// Restores a session previously produced by [toJson].
  factory UploadSession.fromJson(Map<String, Object?> json) => UploadSession(
        uploadId: json['uploadId']! as String,
        sessionId: json['sessionId'] as String?,
        uploadUrl: json['uploadUrl'] as String?,
        chunkSize: json['chunkSize'] as int?,
        uploadedChunkIndices: <int>{
          ...?(json['uploadedChunkIndices'] as List<Object?>?)
              ?.map((Object? e) => e! as int),
        },
        uploadedBytes: (json['uploadedBytes'] as int?) ?? 0,
        headers: <String, String>{
          ...?(json['headers'] as Map<Object?, Object?>?)?.map(
            (Object? k, Object? v) =>
                MapEntry<String, String>(k! as String, v! as String),
          ),
        },
        data: <String, Object?>{
          ...?(json['data'] as Map<Object?, Object?>?)?.map(
            (Object? k, Object? v) =>
                MapEntry<String, Object?>(k! as String, v),
          ),
        },
        expiresAt: json['expiresAt'] == null
            ? null
            : DateTime.parse(json['expiresAt']! as String),
      );

  /// The client-side upload identifier this session belongs to.
  final String uploadId;

  /// Server-assigned session/upload identifier, when the protocol has one.
  final String? sessionId;

  /// Endpoint the adapter should push chunks to, when applicable.
  final String? uploadUrl;

  /// Server-mandated chunk size. Overrides the configured size when set.
  final int? chunkSize;

  /// Indices of chunks the server already holds.
  ///
  /// Populated by adapters that can query upload state, which lets a resumed
  /// upload skip straight past everything already stored.
  final Set<int> uploadedChunkIndices;

  /// Bytes the server already holds, used as the progress baseline on resume.
  final int uploadedBytes;

  /// Headers the adapter wants echoed on subsequent requests.
  final Map<String, String> headers;

  /// Free-form adapter state (tokens, part ETags, offsets...).
  final Map<String, Object?> data;

  /// When the server-side session stops being valid, if known.
  final DateTime? expiresAt;

  /// Whether [expiresAt] is in the past.
  bool get isExpired => expiresAt != null && DateTime.now().isAfter(expiresAt!);

  /// Returns a copy with the given fields replaced.
  UploadSession copyWith({
    String? sessionId,
    String? uploadUrl,
    int? chunkSize,
    Set<int>? uploadedChunkIndices,
    int? uploadedBytes,
    Map<String, String>? headers,
    Map<String, Object?>? data,
    DateTime? expiresAt,
  }) =>
      UploadSession(
        uploadId: uploadId,
        sessionId: sessionId ?? this.sessionId,
        uploadUrl: uploadUrl ?? this.uploadUrl,
        chunkSize: chunkSize ?? this.chunkSize,
        uploadedChunkIndices: uploadedChunkIndices ?? this.uploadedChunkIndices,
        uploadedBytes: uploadedBytes ?? this.uploadedBytes,
        headers: headers ?? this.headers,
        data: data ?? this.data,
        expiresAt: expiresAt ?? this.expiresAt,
      );

  /// Returns a copy that additionally records [index] as stored.
  UploadSession withChunkUploaded(int index, int bytes) => copyWith(
        uploadedChunkIndices: <int>{...uploadedChunkIndices, index},
        uploadedBytes: uploadedBytes + bytes,
      );

  /// Serialises the session for persistence.
  Map<String, Object?> toJson() => <String, Object?>{
        'uploadId': uploadId,
        'sessionId': sessionId,
        'uploadUrl': uploadUrl,
        'chunkSize': chunkSize,
        'uploadedChunkIndices': uploadedChunkIndices.toList(growable: false),
        'uploadedBytes': uploadedBytes,
        'headers': headers,
        'data': data,
        'expiresAt': expiresAt?.toIso8601String(),
      };

  @override
  String toString() =>
      'UploadSession($uploadId, sessionId: $sessionId, stored: '
      '${uploadedChunkIndices.length} chunks / $uploadedBytes bytes)';
}
