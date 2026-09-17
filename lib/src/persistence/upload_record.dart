import 'package:meta/meta.dart';

import '../models/upload_options.dart';
import '../models/upload_session.dart';
import '../models/upload_status.dart';

/// The persisted form of an upload — everything needed to pick it up again
/// after the app was killed mid-transfer.
@immutable
class UploadRecord {
  /// Creates a record.
  const UploadRecord({
    required this.uploadId,
    required this.sourcePath,
    required this.fileName,
    required this.fileSize,
    required this.contentType,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.uploadPath,
    this.uploadSize = 0,
    this.checksum,
    this.checksumAlgorithm,
    this.chunkSize = 0,
    this.totalChunks = 0,
    this.uploadedChunkIndices = const <int>{},
    this.uploadedBytes = 0,
    this.session,
    this.options = const UploadOptions(),
    this.errorMessage,
    this.errorCode,
    this.attempts = 0,
  });

  /// Restores a record produced by [toJson].
  factory UploadRecord.fromJson(Map<String, Object?> json) => UploadRecord(
        uploadId: json['uploadId']! as String,
        sourcePath: json['sourcePath']! as String,
        fileName: json['fileName']! as String,
        fileSize: json['fileSize']! as int,
        contentType: json['contentType']! as String,
        status: UploadStatus.values.firstWhere(
          (UploadStatus s) => s.name == json['status'],
          orElse: () => UploadStatus.queued,
        ),
        createdAt: DateTime.parse(json['createdAt']! as String),
        updatedAt: DateTime.parse(json['updatedAt']! as String),
        uploadPath: json['uploadPath'] as String?,
        uploadSize: (json['uploadSize'] as int?) ?? 0,
        checksum: json['checksum'] as String?,
        checksumAlgorithm: json['checksumAlgorithm'] as String?,
        chunkSize: (json['chunkSize'] as int?) ?? 0,
        totalChunks: (json['totalChunks'] as int?) ?? 0,
        uploadedChunkIndices: <int>{
          ...?(json['uploadedChunkIndices'] as List<Object?>?)
              ?.map((Object? e) => e! as int),
        },
        uploadedBytes: (json['uploadedBytes'] as int?) ?? 0,
        session: json['session'] == null
            ? null
            : UploadSession.fromJson(
                (json['session']! as Map<Object?, Object?>).map(
                  (Object? k, Object? v) =>
                      MapEntry<String, Object?>(k! as String, v),
                ),
              ),
        options: json['options'] == null
            ? const UploadOptions()
            : UploadOptions.fromJson(
                (json['options']! as Map<Object?, Object?>).map(
                  (Object? k, Object? v) =>
                      MapEntry<String, Object?>(k! as String, v),
                ),
              ),
        errorMessage: json['errorMessage'] as String?,
        errorCode: json['errorCode'] as String?,
        attempts: (json['attempts'] as int?) ?? 0,
      );

  /// Client-side upload identifier. The storage key.
  final String uploadId;

  /// Path of the file the caller handed to the uploader.
  final String sourcePath;

  /// Path of the bytes actually being uploaded — the compressed temporary copy
  /// when compression ran, otherwise the same as [sourcePath].
  final String? uploadPath;

  /// Name reported to the backend.
  final String fileName;

  /// Size of the source file in bytes.
  final int fileSize;

  /// Size of the payload at [uploadPath] in bytes.
  final int uploadSize;

  /// MIME type of the payload.
  final String contentType;

  /// The state the upload was in when the record was written.
  final UploadStatus status;

  /// Whole-file digest, when one was computed.
  final String? checksum;

  /// Algorithm used for [checksum], e.g. `md5`.
  final String? checksumAlgorithm;

  /// Chunk size used for the plan.
  final int chunkSize;

  /// Number of chunks in the plan.
  final int totalChunks;

  /// Chunks known to be stored server-side.
  final Set<int> uploadedChunkIndices;

  /// Bytes known to be stored server-side.
  final int uploadedBytes;

  /// The adapter's session, so a resume can continue rather than re-initialise.
  final UploadSession? session;

  /// The options the upload was started with.
  final UploadOptions options;

  /// Last failure message, when [status] is [UploadStatus.failed].
  final String? errorMessage;

  /// Last failure code, when [status] is [UploadStatus.failed].
  final String? errorCode;

  /// How many attempts have been made so far.
  final int attempts;

  /// When the upload was first enqueued.
  final DateTime createdAt;

  /// When the record was last written.
  final DateTime updatedAt;

  /// Whether this record describes an upload that can be resumed.
  bool get isResumable =>
      status.isResumable || status == UploadStatus.uploading;

  /// Returns a copy with the given fields replaced.
  UploadRecord copyWith({
    String? uploadPath,
    int? uploadSize,
    String? contentType,
    UploadStatus? status,
    String? checksum,
    String? checksumAlgorithm,
    int? chunkSize,
    int? totalChunks,
    Set<int>? uploadedChunkIndices,
    int? uploadedBytes,
    UploadSession? session,
    UploadOptions? options,
    String? errorMessage,
    String? errorCode,
    int? attempts,
    DateTime? updatedAt,
    bool clearError = false,
  }) =>
      UploadRecord(
        uploadId: uploadId,
        sourcePath: sourcePath,
        fileName: fileName,
        fileSize: fileSize,
        contentType: contentType ?? this.contentType,
        status: status ?? this.status,
        createdAt: createdAt,
        updatedAt: updatedAt ?? DateTime.now(),
        uploadPath: uploadPath ?? this.uploadPath,
        uploadSize: uploadSize ?? this.uploadSize,
        checksum: checksum ?? this.checksum,
        checksumAlgorithm: checksumAlgorithm ?? this.checksumAlgorithm,
        chunkSize: chunkSize ?? this.chunkSize,
        totalChunks: totalChunks ?? this.totalChunks,
        uploadedChunkIndices: uploadedChunkIndices ?? this.uploadedChunkIndices,
        uploadedBytes: uploadedBytes ?? this.uploadedBytes,
        session: session ?? this.session,
        options: options ?? this.options,
        errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
        errorCode: clearError ? null : errorCode ?? this.errorCode,
        attempts: attempts ?? this.attempts,
      );

  /// Serialises the record.
  Map<String, Object?> toJson() => <String, Object?>{
        'uploadId': uploadId,
        'sourcePath': sourcePath,
        'uploadPath': uploadPath,
        'fileName': fileName,
        'fileSize': fileSize,
        'uploadSize': uploadSize,
        'contentType': contentType,
        'checksum': checksum,
        'checksumAlgorithm': checksumAlgorithm,
        'chunkSize': chunkSize,
        'totalChunks': totalChunks,
        'uploadedChunkIndices': uploadedChunkIndices.toList(growable: false),
        'uploadedBytes': uploadedBytes,
        'session': session?.toJson(),
        'options': options.toJson(),
        'status': status.name,
        'errorMessage': errorMessage,
        'errorCode': errorCode,
        'attempts': attempts,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  @override
  String toString() => 'UploadRecord($uploadId, $fileName, ${status.name}, '
      '${uploadedChunkIndices.length}/$totalChunks chunks)';
}
