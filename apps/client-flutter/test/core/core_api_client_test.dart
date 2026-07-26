import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/intmusic_client.dart';

void main() {
  tearDown(CoreApiClient.closeAll);

  test('normalizes and reuses clients for the same Core endpoint', () {
    final first = CoreApiClient(' http://127.0.0.1:49330/ ');
    final second = CoreApiClient('http://127.0.0.1:49330');

    expect(first, same(second));
    expect(first.baseUrl, 'http://127.0.0.1:49330');
  });

  test('retaining an endpoint closes stale pooled clients', () async {
    final retained = CoreApiClient('http://core-a:49330');
    final stale = CoreApiClient('http://core-b:49330');

    CoreApiClient.retainOnly(retained.baseUrl);

    expect(CoreApiClient(retained.baseUrl), same(retained));
    await expectLater(stale.getJson('/status'), throwsA(isA<StateError>()));
  });

  test('retries idempotent reads but never replays a mutation', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var getRequests = 0;
    var postRequests = 0;
    final subscription = server.listen((request) async {
      if (request.method == 'GET') {
        getRequests += 1;
        request.response.statusCode = getRequests == 1 ? 503 : 200;
        request.response.write(jsonEncode(<String, Object?>{'ready': true}));
      } else {
        postRequests += 1;
        request.response.statusCode = 503;
        request.response.write('try later');
      }
      await request.response.close();
    });
    addTearDown(() async {
      await subscription.cancel();
      await server.close(force: true);
    });
    final client = CoreApiClient('http://127.0.0.1:${server.port}');

    final response = await client.getJson('/status');
    expect(response, <String, Object?>{'ready': true});
    expect(getRequests, 2);

    await expectLater(
      client.postJson('/mutate', <String, Object?>{'value': 1}),
      throwsA(isA<HttpException>()),
    );
    expect(postRequests, 1);
  });
}
