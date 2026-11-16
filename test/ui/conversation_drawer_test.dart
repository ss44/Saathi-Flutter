import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/main.dart';
import 'package:saathi/storage/saathi_store.dart';

void main() {
  for (final populated in [false, true]) {
    for (final width in [390.0, 360.0]) {
      testWidgets(
          'edge pull opens and closes native drawer populated=$populated width=$width',
          (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 844);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        SharedPreferences.setMockInitialValues({});
        final store = SaathiStore(
            preferences: await SharedPreferences.getInstance(),
            secrets: MemorySecrets());
        if (populated) {
          await store.saveChats([
            {
              'id': 'local',
              'connectionId': 'removed',
              'model': 'test',
              'messages': [
                {'role': 'assistant', 'content': 'Local answer'}
              ]
            }
          ]);
        }
        await tester.pumpWidget(SaathiApp(
            store: store,
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(width == 360 ? 2 : 1)),
                child: child!)));
        await tester.pumpAndSettle();
        await tester.dragFrom(const Offset(40, 300), const Offset(280, 0));
        await tester.pumpAndSettle();
        expect(
            tester
                .state<ScaffoldState>(find.byType(Scaffold).first)
                .isDrawerOpen,
            isTrue);
        await tester.dragFrom(const Offset(250, 300), const Offset(-280, 0));
        await tester.pumpAndSettle();
        expect(
            tester
                .state<ScaffoldState>(find.byType(Scaffold).first)
                .isDrawerOpen,
            isFalse);
        await tester.tap(find.byTooltip('Open navigation menu'));
        await tester.pumpAndSettle();
        expect(find.text('On this device'), findsOneWidget);
        await tester.tapAt(Offset(width - 4, 300));
        await tester.pumpAndSettle();
        expect(
            tester
                .state<ScaffoldState>(find.byType(Scaffold).first)
                .isDrawerOpen,
            isFalse);
      });
    }
  }
}
