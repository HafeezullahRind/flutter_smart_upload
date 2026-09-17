import 'upload_record.dart';
import 'upload_storage.dart';

/// In-process storage. The default.
///
/// Enough for pause/resume and retry within a single app session; everything
/// is lost when the process exits. Use [FileUploadStorage] for uploads that
/// must survive a restart.
class MemoryUploadStorage extends UploadStorage {
  /// Creates an empty store.
  MemoryUploadStorage();

  final Map<String, UploadRecord> _records = <String, UploadRecord>{};

  @override
  Future<void> save(UploadRecord record) async {
    _records[record.uploadId] = record;
  }

  @override
  Future<UploadRecord?> read(String uploadId) async => _records[uploadId];

  @override
  Future<List<UploadRecord>> readAll() async {
    final List<UploadRecord> all = _records.values.toList();
    all.sort(
      (UploadRecord a, UploadRecord b) => b.createdAt.compareTo(a.createdAt),
    );
    return all;
  }

  @override
  Future<void> delete(String uploadId) async {
    _records.remove(uploadId);
  }

  @override
  Future<void> clear() async => _records.clear();
}
