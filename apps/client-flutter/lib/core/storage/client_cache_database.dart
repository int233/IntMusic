import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as mobile;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../logging/client_log.dart';

Future<void> configureClientCacheDatabase(Database database) async {
  await database.rawQuery('PRAGMA journal_mode = WAL');
  await database.rawQuery('PRAGMA synchronous = NORMAL');
  await database.rawQuery('PRAGMA busy_timeout = 5000');
}

/// The durable client library. Core URLs are endpoints, never catalog identity.
/// Catalogs, collections, home layout and device file bindings share this DB.
class ClientLibraryDatabase {
  ClientLibraryDatabase({this.path, this.factory});
  static final shared = ClientLibraryDatabase();
  final String? path;
  final DatabaseFactory? factory;
  Future<Database>? _opening;
  final Map<String, String> _endpoints = {};

  String keyForEndpoint(String endpoint) {
    final url = endpoint.trim().replaceAll(RegExp(r'/+$'), '');
    return _endpoints[url] ?? url;
  }

  Future<Database> open() => _opening ??= _open();
  Future<Database> _open() async {
    try {
      final dbFactory =
          factory ??
          (Platform.isAndroid || Platform.isIOS
              ? mobile.databaseFactory
              : _desktopFactory());
      final location =
          path ??
          '${(await getApplicationSupportDirectory()).path}/cache/client-cache-v2.sqlite3';
      await Directory(File(location).parent.path).create(recursive: true);
      return await dbFactory.openDatabase(
        location,
        options: OpenDatabaseOptions(
          version: 2,
          onConfigure: configureClientCacheDatabase,
          onCreate: (database, _) async {
            await database.execute('''
            CREATE TABLE cache_entries (
              core_url TEXT NOT NULL,
              server_id TEXT NOT NULL,
              kind TEXT NOT NULL,
              entity_key TEXT NOT NULL,
              payload TEXT NOT NULL,
              updated_at INTEGER NOT NULL,
              PRIMARY KEY (core_url, kind, entity_key)
            )
          ''');
            await database.execute('''
            CREATE TABLE sync_state (
              core_url TEXT PRIMARY KEY,
              server_id TEXT NOT NULL,
              catalog_epoch TEXT,
              cursor INTEGER NOT NULL DEFAULT 0,
              event_cursor INTEGER NOT NULL DEFAULT 0,
              last_sync_at INTEGER,
              last_error TEXT
            )
          ''');
            await database.execute('''
            CREATE TABLE search_index (
              core_url TEXT NOT NULL,
              kind TEXT NOT NULL,
              entity_id INTEGER NOT NULL,
              title TEXT NOT NULL,
              subtitle TEXT NOT NULL,
              terms TEXT NOT NULL,
              payload TEXT NOT NULL,
              PRIMARY KEY (core_url, kind, entity_id)
            )
          ''');
            await database.execute('''
            CREATE INDEX idx_search_index_core_kind
            ON search_index(core_url, kind)
          ''');

            await _createCatalogEntitiesTable(database);
            await _createDetailWarmStateTable(database);
            await _createLocalTables(database);
          },
          onUpgrade: (database, oldVersion, newVersion) async {
            await _createLocalTables(database);
            // Move existing collection caches once, before switching readers.
            // A damaged optional cache must not prevent opening the library.
            for (final row in await database.query(
              'sync_state',
              orderBy: 'last_sync_at ASC',
            )) {
              if (row['server_id'] == null || row['catalog_epoch'] == null) {
                continue;
              }
              final identity =
                  '${row['core_url']}|${row['server_id']}|${row['catalog_epoch']}';
              final file = File(
                '${File(location).parent.parent.path}/collections/${sha256.convert(utf8.encode(identity))}.json',
              );
              if (!await file.exists()) continue;
              try {
                final payload = await file.readAsString();
                if (jsonDecode(payload) is! Map) continue;
                await database.insert('local_documents', {
                  'namespace': 'collections',
                  'document_key':
                      'catalog:${row['server_id']}:${row['catalog_epoch']}',
                  'payload': payload,
                }, conflictAlgorithm: ConflictAlgorithm.replace);
              } catch (error, stack) {
                ClientLog.error(
                  'library.collections.import_failed',
                  error,
                  stackTrace: stack,
                );
              }
            }
          },
        ),
      );
    } catch (_) {
      _opening = null;
      rethrow;
    }
  }

  DatabaseFactory _desktopFactory() {
    sqfliteFfiInit();
    return databaseFactoryFfi;
  }

  Future<void> _createLocalTables(DatabaseExecutor db) async {
    await db.execute(
      'CREATE TABLE IF NOT EXISTS core_endpoints (url TEXT PRIMARY KEY, library_key TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS local_documents (namespace TEXT NOT NULL, document_key TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(namespace, document_key))',
    );
  }

  Future<void> _createDetailWarmStateTable(DatabaseExecutor database) =>
      database.execute('''
    CREATE TABLE IF NOT EXISTS detail_warm_state (
      core_url TEXT NOT NULL,
      server_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      target_cursor INTEGER NOT NULL,
      after_id INTEGER NOT NULL DEFAULT 0,
      complete INTEGER NOT NULL DEFAULT 0,
      updated_at INTEGER NOT NULL,
      PRIMARY KEY (core_url, kind)
    )
  ''');

  Future<void> _createCatalogEntitiesTable(DatabaseExecutor database) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS catalog_entities (
        core_url TEXT NOT NULL,
        server_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        entity_id INTEGER NOT NULL,
        payload TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (core_url, kind, entity_id)
      )
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS idx_catalog_entities_core_kind
      ON catalog_entities(core_url, kind)
    ''');
  }

  void rememberEndpoint(String endpoint, String key) {
    _endpoints[endpoint.trim().replaceAll(RegExp(r'/+$'), '')] = key;
  }

  Future<String> resolveEndpoint(String endpoint) async {
    final url = endpoint.trim().replaceAll(RegExp(r'/+$'), '');
    if (_endpoints.containsKey(url)) return _endpoints[url]!;
    final db = await open();
    final rows = await db.query(
      'core_endpoints',
      where: 'url = ?',
      whereArgs: [url],
    );
    if (rows.isNotEmpty) {
      return _endpoints[url] = rows.first['library_key'] as String;
    }
    final previous = await db.query(
      'sync_state',
      where: 'core_url = ?',
      whereArgs: [url],
    );
    if (previous.isNotEmpty && previous.first['catalog_epoch'] != null) {
      return bindCatalog(
        url,
        previous.first['server_id'] as String,
        previous.first['catalog_epoch'] as String,
      );
    }
    // An edited/discovered endpoint is not a new library. Keep displaying the
    // last committed catalog until a different Core is confirmed and saved.
    final latest = await db.query(
      'sync_state',
      columns: ['core_url'],
      orderBy: 'last_sync_at DESC',
      limit: 1,
    );
    if (latest.isNotEmpty) {
      return _endpoints[url] = latest.single['core_url'] as String;
    }
    return url;
  }

  Future<String> bindCatalog(
    String endpoint,
    String server,
    String epoch,
  ) async {
    if (server.isEmpty || epoch.isEmpty) {
      throw ArgumentError('Missing catalog identity');
    }
    final url = endpoint.trim().replaceAll(RegExp(r'/+$'), '');
    final key = 'catalog:$server:$epoch';
    final db = await open();
    await db.transaction((tx) async {
      final current = await tx.query(
        'sync_state',
        where: 'core_url = ?',
        whereArgs: [key],
      );
      if (current.isEmpty) {
        final prior = await tx.query(
          'sync_state',
          where: 'server_id = ? AND catalog_epoch = ?',
          whereArgs: [server, epoch],
          limit: 1,
        );
        if (prior.isNotEmpty) {
          final oldKey = prior.first['core_url'];
          for (final table in [
            'cache_entries',
            'sync_state',
            'search_index',
            'catalog_entities',
            'detail_warm_state',
          ]) {
            await tx.update(
              table,
              {'core_url': key},
              where: 'core_url = ?',
              whereArgs: [oldKey],
            );
          }
        }
      }
      await tx.insert('core_endpoints', {
        'url': url,
        'library_key': key,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    _endpoints[url] = key;
    return key;
  }

  Future<Map<String, dynamic>?> readDocument(
    String namespace,
    String key,
  ) async {
    final db = await open();
    final rows = await db.query(
      'local_documents',
      columns: ['payload'],
      where: 'namespace = ? AND document_key = ?',
      whereArgs: [namespace, key],
    );
    if (rows.isEmpty) return null;
    return compute(_decodeLibraryDocument, rows.single['payload'] as String);
  }

  Future<List<Map<String, dynamic>>> readDocuments(String namespace) async {
    final db = await open();
    final rows = await db.query(
      'local_documents',
      columns: ['payload'],
      where: 'namespace = ?',
      whereArgs: [namespace],
    );
    return compute(
      _decodeLibraryDocuments,
      rows.map((r) => r['payload'] as String).toList(),
    );
  }

  Future<void> writeDocument(
    String namespace,
    String key,
    Map<String, dynamic> value,
  ) async {
    final payload = await encodeLocalLibraryDocument(value);
    await writeEncodedDocument(namespace, key, payload);
  }

  Future<void> writeEncodedDocument(
    String namespace,
    String key,
    String payload,
  ) async {
    final db = await open();
    await db.insert('local_documents', {
      'namespace': namespace,
      'document_key': key,
      'payload': payload,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> close() async {
    final pending = _opening;
    if (pending != null) await (await pending).close();
    _opening = null;
    _endpoints.clear();
  }
}

Future<String> encodeLocalLibraryDocument(Map<String, dynamic> data) =>
    compute(_encodeLocalLibraryDocument, data);
String _encodeLocalLibraryDocument(Map<String, dynamic> data) =>
    jsonEncode(data);

List<Map<String, dynamic>> _decodeLibraryDocuments(List<String> rows) =>
    rows.map((s) => Map<String, dynamic>.from(jsonDecode(s) as Map)).toList();

Map<String, dynamic> _decodeLibraryDocument(String value) =>
    Map<String, dynamic>.from(jsonDecode(value) as Map);
