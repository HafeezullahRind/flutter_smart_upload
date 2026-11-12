// A short, self-contained run used to record the animated demo in the README:
// two files uploading side by side, paused mid-flight, resumed, finished.
//
//   xcrun simctl io booted recordVideo demo.mov &
//   flutter drive \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/demo_test.dart \
//     -d <device>

import 'package:flutter_smart_upload_example/main.dart' as app;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('records the demo', (WidgetTester tester) async {
    app.main();
    await _pumpFor(tester, const Duration(seconds: 3));

    final Finder discard = find.text('Discard');
    if (discard.evaluate().isNotEmpty) {
      await tester.tap(discard);
      await _pumpFor(tester, const Duration(seconds: 1));
    }

    for (int i = 0; i < 3; i++) {
      await tester.tap(find.text('Add 24 MB demo file'));
      await _pumpFor(tester, const Duration(milliseconds: 900));
    }

    await _pumpFor(tester, const Duration(seconds: 5));
    await tester.tap(find.byTooltip('Pause all'));
    await _pumpFor(tester, const Duration(seconds: 3));
    await tester.tap(find.byTooltip('Resume all'));

    // Hold until every row says 'completed', so the recording ends on the
    // finished queue rather than mid-transfer.
    final DateTime end = DateTime.now().add(const Duration(seconds: 90));
    while (DateTime.now().isBefore(end) &&
        find.text('completed').evaluate().length < 3) {
      await _pumpFor(tester, const Duration(milliseconds: 200));
    }
    await _pumpFor(tester, const Duration(seconds: 3));
  }, timeout: const Timeout(Duration(minutes: 4)));
}

Future<void> _pumpFor(WidgetTester tester, Duration duration) async {
  final DateTime end = DateTime.now().add(duration);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 60));
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
