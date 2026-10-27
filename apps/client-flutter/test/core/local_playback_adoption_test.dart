import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/core/local_playback_adoption.dart';
import 'package:intmusic_client/core/network/core_api_client.dart';

void main() {
  test(
    'reconnect transfers all queue occurrences, cursor, progress and mode',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final api = CoreApiClient('http://127.0.0.1:${server.port}');
      var snapshot = <String, dynamic>{
        'session_id': 'session',
        'epoch': 1,
        'revision': 1,
        'queue': [],
        'current_item_id': null,
        'command_sequence': 1,
      };
      final actions = <Map<String, dynamic>>[];
      final subscription = server.listen((request) async {
        if (request.method == 'GET') {
          request.response.write(jsonEncode(snapshot));
        } else {
          final command =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          expect(command['expected_revision'], snapshot['revision']);
          expect(command['origin_device_id'], 'device');
          final action = Map<String, dynamic>.from(command['action'] as Map);
          actions.add(action);
          snapshot = {
            ...snapshot,
            'revision': (snapshot['revision'] as int) + 1,
          };
          if (action['type'] == 'replace_queue_and_play') {
            for (final item in action['items'] as List) {
              expect(item['added_by_device_id'], 'device');
              expect(DateTime.tryParse(item['added_at']), isNotNull);
            }
            snapshot = {
              ...snapshot,
              'queue': action['items'],
              'current_item_id': action['start_item_id'],
              'position_ms': action['position_ms'],
            };
          } else if (action['type'] == 'set_mode') {
            snapshot = {...snapshot, 'mode': action['mode']};
          }
          request.response.write(
            jsonEncode({
              'command_id': command['command_id'],
              'status': 'applied',
              'snapshot': snapshot,
            }),
          );
        }
        await request.response.close();
      });
      addTearDown(() async {
        api.close();
        await subscription.cancel();
        await server.close(force: true);
      });
      var commands = 0;
      final result = await adoptLocalPlayback(
        api: api,
        outputId: 'renderer:device:default',
        deviceId: 'device',
        queue: {
          'mode': 'repeat_all',
          'current_index': 1,
          'items': [
            {
              'id': 'a',
              'track': {'id': 1},
            },
            {
              'id': 'b',
              'track': {'id': 2},
            },
            {
              'id': 'c',
              'track': {'id': 1},
            },
          ],
        },
        positionMs: 123000,
        paused: false,
        newCommandId: () => 'command-${++commands}',
      );
      expect(result!.agent.items.map((i) => i.itemId), ['a', 'b', 'c']);
      expect(result.agent.items.map((i) => i.trackId), [1, 2, 1]);
      expect(result.agent.currentIndex, 1);
      expect(result.agent.repeatMode, 'all');
      expect(actions.first['position_ms'], 123000);
      expect(actions.first['start_item_id'], 'b');
    },
  );

  test(
    'unbound local files retain independent playback until Core assigns IDs',
    () async {
      final api = CoreApiClient('http://127.0.0.1:1');
      addTearDown(api.close);
      final result = await adoptLocalPlayback(
        api: api,
        outputId: 'renderer:device:default',
        deviceId: 'device',
        queue: {
          'current_index': 0,
          'items': [
            {
              'id': 'a',
              'track': {'id': -100},
            },
          ],
        },
        positionMs: 1000,
        paused: false,
        newCommandId: () => 'unused',
      );
      expect(result, isNull);
    },
  );
}
