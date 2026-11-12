import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/core/saathi_core.dart' hide RemoteHistoryPage;
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/remote_sessions.dart';

final _pixel = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=');

class _ImageClient implements HttpClient {
  _ImageClient(this.requests);
  final List<Uri> requests;
  @override
  set autoUncompress(bool value) {}
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requests.add(url);
    return _ImageRequest();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImageRequest implements HttpClientRequest {
  @override
  Future<HttpClientResponse> close() async => _ImageResponse();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImageResponse extends Stream<List<int>> implements HttpClientResponse {
  @override
  int get statusCode => HttpStatus.ok;
  @override
  int get contentLength => _pixel.length;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  StreamSubscription<List<int>> listen(void Function(List<int>)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      Stream<List<int>>.value(_pixel).listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImageFile implements File {
  _ImageFile(this.path, this.reads);
  @override
  final String path;
  final List<String> reads;
  @override
  Future<int> length() async {
    reads.add(path);
    return _pixel.length;
  }

  @override
  Future<Uint8List> readAsBytes() async {
    reads.add(path);
    return _pixel;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _render(
    WidgetTester tester, String surface, String markdown) async {
  PaintingBinding.instance.imageCache.clear();
  PaintingBinding.instance.imageCache.clearLiveImages();
  if (surface == 'chat') {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: MessageView(text: markdown, user: false))));
  } else {
    SharedPreferences.setMockInitialValues({});
    final store = SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets());
    final controller = ChatController(store,
        coreFactory: () => SaathiCore(
            client: MockClient((_) async => http.Response(
                jsonEncode({
                  'session_id': 'remote',
                  'data': [
                    {'role': 'assistant', 'content': markdown}
                  ],
                  'pagination': {'has_more': false},
                }),
                200))));
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
        home: RemoteHistoryPage(
            controller: controller,
            connection: const {
              'id': 'h',
              'name': 'Hermes',
              'url': 'https://hermes.example',
              'type': 'hermes'
            },
            session: RemoteSession({'id': 'remote', 'title': 'Remote'}))));
  }
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  await tester.pumpAndSettle();
}

void main() {
  for (final surface in ['chat', 'remote']) {
    testWidgets('$surface Markdown never automatically requests HTTP(S) images',
        (tester) async {
      final requests = <Uri>[];
      debugNetworkImageHttpClientProvider = () => HttpClient();
      try {
        await HttpOverrides.runZoned(() async {
          await _render(
              tester,
              surface,
              'Visible **answer**\n\n![tracking](http://attacker.invalid/pixel)\n\n'
              '![secure](https://attacker.invalid/secret)');
          expect(requests, isEmpty);
          expect(find.byType(Image), findsNothing);
          expect(find.textContaining('Visible'), findsOneWidget);
          expect(find.textContaining('Image blocked'), findsNWidgets(2));
        }, createHttpClient: (_) => _ImageClient(requests));
      } finally {
        debugNetworkImageHttpClientProvider = null;
      }
    });

    testWidgets('$surface raw HTML images perform no network or file reads',
        (tester) async {
      final requests = <Uri>[];
      final reads = <String>[];
      debugNetworkImageHttpClientProvider = () => HttpClient();
      try {
        await HttpOverrides.runZoned(() async {
          await IOOverrides.runZoned(() async {
            await _render(
                tester,
                surface,
                'Visible answer\n\n<img src="http://attacker.invalid/raw">\n\n'
                '<img src="https://attacker.invalid/raw">\n\n'
                '<img src="file:///private/raw.png">');
            expect(requests, isEmpty);
            expect(reads, isEmpty);
            expect(find.byType(Image), findsNothing);
            expect(find.textContaining('Visible'), findsOneWidget);
          }, createFile: (path) => _ImageFile(path, reads));
        }, createHttpClient: (_) => _ImageClient(requests));
      } finally {
        debugNetworkImageHttpClientProvider = null;
      }
    });

    testWidgets('$surface Markdown never reads local image files',
        (tester) async {
      final reads = <String>[];
      await IOOverrides.runZoned(() async {
        await _render(
            tester,
            surface,
            'Visible answer\n\n![local](file:///private/secret.png)\n\n'
            '![relative](/private/relative.png)');
        expect(reads, isEmpty);
        expect(find.byType(Image), findsNothing);
        expect(find.textContaining('Image blocked'), findsNWidgets(2));
      }, createFile: (path) => _ImageFile(path, reads));
    });
  }
}
