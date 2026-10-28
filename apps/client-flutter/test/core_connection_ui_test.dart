import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/intmusic_client.dart';
import 'package:intmusic_client/core/logging/client_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  testWidgets(
    'Core version and Connect button do not wait for library download',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final events = <Map<String, Object?>>[];
      ClientLog.remoteSink = events.add;
      addTearDown(() => ClientLog.remoteSink = null);
      const channel = MethodChannel('dev.intmusic/platform');
      // Keep automatic platform boot pending; exercise the real manual connection.
      final boot = Completer<Object?>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) =>
            call.method == 'initialize' ? boot.future : Future.value(null),
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final started = Completer<void>();
      var snapshotRequests = 0;
      final release = Completer<void>();
      final sockets = <WebSocket>[];
      late HttpServer server;
      await tester.runAsync(() async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          if (WebSocketTransformer.isUpgradeRequest(request)) {
            sockets.add(await WebSocketTransformer.upgrade(request));
            return;
          }
          Object? response;
          switch (request.uri.path) {
            case '/api/v1/status':
              response = {
                'name': 'IntMusic Local Music Core',
                'api_version': 'v1',
                'server_id': 'core',
                'catalog_epoch': 'epoch',
                'version': '1.6.0',
              };
            case '/api/v1/zones':
              response = [];
            case '/api/v1/client-sync/snapshot':
              snapshotRequests++;
              if (!started.isCompleted) started.complete();
              await release.future;
              request.response.statusCode = 503;
            default:
              response = <String, dynamic>{};
          }
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(response));
          try {
            await request.response.close();
          } on IOException {
            /* client disposed */
          }
        });
      });
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const IntMusicClientApp(enableAudioRenderer: false),
      );
      final dashboard = tester.state(find.byType(CoreDashboard));
      Map<String, dynamic>? connection;
      try {
        await tester.runAsync(
          () => HttpOverrides.runWithHttpOverrides(() async {
            connection = await refreshCoreConnectionForTesting(
              dashboard,
              'http://127.0.0.1:${server.port}',
            ).timeout(const Duration(seconds: 3));
          }, _RealHttp()),
        );
        expect(connection!['status']['version'], '1.6.0');
        expect(connection!['loading'], isFalse);
        expect(connection!['online'], isTrue);
        expect(connection!['sync_pending'], isTrue);
        expect(connection!['local_playback'], isTrue);
        await tester.pump();
        for (var i = 0; i < 50 && !started.isCompleted; i++) {
          await tester.pump(const Duration(milliseconds: 20));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
        }
        expect(started.isCompleted, isTrue, reason: events.toString());
        await tester.tap(find.byIcon(Icons.tune_outlined).first);
        await tester.pump();
        expect(find.text('1.6.0'), findsOneWidget);
        final button = find.widgetWithText(FilledButton, 'Connect');
        expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
        expect(
          find.descendant(
            of: button,
            matching: find.byType(CircularProgressIndicator),
          ),
          findsNothing,
        );
        await tester.tap(button);
        await tester.pump();
        expect(snapshotRequests, 1);
        expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        release.complete();
        await tester.runAsync(() async {
          for (final socket in sockets) {
            await socket.close();
          }
          await server.close(force: true);
        });
      }
    },
  );
}
