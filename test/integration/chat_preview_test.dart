import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/main.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_home.dart';

void main() {
  testWidgets(
      'populated mobile conversation renders and activity stays tucked away',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final root =
        Platform.environment['FLUTTER_ROOT'] ?? '/opt/data/tools/flutter';
    await tester.runAsync(() async {
      for (final font in {
        'Roboto': 'Roboto-Regular.ttf',
        'MaterialIcons': 'MaterialIcons-Regular.otf'
      }.entries) {
        final file =
            File('$root/bin/cache/artifacts/material_fonts/${font.value}');
        if (file.existsSync()) {
          await (FontLoader(font.key)
                ..addFont(Future.value(
                    ByteData.sublistView(await file.readAsBytes()))))
              .load();
        }
      }
    });
    SharedPreferences.setMockInitialValues({});
    final store = SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets());
    // Explicit synthetic display fixture. No provider is contacted by this test.
    await store.saveConnection({
      'id': 'preview',
      'name': 'Local model',
      'type': 'openai',
      'url': 'http://localhost:1234'
    }, apiKey: '');
    await store.saveChats([
      {
        'id': 'preview-chat',
        'connectionId': 'preview',
        'model': 'your-model',
        'messages': [
          {
            'role': 'user',
            'content': 'Can you help me plan a focused morning?'
          },
          {
            'role': 'model',
            'content':
                'Start with **one thing**.\n\n- Pick your most important task.\n- Give it 45 quiet minutes.\n- Take a short break before checking messages.\n\nWhat would you like to make progress on?'
          }
        ]
      }
    ]);
    final repaint = GlobalKey();
    await tester.pumpWidget(SaathiApp(
        store: store,
        builder: (_, child) => RepaintBoundary(key: repaint, child: child!)));
    await tester.pumpAndSettle();
    expect(find.byType(MessageView), findsNWidgets(2));
    expect(find.textContaining('Activity ·'), findsNothing);
    expect(tester.takeException(), isNull);
    Future<void> capture(String name) async {
      if (!const bool.fromEnvironment('SAATHI_CAPTURE_PREVIEWS')) return;
      await tester.runAsync(() async {
        final boundary = repaint.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('docs/previews/saathi-$name.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }

    await capture('conversation-390');
    await tester.drag(find.byType(MessageView).last, const Offset(-200, 0));
    await tester.pumpAndSettle();
    expect(find.textContaining('Activity · Response received'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await capture('conversation-activity-390');
  });
}
