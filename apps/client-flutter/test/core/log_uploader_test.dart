import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/core/logging/log_uploader.dart';

void main() {
  test(
    'disabled by default; bounded queue; retries then clears; no upload feedback',
    () async {
      var fail = true;
      var sent = 0;
      final uploader = LogUploader((events) async {
        if (fail) throw Exception('offline');
        sent += events.length;
      });
      addTearDown(uploader.dispose);
      uploader.add({'event': 'ignored'});
      expect(uploader.pendingCount, 0);
      uploader.setEnabled(true);
      for (var i = 0; i < 1000; i++) {
        uploader.add({'event': 'test', 'sequence': i});
      }
      expect(uploader.pendingCount, 256);
      await uploader.flush();
      expect(uploader.pendingCount, 256);
      fail = false;
      await uploader.flush();
      expect(sent, 32);
      expect(uploader.pendingCount, 224);
      uploader.add({
        'event': 'core.http.error',
        'data': {'path': '/api/v1/diagnostics/clients/a/logs'},
      });
      expect(uploader.pendingCount, 224);
      uploader.setEnabled(false);
      await uploader.flush();
      expect(uploader.pendingCount, 0);
      expect(sent, 32);
    },
  );
  test(
    'completion of an old upload cannot clear a newly enabled queue',
    () async {
      final response = Completer<void>();
      final uploader = LogUploader((_) => response.future);
      addTearDown(uploader.dispose);
      uploader.setEnabled(true);
      uploader.add({'event': 'old'});
      final sending = uploader.flush();
      uploader.setEnabled(false);
      uploader.setEnabled(true);
      uploader.add({'event': 'new'});
      response.complete();
      await sending;
      expect(uploader.pendingCount, 1);
    },
  );
}
