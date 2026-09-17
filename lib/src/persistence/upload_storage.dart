import 'upload_record.dart';

/// Where upload state is kept between attempts — and between app launches.
///
/// The default is [MemoryUploadStorage], which survives pause/resume within a
/// session but not a restart. Pass [FileUploadStorage] (or your own
/// implementation over sqflite, Hive, shared_preferences...) to make uploads
/// survive the process dying.
abstract class UploadStorage {
  /// Const constructor so storages can be const.
  const UploadStorage();

  /// Inserts or replaces [record].
  Future<void> save(UploadRecord record);

  /// Reads the record for [uploadId], or `null` if there is none.
  Future<UploadRecord?> read(String uploadId);

  /// Reads every stored record, newest first.
  Future<List<UploadRecord>> readAll();

  /// Removes the record for [uploadId]. A no-op if it does not exist.
  Future<void> delete(String uploadId);

  /// Removes every record.
  Future<void> clear();
}
