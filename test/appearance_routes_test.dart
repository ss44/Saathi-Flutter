import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/main.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/connections.dart';
import 'package:saathi/update_host.dart';
import 'appearance_surfaces_test.dart' show appearanceChatStore;

void main() {
  testWidgets(
      'menus drawer connection dialogs and updates inherit live brightness',
      (tester) async {
    PackageInfo.setMockInitialValues(
        appName: 'Saathi',
        packageName: 'test.saathi',
        version: '0.1.0',
        buildNumber: '1',
        buildSignature: '');
    final store = await appearanceChatStore();
    var posts = 0;
    final client = MockClient((request) async {
      if (request.method == 'POST') posts++;
      return http.Response('{"data":[]}', 200);
    });
    addTearDown(client.close);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(
        SaathiApp(store: store, coreFactory: () => SaathiCore(client: client)));
    await tester.pumpAndSettle();
    Future<void> check(Finder target) async {
      for (final brightness in Brightness.values) {
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        await tester.pumpAndSettle();
        expect(Theme.of(tester.element(target)).brightness, brightness);
        expect(tester.takeException(), isNull);
      }
    }

    await tester.enterText(find.byKey(const Key('composer')), 'Unsent draft');
    await tester.pump();
    await tester.longPress(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Enhance prompt'), findsOneWidget);
    await check(find.byTooltip('Enhance prompt'));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(posts, 0);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await check(find.byType(Drawer));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await check(find.byType(ConnectionsPage));
    await tester.ensureVisible(
        find.widgetWithText(ListTile, 'Global prompt optimizer'));
    await tester.tap(find.widgetWithText(ListTile, 'Global prompt optimizer'));
    await tester.pumpAndSettle();
    await check(find.byType(AlertDialog));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(ListTile, 'App updates'));
    await tester.tap(find.widgetWithText(ListTile, 'App updates'));
    await tester.pumpAndSettle();
    await check(find.byType(SaathiUpdatesPage));
    expect(find.text('Current version: 0.1.0'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Add connection'));
    await tester.tap(find.text('Add connection'));
    await tester.pumpAndSettle();
    await check(find.byType(AddConnectionPage));
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Delete conversation'));
    await tester.pumpAndSettle();
    await check(find.byType(AlertDialog));
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('composer')))
            .controller!
            .text,
        'Unsent draft');
    expect(
        tester
            .widget<ChatHome>(find.byType(ChatHome))
            .controller
            .current!
            .connectionId,
        'local');
    expect(posts, 0);
  });
}
