import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_smart_upload/flutter_smart_upload.dart';
// Imported so the demo app's code is compiled and type-checked by this suite.
import 'package:flutter_smart_upload_example/main.dart';
import 'package:flutter_smart_upload_example/upload_tile.dart';
import 'package:flutter_test/flutter_test.dart';

/// `testWidgets` drives a fake clock, and real file I/O never completes under
/// it — so every interaction with the uploader is wrapped in
/// [WidgetTester.runAsync], which hands control back to the real event loop.
void main() {
  late Directory dir;
  late SmartUploader uploader;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('fsu_example');
    uploader = SmartUploader(
      adapter: InMemoryUploadAdapter(),
      config: SmartUploadConfig(
        chunkSize: 1024,
        progressInterval: Duration.zero,
      ),
    );
  });

  tearDown(() => dir.deleteSync(recursive: true));

  testWidgets('renders the file name and finishes at 100%',
      (WidgetTester tester) async {
    final File file = File('${dir.path}/photo.jpg')
      ..writeAsBytesSync(List<int>.filled(4096, 7));

    late UploadTask task;
    await tester.runAsync(() async {
      task = await uploader.upload(file: file);
    });

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: UploadTile(task: task, onRetry: () {}))),
    );
    expect(find.text('photo.jpg'), findsOneWidget);

    await tester.runAsync(() => task.done);
    await tester.pump();

    expect(find.text('completed'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      1.0,
    );
    expect(find.textContaining('memory://uploads/'), findsOneWidget);
    await tester.runAsync(uploader.dispose);
  });

  testWidgets('a cancelled upload offers no actions',
      (WidgetTester tester) async {
    final File file = File('${dir.path}/doc.pdf')
      ..writeAsBytesSync(List<int>.filled(8192, 3));

    late UploadTask task;
    await tester.runAsync(() async {
      task = await uploader.upload(file: file);
      await task.cancel();
    });

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: UploadTile(task: task, onRetry: () {}))),
    );

    expect(find.text('cancelled'), findsOneWidget);
    expect(find.byType(IconButton), findsNothing);
    await tester.runAsync(uploader.dispose);
  });

  testWidgets('a queued upload offers pause and cancel',
      (WidgetTester tester) async {
    final File file = File('${dir.path}/queued.bin')
      ..writeAsBytesSync(List<int>.filled(2048, 1));

    // Holding the queue closed keeps the task in `queued` for the assertion.
    final SmartUploader held = SmartUploader(
      adapter: InMemoryUploadAdapter(),
      config: SmartUploadConfig(chunkSize: 1024, autoStart: false),
    );
    late UploadTask task;
    await tester.runAsync(() async {
      task = await held.upload(file: file);
    });

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: UploadTile(task: task, onRetry: () {}))),
    );

    expect(find.text('queued'), findsOneWidget);
    expect(find.byIcon(Icons.pause), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
    await tester.runAsync(held.dispose);
  });

  test('the demo app is a MaterialApp shell', () {
    expect(
        const SmartUploadDemoApp().build(_FakeContext()), isA<MaterialApp>());
  });
}

/// The app shell does not touch its context, so a stub is enough to build it
/// without a widget tree (and without the plugins the real page needs).
class _FakeContext extends StatelessElement {
  _FakeContext() : super(const SmartUploadDemoApp());
}
