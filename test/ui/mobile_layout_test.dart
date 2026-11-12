import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/main.dart';
import 'package:saathi/storage/saathi_store.dart';

void main() {
  testWidgets('mobile layouts handle 390px and 360px at 2x text with keyboard',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
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
          final loader = FontLoader(font.key)
            ..addFont(
                Future.value(ByteData.sublistView(await file.readAsBytes())));
          await loader.load();
        }
      }
    });
    final repaint = GlobalKey();
    var scale = 1.0;
    var keyboard = 0.0;
    SharedPreferences.setMockInitialValues({});
    final store = SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets());
    Widget app() => SaathiApp(
        store: store,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                viewInsets: EdgeInsets.only(bottom: keyboard)),
            child: RepaintBoundary(key: repaint, child: child!)));
    Future<void> capture(String name) async {
      expect(tester.takeException(), isNull);
      if (!const bool.fromEnvironment('SAATHI_CAPTURE_PREVIEWS')) return;
      await tester.runAsync(() async {
        final boundary = repaint.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('docs/previews/saathi-$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }

    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await capture('empty-390');
    await tester.tap(find.byTooltip('Connection settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add connection'));
    await tester.pumpAndSettle();
    await capture('connection-390');
    tester.view.physicalSize = const Size(360, 800);
    scale = 2;
    keyboard = 300;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Connection name'),
        'Local development');
    await tester.pumpAndSettle();
    await capture('connection-360-text2-keyboard');
    await tester.enterText(find.widgetWithText(TextFormField, 'API base URL'),
        'http://localhost:1234');
    await tester.scrollUntilVisible(find.text('Save connection'), 180,
        scrollable: find
            .descendant(
                of: find.byType(ListView).last,
                matching: find.byType(Scrollable))
            .first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Save connection'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New conversation'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Model ID'), 'local-model');
    await tester.pumpAndSettle();
    await capture('new-chat-360-text2-keyboard');
    await tester.scrollUntilVisible(find.text('Start conversation'), 160,
        scrollable: find
            .descendant(
                of: find.byType(ListView).last,
                matching: find.byType(Scrollable))
            .first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Start conversation'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await capture('chat-360-text2-keyboard');
  });
}
