part of '../intmusic_client.dart';

class _ClientCacheSnapshot {
  const _ClientCacheSnapshot({
    required this.serverId,
    required this.catalogEpoch,
    required this.cursor,
    required this.values,
    required this.trackDetails,
    required this.albumDetails,
    required this.artistDetails,
    required this.playlistDetails,
    required this.pendingDetailRefresh,
    required this.pendingDetailTargetCursors,
  });

  final String? serverId;
  final String? catalogEpoch;
  final int cursor;
  final Map<String, dynamic> values;
  final Map<int, Map<String, dynamic>> trackDetails;
  final Map<int, Map<String, dynamic>> albumDetails;
  final Map<int, Map<String, dynamic>> artistDetails;
  final Map<int, Map<String, dynamic>> playlistDetails;
  final Map<String, int> pendingDetailRefresh;
  final Map<String, int> pendingDetailTargetCursors;

  bool get isEmpty => values.isEmpty;
}

class _ClientCacheStore {
  static const _databaseVersion = 3;
  static Database? _database;
  static Future<void> _writeQueue = Future<void>.value();

  static DatabaseFactory _factory() {
    if (Platform.isAndroid || Platform.isIOS) {
      return mobile_sqlite.databaseFactory;
    }
    sqfliteFfiInit();
    return databaseFactoryFfi;
  }

  static Future<Database> _open() async {
    final current = _database;
    if (current != null && current.isOpen) return current;
    final support = await getApplicationSupportDirectory();
    final cacheDirectory = Directory(
      '${support.path}${Platform.pathSeparator}cache',
    );
    await cacheDirectory.create(recursive: true);
    final database = await _factory().openDatabase(
      '${cacheDirectory.path}${Platform.pathSeparator}client-cache-v1.sqlite3',
      options: OpenDatabaseOptions(
        version: _databaseVersion,
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
          await _createDetailWarmStateTable(database);
        },
        onUpgrade: (database, oldVersion, _) async {
          if (oldVersion < 2) {
            await _createDetailWarmStateTable(database);
          }
          if (oldVersion < 3) {
            await database.execute(
              'ALTER TABLE sync_state ADD COLUMN catalog_epoch TEXT',
            );
            // v1/v2 rows contain logical IDs from the retired catalog model.
            // Local folder preferences and SAF grants live in SharedPreferences
            // and are intentionally preserved outside this database.
            await database.delete('cache_entries');
            await database.delete('search_index');
            await database.delete('detail_warm_state');
            await database.delete('sync_state');
          }
        },
      ),
    );
    _database = database;
    return database;
  }

  static String _normalizedCoreUrl(String value) =>
      value.trim().replaceAll(RegExp(r'/+$'), '');

  static Future<void> _createDetailWarmStateTable(DatabaseExecutor database) =>
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

  static Future<_ClientCacheSnapshot> load(String coreUrl) async {
    try {
      final normalized = _normalizedCoreUrl(coreUrl);
      final database = await _open();
      final stateRows = await database.query(
        'sync_state',
        where: 'core_url = ?',
        whereArgs: <Object?>[normalized],
        limit: 1,
      );
      final serverId = stateRows.firstOrNull?['server_id']?.toString();
      final catalogEpoch = stateRows.firstOrNull?['catalog_epoch']?.toString();
      final cursor = _intValue(stateRows.firstOrNull?['cursor']) ?? 0;
      final rows = await database.query(
        'cache_entries',
        columns: <String>['kind', 'entity_key', 'payload'],
        where: 'core_url = ?',
        whereArgs: <Object?>[normalized],
      );
      final decoded = await Isolate.run(() => _decodeRows(rows));
      final values = decoded.values;
      final trackDetails = decoded.trackDetails;
      final albumDetails = decoded.albumDetails;
      final artistDetails = decoded.artistDetails;
      final playlistDetails = decoded.playlistDetails;
      final pendingDetailRefresh = <String, int>{};
      final pendingDetailTargetCursors = <String, int>{};
      final warmRows = await database.query(
        'detail_warm_state',
        columns: <String>['kind', 'after_id', 'target_cursor'],
        where: 'core_url = ? AND complete = 0',
        whereArgs: <Object?>[normalized],
      );
      for (final row in warmRows) {
        final kind = row['kind']?.toString() ?? '';
        if (kind.isNotEmpty) {
          pendingDetailRefresh[kind] = _intValue(row['after_id']) ?? 0;
          pendingDetailTargetCursors[kind] =
              _intValue(row['target_cursor']) ?? cursor;
        }
      }
      return _ClientCacheSnapshot(
        serverId: serverId,
        catalogEpoch: catalogEpoch,
        cursor: cursor,
        values: values,
        trackDetails: trackDetails,
        albumDetails: albumDetails,
        artistDetails: artistDetails,
        playlistDetails: playlistDetails,
        pendingDetailRefresh: pendingDetailRefresh,
        pendingDetailTargetCursors: pendingDetailTargetCursors,
      );
    } catch (_) {
      return const _ClientCacheSnapshot(
        serverId: null,
        catalogEpoch: null,
        cursor: 0,
        values: <String, dynamic>{},
        trackDetails: <int, Map<String, dynamic>>{},
        albumDetails: <int, Map<String, dynamic>>{},
        artistDetails: <int, Map<String, dynamic>>{},
        playlistDetails: <int, Map<String, dynamic>>{},
        pendingDetailRefresh: <String, int>{},
        pendingDetailTargetCursors: <String, int>{},
      );
    }
  }

  static _DecodedCacheRows _decodeRows(List<Map<String, Object?>> rows) {
    final values = <String, dynamic>{};
    final trackDetails = <int, Map<String, dynamic>>{};
    final albumDetails = <int, Map<String, dynamic>>{};
    final artistDetails = <int, Map<String, dynamic>>{};
    final playlistDetails = <int, Map<String, dynamic>>{};
    for (final row in rows) {
      final kind = row['kind']?.toString() ?? '';
      final key = row['entity_key']?.toString() ?? '';
      final payload = _decodeCachePayload(row['payload']);
      if (payload == null) continue;
      final id = int.tryParse(key);
      switch (kind) {
        case 'overview':
          values[key] = payload;
        case 'track_detail':
          if (id != null && payload is Map) {
            trackDetails[id] = payload.cast<String, dynamic>();
          }
        case 'album_detail':
          if (id != null && payload is Map) {
            albumDetails[id] = payload.cast<String, dynamic>();
          }
        case 'artist_detail':
          if (id != null && payload is Map) {
            artistDetails[id] = payload.cast<String, dynamic>();
          }
        case 'playlist_detail':
          if (id != null && payload is Map) {
            playlistDetails[id] = payload.cast<String, dynamic>();
          }
      }
    }
    return _DecodedCacheRows(
      values: values,
      trackDetails: trackDetails,
      albumDetails: albumDetails,
      artistDetails: artistDetails,
      playlistDetails: playlistDetails,
    );
  }

  static Future<void> replaceSnapshot(
    String coreUrl,
    Map<String, dynamic> snapshot,
  ) {
    final normalized = _normalizedCoreUrl(coreUrl);
    final serverId = snapshot['server_id']?.toString() ?? '';
    final catalogEpoch = snapshot['catalog_epoch']?.toString() ?? '';
    final cursor = _intValue(snapshot['cursor']) ?? 0;
    final values = <String, dynamic>{
      'albums': (snapshot['albums'] as List?) ?? const <dynamic>[],
      'artists': (snapshot['artists'] as List?) ?? const <dynamic>[],
      'tracks': (snapshot['tracks'] as List?) ?? const <dynamic>[],
      'playlists': (snapshot['playlists'] as List?) ?? const <dynamic>[],
      'playback_history':
          (snapshot['playback_history'] as List?) ?? const <dynamic>[],
      'playback_stats': _asMap(snapshot['playback_stats']),
      'library_roots':
          (snapshot['library_roots'] as List?) ?? const <dynamic>[],
      'client_library_roots':
          (snapshot['client_library_roots'] as List?) ?? const <dynamic>[],
      'client_file_bindings':
          (snapshot['client_file_bindings'] as List?) ?? const <dynamic>[],
      'settings': _asMap(snapshot['settings']),
      'generated_at': snapshot['generated_at']?.toString(),
      if (snapshot['status'] is Map) 'status': _asMap(snapshot['status']),
      if (snapshot['diagnostics'] is Map)
        'diagnostics': _asMap(snapshot['diagnostics']),
    };
    _writeQueue = _writeQueue.catchError((_) {}).then((_) async {
      final database = await _open();
      await database.transaction((transaction) async {
        final previous = await transaction.query(
          'sync_state',
          columns: <String>['server_id', 'catalog_epoch'],
          where: 'core_url = ?',
          whereArgs: <Object?>[normalized],
          limit: 1,
        );
        if (previous.isNotEmpty &&
            (previous.first['server_id']?.toString() != serverId ||
                previous.first['catalog_epoch']?.toString() != catalogEpoch)) {
          await transaction.delete(
            'cache_entries',
            where: 'core_url = ?',
            whereArgs: <Object?>[normalized],
          );
          await transaction.delete(
            'search_index',
            where: 'core_url = ?',
            whereArgs: <Object?>[normalized],
          );
          await transaction.delete(
            'detail_warm_state',
            where: 'core_url = ?',
            whereArgs: <Object?>[normalized],
          );
        } else {
          final validIds = <String, Set<String>>{
            'track_detail': {
              for (final value in values['tracks'] as List<dynamic>)
                if (value is Map && _intValue(value['id']) != null)
                  _intValue(value['id'])!.toString(),
            },
            'album_detail': {
              for (final value in values['albums'] as List<dynamic>)
                if (value is Map && _intValue(value['id']) != null)
                  _intValue(value['id'])!.toString(),
            },
            'artist_detail': {
              for (final value in values['artists'] as List<dynamic>)
                if (value is Map && _intValue(value['id']) != null)
                  _intValue(value['id'])!.toString(),
            },
            'playlist_detail': {
              for (final value in values['playlists'] as List<dynamic>)
                if (value is Map && _intValue(value['id']) != null)
                  _intValue(value['id'])!.toString(),
            },
          };
          final existingDetails = await transaction.query(
            'cache_entries',
            columns: <String>['kind', 'entity_key'],
            where:
                "core_url = ? AND kind IN "
                "('track_detail','album_detail','artist_detail','playlist_detail')",
            whereArgs: <Object?>[normalized],
          );
          for (final detail in existingDetails) {
            final kind = detail['kind']?.toString() ?? '';
            final entityKey = detail['entity_key']?.toString() ?? '';
            if (validIds[kind]?.contains(entityKey) == false) {
              await transaction.delete(
                'cache_entries',
                where: 'core_url = ? AND kind = ? AND entity_key = ?',
                whereArgs: <Object?>[normalized, kind, entityKey],
              );
            }
          }
        }
        final now = DateTime.now().millisecondsSinceEpoch;
        final batch = transaction.batch();
        for (final entry in values.entries) {
          batch.insert('cache_entries', <String, Object?>{
            'core_url': normalized,
            'server_id': serverId,
            'kind': 'overview',
            'entity_key': entry.key,
            'payload': jsonEncode(entry.value),
            'updated_at': now,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        batch.insert('sync_state', <String, Object?>{
          'core_url': normalized,
          'server_id': serverId,
          'catalog_epoch': catalogEpoch,
          'cursor': cursor,
          'last_sync_at': now,
          'last_error': null,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        batch.delete(
          'search_index',
          where: 'core_url = ?',
          whereArgs: <Object?>[normalized],
        );
        for (final track in values['tracks'] as List<dynamic>) {
          _addSearchInsert(batch, normalized, 'track', track);
        }
        for (final album in values['albums'] as List<dynamic>) {
          _addSearchInsert(batch, normalized, 'album', album);
        }
        for (final artist in values['artists'] as List<dynamic>) {
          _addSearchInsert(batch, normalized, 'artist', artist);
        }
        for (final playlist in values['playlists'] as List<dynamic>) {
          _addSearchInsert(batch, normalized, 'playlist', playlist);
        }
        await batch.commit(noResult: true);
      });
    });
    return _writeQueue;
  }

  static Future<void> clear(String coreUrl) {
    final normalized = _normalizedCoreUrl(coreUrl);
    _writeQueue = _writeQueue.catchError((_) {}).then((_) async {
      final database = await _open();
      await database.transaction((transaction) async {
        for (final table in const <String>[
          'cache_entries',
          'search_index',
          'detail_warm_state',
          'sync_state',
        ]) {
          await transaction.delete(
            table,
            where: 'core_url = ?',
            whereArgs: <Object?>[normalized],
          );
        }
      });
    });
    return _writeQueue;
  }

  static void _addSearchInsert(
    Batch batch,
    String coreUrl,
    String kind,
    dynamic value,
  ) {
    if (value is! Map) return;
    final item = value.cast<String, dynamic>();
    final id = _intValue(item['id']);
    if (id == null) return;
    final title = (item['title'] ?? item['name'] ?? '').toString();
    final subtitle = switch (kind) {
      'track' => '${item['artist_display'] ?? ''} ${item['album_title'] ?? ''}',
      'album' => '${item['album_artist_display'] ?? ''} ${item['year'] ?? ''}',
      'artist' => '${item['sort_name'] ?? ''}',
      'playlist' => '${item['description'] ?? ''}',
      _ => '',
    };
    batch.insert('search_index', <String, Object?>{
      'core_url': coreUrl,
      'kind': kind,
      'entity_id': id,
      'title': title,
      'subtitle': subtitle,
      'terms': '$title $subtitle'.toLowerCase(),
      'payload': jsonEncode(item),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> putDetail(
    String coreUrl,
    String serverId,
    String kind,
    int id,
    Map<String, dynamic> detail,
  ) {
    return putDetails(coreUrl, serverId, kind, <int, Map<String, dynamic>>{
      id: detail,
    });
  }

  static Future<void> putDetails(
    String coreUrl,
    String serverId,
    String kind,
    Map<int, Map<String, dynamic>> details,
  ) {
    if (details.isEmpty) return Future<void>.value();
    final normalized = _normalizedCoreUrl(coreUrl);
    _writeQueue = _writeQueue.catchError((_) {}).then((_) async {
      final database = await _open();
      final batch = database.batch();
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final entry in details.entries) {
        batch.insert('cache_entries', <String, Object?>{
          'core_url': normalized,
          'server_id': serverId,
          'kind': '${kind}_detail',
          'entity_key': entry.key.toString(),
          'payload': jsonEncode(entry.value),
          'updated_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
    return _writeQueue;
  }

  static Future<void> putOverviewValues(
    String coreUrl,
    String serverId,
    Map<String, dynamic> values,
  ) {
    if (values.isEmpty) return Future<void>.value();
    final normalized = _normalizedCoreUrl(coreUrl);
    _writeQueue = _writeQueue.catchError((_) {}).then((_) async {
      final database = await _open();
      final batch = database.batch();
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final entry in values.entries) {
        batch.insert('cache_entries', <String, Object?>{
          'core_url': normalized,
          'server_id': serverId,
          'kind': 'overview',
          'entity_key': entry.key,
          'payload': jsonEncode(entry.value),
          'updated_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
    return _writeQueue;
  }

  static Future<void> invalidateDetails(String coreUrl, String kind) {
    final normalized = _normalizedCoreUrl(coreUrl);
    _writeQueue = _writeQueue.catchError((_) {}).then((_) async {
      final database = await _open();
      await database.delete(
        'cache_entries',
        where: 'core_url = ? AND kind = ?',
        whereArgs: <Object?>[normalized, '${kind}_detail'],
      );
    });
    return _writeQueue;
  }

  static Future<void> markDetailsForRefresh(
    String coreUrl,
    String serverId,
    int cursor,
    Iterable<String> kinds,
  ) {
    final normalized = _normalizedCoreUrl(coreUrl);
    final distinctKinds = kinds.toSet();
    if (distinctKinds.isEmpty) return Future<void>.value();
    _writeQueue = _writeQueue.catchError((_) {}).then((_) async {
      final database = await _open();
      final batch = database.batch();
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final kind in distinctKinds) {
        batch.insert('detail_warm_state', <String, Object?>{
          'core_url': normalized,
          'server_id': serverId,
          'kind': kind,
          'target_cursor': cursor,
          'after_id': 0,
          'complete': 0,
          'updated_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
    return _writeQueue;
  }

  static Future<void> updateDetailWarmProgress(
    String coreUrl,
    String kind,
    int afterId, {
    required int targetCursor,
    required bool complete,
  }) {
    final normalized = _normalizedCoreUrl(coreUrl);
    _writeQueue = _writeQueue.catchError((_) {}).then((_) async {
      final database = await _open();
      await database.update(
        'detail_warm_state',
        <String, Object?>{
          'after_id': afterId,
          'complete': complete ? 1 : 0,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'core_url = ? AND kind = ? AND target_cursor = ?',
        whereArgs: <Object?>[normalized, kind, targetCursor],
      );
    });
    return _writeQueue;
  }

  static Future<Map<String, dynamic>> search(
    String coreUrl,
    String query, {
    int limit = 120,
  }) async {
    final normalized = _normalizedCoreUrl(coreUrl);
    final terms = query
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    if (terms.isEmpty) {
      return <String, dynamic>{
        'query': query,
        'tracks': const <dynamic>[],
        'albums': const <dynamic>[],
        'artists': const <dynamic>[],
        'playlists': const <dynamic>[],
      };
    }
    final database = await _open();
    final whereTerms = List<String>.filled(
      terms.length,
      'terms LIKE ?',
    ).join(' AND ');
    final rows = await database.rawQuery(
      '''
      SELECT kind, payload
      FROM search_index
      WHERE core_url = ? AND $whereTerms
      ORDER BY CASE kind
        WHEN 'track' THEN 0
        WHEN 'album' THEN 1
        WHEN 'artist' THEN 2
        ELSE 3
      END, title COLLATE NOCASE
      LIMIT ?
      ''',
      <Object?>[
        normalized,
        ...terms.map((value) => '%$value%'),
        limit.clamp(1, 500),
      ],
    );
    final result = <String, dynamic>{
      'query': query,
      'tracks': <dynamic>[],
      'albums': <dynamic>[],
      'artists': <dynamic>[],
      'playlists': <dynamic>[],
    };
    for (final row in rows) {
      final payload = _decodeCachePayload(row['payload']);
      if (payload is! Map) continue;
      final target = switch (row['kind']?.toString()) {
        'track' => result['tracks'] as List<dynamic>,
        'album' => result['albums'] as List<dynamic>,
        'artist' => result['artists'] as List<dynamic>,
        _ => result['playlists'] as List<dynamic>,
      };
      target.add(payload.cast<String, dynamic>());
    }
    return result;
  }

  static Future<void> recordError(String coreUrl, Object error) async {
    try {
      final database = await _open();
      await database.update(
        'sync_state',
        <String, Object?>{'last_error': error.toString()},
        where: 'core_url = ?',
        whereArgs: <Object?>[_normalizedCoreUrl(coreUrl)],
      );
    } catch (_) {
      // Cache diagnostics must never interfere with the foreground UI.
    }
  }

  static dynamic _decodeCachePayload(Object? payload) {
    if (payload is! String || payload.isEmpty) return null;
    try {
      return jsonDecode(payload);
    } catch (_) {
      return null;
    }
  }
}

class _DecodedCacheRows {
  const _DecodedCacheRows({
    required this.values,
    required this.trackDetails,
    required this.albumDetails,
    required this.artistDetails,
    required this.playlistDetails,
  });

  final Map<String, dynamic> values;
  final Map<int, Map<String, dynamic>> trackDetails;
  final Map<int, Map<String, dynamic>> albumDetails;
  final Map<int, Map<String, dynamic>> artistDetails;
  final Map<int, Map<String, dynamic>> playlistDetails;
}
