import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

import '../exceptions/upload_exception.dart';

/// Computes integrity digests for files and chunks.
///
/// Hashing is opt-in (see [ChecksumMode]) because it costs a full extra read
/// of the file. Implement this interface to use a cheaper rolling hash, a
/// platform-native digest, or a server-specific scheme such as S3's
/// multipart ETag.
abstract class ChecksumProvider {
  /// Const constructor so providers can be const.
  const ChecksumProvider();

  /// Name of the algorithm, e.g. `md5`. Sent to adapters alongside digests.
  String get algorithm;

  /// Digests the whole [file].
  ///
  /// Implementations must stream the file rather than reading it into memory.
  Future<String> calculate(File file);

  /// Digests an in-memory buffer, used for per-chunk checksums.
  Future<String> calculateBytes(List<int> bytes);
}

/// Base class for [crypto]-backed providers that hash a file by streaming it.
abstract class _DigestChecksumProvider extends ChecksumProvider {
  const _DigestChecksumProvider();

  /// The underlying hash.
  Hash get hash;

  @override
  Future<String> calculate(File file) async {
    if (!file.existsSync()) {
      throw SmartUploadException.fileNotFound(file.path);
    }
    try {
      // `bind` consumes the file as a stream of blocks; the whole file is
      // never resident.
      final Digest digest = await hash.bind(file.openRead()).first;
      return digest.toString();
    } on FileSystemException catch (e, s) {
      throw SmartUploadException(
        'Failed to checksum ${file.path}: ${e.message}',
        errorCode: UploadErrorCode.invalidFile,
        cause: e,
        stackTrace: s,
      );
    }
  }

  @override
  Future<String> calculateBytes(List<int> bytes) async =>
      hash.convert(bytes).toString();
}

/// MD5 digests, hex encoded. Fast, and what most upload APIs expect for
/// `Content-MD5`.
class Md5ChecksumProvider extends _DigestChecksumProvider {
  /// Creates the provider.
  const Md5ChecksumProvider();

  @override
  String get algorithm => 'md5';

  @override
  Hash get hash => md5;
}

/// SHA-256 digests, hex encoded. Slower than MD5, collision resistant.
class Sha256ChecksumProvider extends _DigestChecksumProvider {
  /// Creates the provider.
  const Sha256ChecksumProvider();

  @override
  String get algorithm => 'sha256';

  @override
  Hash get hash => sha256;
}

/// Base64-encoded MD5, the form S3 and GCS want in `Content-MD5`.
class Md5Base64ChecksumProvider extends ChecksumProvider {
  /// Creates the provider.
  const Md5Base64ChecksumProvider();

  @override
  String get algorithm => 'md5-base64';

  @override
  Future<String> calculate(File file) async {
    if (!file.existsSync()) {
      throw SmartUploadException.fileNotFound(file.path);
    }
    final Digest digest = await md5.bind(file.openRead()).first;
    return base64Encode(digest.bytes);
  }

  @override
  Future<String> calculateBytes(List<int> bytes) async =>
      base64Encode(md5.convert(bytes).bytes);
}

/// A provider that fingerprints a file from its path, size and modification
/// time instead of its contents.
///
/// Not cryptographically meaningful, but it costs nothing and is enough to
/// detect "the file on disk changed since we persisted this upload", which is
/// the check that matters most when resuming.
class FileStatChecksumProvider extends ChecksumProvider {
  /// Creates the provider.
  const FileStatChecksumProvider();

  @override
  String get algorithm => 'file-stat';

  @override
  Future<String> calculate(File file) async {
    if (!file.existsSync()) {
      throw SmartUploadException.fileNotFound(file.path);
    }
    final FileStat stat = await file.stat();
    final String raw =
        '${file.path}:${stat.size}:${stat.modified.millisecondsSinceEpoch}';
    return md5.convert(utf8.encode(raw)).toString();
  }

  @override
  Future<String> calculateBytes(List<int> bytes) async =>
      md5.convert(bytes).toString();
}
