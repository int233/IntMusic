import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/core/storage/client_cache_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test(
    'client cache database configuration uses query-capable PRAGMAs',
    () async {
      sqfliteFfiInit();
      final directory = await Directory.systemTemp.createTemp(
        'intmusic-client-cache-test-',
      );
      addTearDown(() => directory.delete(recursive: true));

      final database = await databaseFactoryFfi.openDatabase(
        '${directory.path}${Platform.pathSeparator}cache.sqlite3',
        options: OpenDatabaseOptions(onConfigure: configureClientCacheDatabase),
      );
      addTearDown(database.close);

      final journalMode = await database.rawQuery('PRAGMA journal_mode');
      final synchronous = await database.rawQuery('PRAGMA synchronous');
      final busyTimeout = await database.rawQuery('PRAGMA busy_timeout');

      expect(journalMode.single.values.single.toString().toLowerCase(), 'wal');
      expect(synchronous.single.values.single, 1);
      expect(busyTimeout.single.values.single, 5000);
    },
  );
}
