import 'dart:async';
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

  test('health probes are uncached and do not retry', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    final subscription = server.listen((request) async {
      requests += 1;
      request.response.write(jsonEncode(<String, Object?>{'ready': true}));
      await request.response.close();
    });
    addTearDown(() async {
      await subscription.cancel();
      await server.close(force: true);
    });

    final before = CoreApiClient.debugPooledClientCount;
    final response = await CoreApiClient.probeJson(
      'http://127.0.0.1:${server.port}',
      '/status',
    );

    expect(response, <String, Object?>{'ready': true});
    expect(requests, 1);
    expect(CoreApiClient.debugPooledClientCount, before);
  });

  test(
    'retries a control command only when it has a stable command identity',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var idempotentRequests = 0;
      var v3Requests = 0;
      var unsafeRequests = 0;
      final subscription = server.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        if (body['intent_id'] == 'intent-1') {
          idempotentRequests += 1;
          request.response.statusCode = idempotentRequests == 1 ? 503 : 200;
          request.response.write(
            idempotentRequests == 1
                ? 'try later'
                : jsonEncode(<String, Object?>{'state': 'playing'}),
          );
        } else if (body['command_id'] == 'command-1') {
          v3Requests += 1;
          request.response.statusCode = v3Requests == 1 ? 503 : 200;
          request.response.write(
            v3Requests == 1
                ? 'try later'
                : jsonEncode(<String, Object?>{'status': 'duplicate'}),
          );
        } else {
          unsafeRequests += 1;
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

      expect(
        await client.postControlJson('/control', <String, Object?>{
          'intent_id': 'intent-1',
        }),
        <String, Object?>{'state': 'playing'},
      );
      expect(idempotentRequests, 2);

      expect(
        await client.postControlJson('/control', <String, Object?>{
          'command_id': 'command-1',
        }),
        <String, Object?>{'status': 'duplicate'},
      );
      expect(v3Requests, 2);

      await expectLater(
        client.postControlJson('/control', const <String, Object?>{}),
        throwsA(isA<HttpException>()),
      );
      expect(unsafeRequests, 1);
    },
  );

  test(
    'a timed-out bulk request cannot starve critical Core traffic',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final releaseSlowRequests = Completer<void>();
      final subscription = server.listen((request) async {
        if (request.uri.path.endsWith('/slow')) {
          await releaseSlowRequests.future;
        }
        request.response.write(jsonEncode(<String, Object?>{'ready': true}));
        await request.response.close();
      });
      addTearDown(() async {
        if (!releaseSlowRequests.isCompleted) {
          releaseSlowRequests.complete();
        }
        await subscription.cancel();
        await server.close(force: true);
      });
      final client = CoreApiClient('http://127.0.0.1:${server.port}');

      await expectLater(
        client.getBulkJson(
          '/slow',
          requestTimeout: const Duration(milliseconds: 60),
        ),
        throwsA(isA<TimeoutException>()),
      );

      expect(await client.getCriticalJson('/fast'), <String, Object?>{
        'ready': true,
      });
      expect(await client.getBulkJson('/fast'), <String, Object?>{
        'ready': true,
      });
    },
  );

  test('a timed-out request does not cancel a background peer', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final releaseSlowRequest = Completer<void>();
    final fastRequestStarted = Completer<void>();
    final subscription = server.listen((request) async {
      if (request.uri.path.endsWith('/slow')) {
        await releaseSlowRequest.future;
      } else {
        if (!fastRequestStarted.isCompleted) fastRequestStarted.complete();
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      request.response.write(jsonEncode(<String, Object?>{'ready': true}));
      await request.response.close();
    });
    addTearDown(() async {
      if (!releaseSlowRequest.isCompleted) releaseSlowRequest.complete();
      await subscription.cancel();
      await server.close(force: true);
    });
    final client = CoreApiClient('http://127.0.0.1:${server.port}');

    final slow = client.postJson(
      '/slow',
      const <String, Object?>{},
      requestTimeout: const Duration(milliseconds: 60),
    );
    final fast = client.postJson(
      '/fast',
      const <String, Object?>{},
      requestTimeout: const Duration(milliseconds: 500),
    );
    await fastRequestStarted.future;

    await expectLater(slow, throwsA(isA<TimeoutException>()));
    expect(await fast, <String, Object?>{'ready': true});
    releaseSlowRequest.complete();
  });

  test('library sync traffic uses an isolated connection pool', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final releaseManifest = Completer<void>();
    final subscription = server.listen((request) async {
      if (request.uri.path.endsWith('/client-library/manifests')) {
        await releaseManifest.future;
      }
      request.response.write(jsonEncode(<String, Object?>{'ready': true}));
      await request.response.close();
    });
    addTearDown(() async {
      if (!releaseManifest.isCompleted) releaseManifest.complete();
      await subscription.cancel();
      await server.close(force: true);
    });
    final client = CoreApiClient('http://127.0.0.1:${server.port}');

    final manifest = client.postLibrarySyncJson(
      '/client-library/manifests',
      const <String, Object?>{},
      requestTimeout: const Duration(milliseconds: 60),
    );

    expect(await client.getJson('/status'), <String, Object?>{'ready': true});
    await expectLater(manifest, throwsA(isA<TimeoutException>()));
    releaseManifest.complete();
  });

  test(
    'library sync retries transient failures but not invalid data',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var transientRequests = 0;
      var invalidRequests = 0;
      final subscription = server.listen((request) async {
        if (request.uri.path.endsWith('/transient')) {
          transientRequests += 1;
          request.response.statusCode = transientRequests < 3 ? 503 : 200;
          request.response.write(
            transientRequests < 3
                ? 'try later'
                : jsonEncode(<String, Object?>{'accepted_files': 1}),
          );
        } else {
          invalidRequests += 1;
          request.response.statusCode = 422;
          request.response.write('invalid manifest');
        }
        await request.response.close();
      });
      addTearDown(() async {
        await subscription.cancel();
        await server.close(force: true);
      });
      final client = CoreApiClient('http://127.0.0.1:${server.port}');

      expect(
        await client.postLibrarySyncJson('/transient', const <String, Object?>{
          'batch_id': 'scan:0',
        }),
        <String, Object?>{'accepted_files': 1},
      );
      expect(transientRequests, 3);

      await expectLater(
        client.postLibrarySyncJson('/invalid', const <String, Object?>{
          'batch_id': 'scan:1',
        }),
        throwsA(isA<HttpException>()),
      );
      expect(invalidRequests, 1);
    },
  );
}
