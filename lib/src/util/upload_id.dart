import 'dart:math' as math;

final math.Random _random = math.Random();
const String _alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';

/// Generates a sortable, collision-resistant upload identifier.
///
/// Format: `<base36 milliseconds>-<8 random chars>`, e.g. `m3k9x2p1-a7f2k9d1`.
/// The timestamp prefix keeps persisted records roughly ordered on disk, and
/// the suffix makes same-millisecond collisions vanishingly unlikely.
String generateUploadId() {
  final String time = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
  final String suffix = List<String>.generate(
    8,
    (_) => _alphabet[_random.nextInt(_alphabet.length)],
  ).join();
  return '$time-$suffix';
}
