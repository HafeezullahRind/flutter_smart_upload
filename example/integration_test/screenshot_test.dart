// Drives the demo app through the states the README talks about and captures
// a screenshot of each one.
//
//   flutter drive \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/screenshot_test.dart \
//     -d <device>
//
// The driver writes the PNGs to `doc/screenshots/raw/`; `tool/screenshots.sh`
// resizes them into the images the README points at.

import 'package:flutter/material.dart';
import 'package:flutter_smart_upload_example/main.dart' as app;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('captures the README screenshots', (WidgetTester tester) async {
    app.main();
    await _pumpFor(tester, const Duration(seconds: 3));
    await _discardLeftovers(tester);

    await binding.takeScreenshot('00-start');

    // Three files, two upload slots: the third waits in the queue.
    for (int i = 0; i < 3; i++) {
      await tester.tap(find.text('Add 24 MB demo file'));
      await _pumpFor(tester, const Duration(milliseconds: 1200));
    }
    await _pumpFor(tester, const Duration(seconds: 3));
    await binding.takeScreenshot('01-queue');

    await tester.tap(find.byTooltip('Pause all'));
    await _pumpFor(tester, const Duration(seconds: 1));
    await binding.takeScreenshot('02-paused');

    await tester.tap(find.byTooltip('Resume all'));
    await _waitFor(
      tester,
      () => find.textContaining('Completed →').evaluate().isNotEmpty,
      const Duration(seconds: 90),
    );
    await _pumpFor(tester, const Duration(seconds: 1));
    await binding.takeScreenshot('03-completed');

    // Offline: the transfer parks itself instead of hammering a dead link.
    await tester.tap(find.text('Add 24 MB demo file'));
    await _pumpFor(tester, const Duration(seconds: 3));
    await tester.tap(find.text('Simulate offline'));
    await _waitFor(
      tester,
      () => find.textContaining('Waiting for network').evaluate().isNotEmpty,
      const Duration(seconds: 20),
    );
    await _scrollToBottom(tester);
    await binding.takeScreenshot('04-offline');

    await tester.tap(find.text('Simulate offline'));
    await _pumpFor(tester, const Duration(seconds: 2));

    // Flaky server: 25% of chunks fail, and the retries show up in the log.
    await tester.tap(find.text('Simulate flaky server'));
    await _pumpFor(tester, const Duration(seconds: 5)); // let the snack bar go
    await tester.tap(find.text('Add 24 MB demo file'));
    await _waitFor(
      tester,
      () => find.textContaining('Retry #').evaluate().isNotEmpty,
      const Duration(seconds: 40),
    );
    await _scrollToBottom(tester);
    await binding.takeScreenshot('05-retry');
  }, timeout: const Timeout(Duration(minutes: 6)));
}

/// Pumps frames for [duration] of wall-clock time.
///
/// [WidgetTester.pumpAndSettle] is useless here: progress bars and spinners
/// mean the tree never settles.
Future<void> _pumpFor(WidgetTester tester, Duration duration) async {
  final DateTime end = DateTime.now().add(duration);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 60));
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() condition,
  Duration timeout,
) async {
  final DateTime end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (condition()) return;
    await _pumpFor(tester, const Duration(milliseconds: 200));
  }
  throw StateError('Timed out waiting for the app to reach the next state');
}

Future<void> _scrollToBottom(WidgetTester tester) async {
  final Finder list = find.byType(ListView);
  if (list.evaluate().isEmpty) return;
  await tester.drag(list, const Offset(0, -600));
  await _pumpFor(tester, const Duration(milliseconds: 800));
}

/// A previous run may have left unfinished uploads on disk; start clean.
Future<void> _discardLeftovers(WidgetTester tester) async {
  final Finder discard = find.text('Discard');
  if (discard.evaluate().isEmpty) return;
  await tester.tap(discard);
  await _pumpFor(tester, const Duration(seconds: 1));
}
