import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/notifications/reply_notifications.dart';
import 'package:saathi/notifications/settings.dart';

class _Adapter implements NotificationAdapter {
  bool granted = false;
  int requests = 0;
  @override
  bool get supported => true;
  @override
  Future<bool> requestPermission() async {
    requests++;
    return granted;
  }

  @override
  Future<void> show(String conversationId) async {}
  @override
  Future<String?> consumePendingTap() async => null;
}

void main() {
  testWidgets('notification settings fit 360px at 2x text and require consent',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final adapter = _Adapter();
    final notifications = ReplyNotifications(
        await SharedPreferences.getInstance(),
        adapter: adapter);
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ),
      home: Scaffold(
          appBar: AppBar(actions: [
        NotificationSettingsButton(notifications: notifications)
      ])),
    ));
    expect(adapter.requests, 0);
    await tester.tap(find.byTooltip('Notifications'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(notifications.enabled, isFalse);
    expect(adapter.requests, 0);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(adapter.requests, 1);
    expect(notifications.enabled, isFalse);
    expect(
        find.text(
            'Could not change notifications. Check Android notification settings.'),
        findsOneWidget);
    adapter.granted = true;
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(adapter.requests, 2);
    expect(notifications.enabled, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    notifications.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
