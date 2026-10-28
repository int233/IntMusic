import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/core/library_repository.dart';
import 'package:intmusic_client/core/storage/client_cache_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Desktop SQLite does not have Android's CursorWindow. Enforce its row limit
// on real SQL query results so the regression is reproducible on CI hosts.
class _CursorWindow extends Fake implements DatabaseExecutor {
  _CursorWindow(this.database);
  @override
  final Database database;
  List<Map<String, Object?>> _check(List<Map<String, Object?>> rows) {
    for (final row in rows) {
      if (utf8.encode(jsonEncode(row)).length > 2 * 1024 * 1024) {
        throw StateError('Row too big to fit into CursorWindow');
      }
    }
    return rows;
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async => _check(
    await database.query(
      table,
      columns: columns,
      where: where,
      whereArgs: whereArgs,
      orderBy: orderBy,
      limit: limit,
    ),
  );

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async => _check(await database.rawQuery(sql, arguments));
}

void main() {
  late Directory directory;
  late ClientLibraryDatabase database;
  // Supplementary characters cross SQL substring boundaries; offsets must use
  // SQLite character counts rather than Dart UTF-16 lengths or UTF-8 bytes.
  final large = List.filled(400000, '国语🎵').join();
  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('intmusic-json-window-');
    database = ClientLibraryDatabase(
      path: File.fromUri(directory.uri.resolve('cache.sqlite3')).path,
      factory: databaseFactoryFfi,
    );
  });
  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  test(
    'JSON over the Android row limit is read intact in bounded chunks',
    () async {
      final sql = await database.open();
      await database.writeDocument('collections', 'large', {'text': large});
      await database.writeDocument('collections', 'small', {'text': '小'});
      final window = _CursorWindow(sql);
      await expectLater(window.query('local_documents'), throwsStateError);
      final rows = await readLibraryJsonRows(
        window,
        'local_documents',
        columns: ['document_key'],
        orderBy: 'document_key',
      );
      expect(rows.map((r) => r['document_key']), ['large', 'small']);
      expect(jsonDecode(rows.first['payload'] as String), {'text': large});
      expect(jsonDecode(rows.last['payload'] as String), {'text': '小'});
    },
  );

  test(
    'large home and collection documents survive a database cold start',
    () async {
      await database.writeDocument('collections', 'catalog:core:epoch', {
        'text': large,
      });
      await database.close();
      expect(await database.readDocument('collections', 'catalog:core:epoch'), {
        'text': large,
      });
      expect(await database.readDocuments('collections'), [
        {'text': large},
      ]);
      expect(await database.readDocument('collections', 'missing'), isNull);
    },
  );

  test('oversized cached detail cannot hide the saved song catalog', () async {
    final repository = ClientLibraryRepository(database);
    await repository.replaceSnapshot('http://core', {
      'server_id': 'core',
      'catalog_epoch': 'epoch',
      'cursor': 42,
      'tracks': [
        {'id': 1, 'title': '本地歌曲'},
      ],
    });
    await repository.putDetail('http://core', 'core', 'track', 1, {
      'lyrics': large,
    });
    await repository.putOverviewValues('http://core', 'core', {
      'large_overview': large,
    });
    await database.close();
    final cold = await ClientLibraryRepository(database).load('http://core');
    expect(cold.cursor, 42);
    expect((cold.values['tracks'] as List).single['title'], '本地歌曲');
    expect(cold.trackDetails[1]!['lyrics'], large);
    expect(cold.values['large_overview'], large);
  });
}
