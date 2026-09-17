import 'package:path/path.dart' as p;

/// Fallback MIME type for anything unrecognised.
const String kDefaultContentType = 'application/octet-stream';

const Map<String, String> _byExtension = <String, String>{
  // Images
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'bmp': 'image/bmp',
  'heic': 'image/heic',
  'heif': 'image/heif',
  'tif': 'image/tiff',
  'tiff': 'image/tiff',
  'svg': 'image/svg+xml',
  // Video
  'mp4': 'video/mp4',
  'm4v': 'video/x-m4v',
  'mov': 'video/quicktime',
  'avi': 'video/x-msvideo',
  'mkv': 'video/x-matroska',
  'webm': 'video/webm',
  '3gp': 'video/3gpp',
  // Audio
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'wav': 'audio/wav',
  'aac': 'audio/aac',
  'ogg': 'audio/ogg',
  'flac': 'audio/flac',
  // Documents
  'pdf': 'application/pdf',
  'doc': 'application/msword',
  'docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xls': 'application/vnd.ms-excel',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'ppt': 'application/vnd.ms-powerpoint',
  'pptx': 'application/vnd.openxmlformats-officedocument.presentationml'
      '.presentation',
  'txt': 'text/plain',
  'csv': 'text/csv',
  'json': 'application/json',
  'xml': 'application/xml',
  'html': 'text/html',
  // Archives
  'zip': 'application/zip',
  'gz': 'application/gzip',
  'tar': 'application/x-tar',
  'rar': 'application/vnd.rar',
  '7z': 'application/x-7z-compressed',
};

/// Guesses a MIME type from a file path's extension.
///
/// Deliberately extension-based: sniffing magic bytes would mean opening and
/// reading every file just to name it.
String contentTypeForPath(String path) {
  final String ext = p.extension(path).replaceFirst('.', '').toLowerCase();
  return _byExtension[ext] ?? kDefaultContentType;
}

/// Whether [contentType] names an image format.
bool isImageContentType(String contentType) => contentType.startsWith('image/');
