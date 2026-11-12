import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

/// Writes every screenshot the integration test takes into `doc/screenshots/`
/// at the repository root, so the README can point at real pixels.
Future<void> main() async {
  await integrationDriver(
    onScreenshot: (
      String name,
      List<int> bytes, [
      Map<String, Object?>? args,
    ]) async {
      final File file = File('../doc/screenshots/raw/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
      stdout.writeln('wrote ${file.path} (${bytes.length} bytes)');
      return true;
    },
  );
}
