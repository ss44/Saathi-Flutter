import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/notifications/reply_notifications.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _tabTo(WidgetTester tester, Finder target) async {
  bool focused() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    final targets = target.evaluate().toSet();
    var found = targets.contains(context);
    context.visitAncestorElements((element) {
      found = found || targets.contains(element);
      return !found;
    });
    return found;
  }

  for (var index = 0; index < 45 && !focused(); index++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
  }
  expect(focused(), isTrue, reason: 'Keyboard must reach $target');
}

void main() {
  testWidgets(
      'keyboard reaches global and chat preferences at 360px and 2x text',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final controller = ChatController(SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets()));
    await controller.load();
    final notifications = ReplyNotifications(controller.store.preferences);
    controller.notifications = notifications;
    addTearDown(notifications.dispose);
    await controller.addConnection({
      'id': 'direct',
      'name': 'Direct',
      'type': 'openai',
      'url': 'https://example.test'
    }, 'fixture');
    await controller.newSession(controller.connections.single, 'response', '');
    await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!),
        home: ChatHome(controller: controller)));
    await tester.pumpAndSettle();
    final composer = find.byKey(const Key('composer'));
    await tester.enterText(composer, 'Draft');
    await _tabTo(tester, find.byTooltip('Settings'));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Settings'), findsOneWidget);
    for (final label in ['Global prompt optimizer', 'Chat prompt optimizer']) {
      await _tabTo(tester, find.widgetWithText(ListTile, label));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    }
    for (final label in ['Notifications', 'App updates']) {
      await _tabTo(tester, find.widgetWithText(ListTile, label));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, label), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
    }
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(composer).controller!.text, 'Draft');
    await tester.tap(composer);
    await tester.pumpAndSettle();
    final editable =
        find.descendant(of: composer, matching: find.byType(EditableText));
    expect(tester.widget<EditableText>(editable).focusNode.hasFocus, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
