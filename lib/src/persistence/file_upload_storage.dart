import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../exceptions/upload_exception.dart';
import 'upload_record.dart';
import 'upload_storage.dart';

/// Stores one JSON file per upload inside a directory.
///
/// Dependency-free persistence that survives app restarts. Give it a directory
/// your app owns — in Flutter, typically
/// `(await getApplicationSupportDirectory())` joined with a subfolder:
///
/// ```dart
/// final Directory dir = Directory(
///   p.join((await getApplicationSupportDirectory()).path, 'uploads'),
/// );
/// final SmartUploader uploader = SmartUploader(
///   config: SmartUploadConfig(storage: FileUploadStorage(dir)),
/// );
/// ```
///
/// Writes go to a temporary file that is then renamed, so a crash mid-write
/// cannot leave a half-written record behind.
class FileUploadStorage extends UploadStorage {
  /// Creates a store backed by [directory], which is created on first use.
  FileUploadStorage(this.directory);

  /// Where records are kept.
  final Directory directory;

  bool _ensured = false;

  Future<void> _ensureDirectory() async {
    if (_ensured) return;
    try {
      if (!directory.existsSync()) {
        await directory.create(recursive: true);
      }
      _ensured = true;
    } on FileSystemException catch (e, s) {
      throw SmartUploadException(
        'Cannot create upload state directory ${directory.path}: ${e.message}',
        errorCode: UploadErrorCode.storageError,
        cause: e,
        stackTrace: s,
      );
    }
  }

  File _fileFor(String uploadId) =>
      File(p.join(directory.path, '$uploadId.json'));

  @override
  Future<void> save(UploadRecord record) async {
    await _ensureDirectory();
    final File target = _fileFor(record.uploadId);
    final File temp = File('${target.path}.tmp');
    try {
      await temp.writeAsString(jsonEncode(record.toJson()), flush: true);
      await temp.rename(target.path);
    } on FileSystemException catch (e, s) {
      throw SmartUploadException(
        'Cannot persist upload ${record.uploadId}: ${e.message}',
        errorCode: UploadErrorCode.storageError,
        cause: e,
        stackTrace: s,
      );
    }
  }

  @override
  Future<UploadRecord?> read(String uploadId) async {
    final File file = _fileFor(uploadId);
    if (!file.existsSync()) return null;
    return _decode(file);
  }

  @override
  Future<List<UploadRecord>> readAll() async {
    if (!directory.existsSync()) return const <UploadRecord>[];
    final List<UploadRecord> records = <UploadRecord>[];
    await for (final FileSystemEntity entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final UploadRecord? record = await _decode(entity);
      if (record != null) records.add(record);
    }
    records.sort(
      (UploadRecord a, UploadRecord b) => b.createdAt.compareTo(a.createdAt),
    );
    return records;
  }

  @override
  Future<void> delete(String uploadId) async {
    final File file = _fileFor(uploadId);
    if (file.existsSync()) {
      try {
        await file.delete();
      } on FileSystemException {
        // Losing a stale record is not worth failing an upload over.
      }
    }
  }

  @override
  Future<void> clear() async {
    if (!directory.existsSync()) return;
    await for (final FileSystemEntity entity in directory.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        try {
          await entity.delete();
        } on FileSystemException {
          // Best effort.
        }
      }
    }
  }

  /// Reads and decodes a record, discarding (and deleting) corrupt files
  /// rather than letting them break every subsequent read.
  Future<UploadRecord?> _decode(File file) async {
    try {
      final String raw = await file.readAsString();
      final Object? json = jsonDecode(raw);
      if (json is! Map<String, Object?>) return null;
      return UploadRecord.fromJson(json);
    } on FormatException {
      await file.delete().catchError((_) => file);
      return null;
    } on TypeError {
      await file.delete().catchError((_) => file);
      return null;
    } on FileSystemException {
      return null;
    }
  }
}
