import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/agent_activity/activity_transport.dart';

void main() {
  test('actual message.delta reaches transcript seam without private fields',
      () async {
    final transport = ActivityTransport(
        origin: Uri.parse('https://fixture.test'),
        bearerKey: 'fixture',
        isCurrent: () => true,
        eventsSupported: true,
        client: MockClient((_) async => http.Response(
            'id: 1\ndata: {"event":"message.delta","run_id":"run_actual","delta":"visible reply","reasoning":"PRIVATE"}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'})));
    final events = <ActivityTransportEvent>[];
    await transport
        .connect('run_actual')
        .forEach(events.add)
        .catchError((Object _) {});
    expect(events.single.data['delta'], 'visible reply');
    expect(events.single.data.containsKey('reasoning'), isFalse);
    await transport.close();
  });
}
