import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/core/logging/client_log.dart';
import 'package:intmusic_client/core/logging/error_history.dart';

void main() {
  Map<String, Object?> error(int index) => {
    'timestamp': DateTime.utc(2026, 10, 24, 0, 0, index).toIso8601String(),
    'event': 'test.failure',
    'level': 'error',
    'message': 'Failure $index',
  };

  test(
    'error history survives restart, coalesces repeats and stays bounded',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'intmusic-errors-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final history = ErrorHistory();
      await history.initialize(directory);
      for (var i = 0; i < 230; i++) {
        history.record(error(i));
      }
      history.record(error(229));
      await history.flush();
      expect(history.entries.value.length, 200);
      expect(history.entries.value.first['count'], 2);
      final restored = ErrorHistory();
      await restored.initialize(directory);
      expect(restored.entries.value.first['message'], 'Failure 229');
      expect(restored.entries.value.last['message'], 'Failure 30');
    },
  );

  test(
    'imports existing diagnostic errors on first journal creation',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'intmusic-import-errors-',
      );
      addTearDown(() => directory.delete(recursive: true));
      await File('${directory.path}/client-playback.jsonl').writeAsString(
        [
          jsonEncode({'level': 'info', 'event': 'startup'}),
          jsonEncode(error(1)),
        ].join('\n'),
      );
      final history = ErrorHistory();
      await history.initialize(directory);
      expect(history.entries.value.single['message'], 'Failure 1');
    },
  );

  test(
    'disabling verbose diagnostics still records sanitized errors',
    () async {
      ClientLog.setEnabled(false);
      ClientLog.error(
        'test.private_error',
        'an error',
        data: {'password': 'secret'},
      );
      await Future<void>.delayed(Duration.zero);
      final event = ClientLog.errors.entries.value.first;
      expect(event['event'], 'test.private_error');
      expect((event['data'] as Map)['password'], '<redacted>');
    },
  );
}
