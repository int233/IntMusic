import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:sqflite_common/sqlite_api.dart';
import 'json_values.dart';
import 'logging/client_log.dart';
import 'network/core_api_client.dart';
import 'storage/client_cache_database.dart';

class LibraryProjection {
  const LibraryProjection({
    required this.serverId,
    required this.catalogEpoch,
    required this.cursor,
    required this.eventCursor,
    required this.values,
    required this.trackDetails,
    required this.albumDetails,
    required this.artistDetails,
    required this.pendingDetailRefresh,
    required this.pendingDetailTargetCursors,
  });

  final String? serverId;
  final String? catalogEpoch;
  final int cursor;
  final int eventCursor;
  final Map<String, dynamic> values;
  final Map<int, Map<String, dynamic>> trackDetails;
  final Map<int, Map<String, dynamic>> albumDetails;
  final Map<int, Map<String, dynamic>> artistDetails;
  final Map<String, int> pendingDetailRefresh;
  final Map<String, int> pendingDetailTargetCursors;

  bool get isEmpty => values.isEmpty;
}

class ClientLibraryRepository {
  ClientLibraryRepository(this._database);
  final ClientLibraryDatabase _database;
  Future<void> _writeQueue = Future<void>.value();
  Future<Database> _open() => _database.open();
  String _normalizedCoreUrl(String value) => _database.keyForEndpoint(value);

  Future<LibraryProjection> load(String coreUrl) async {
    try {
      final normalized = await _database.resolveEndpoint(coreUrl);
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
      final eventCursor =
          _intValue(stateRows.firstOrNull?['event_cursor']) ?? 0;
      final rows = await database.query(
        'cache_entries',
        columns: <String>['kind', 'entity_key', 'payload'],
        where: 'core_url = ?',
        whereArgs: <Object?>[normalized],
      );
      final catalogRows = await database.query(
        'catalog_entities',
        columns: <String>['kind', 'entity_id', 'payload'],
        where: 'core_url = ?',
        whereArgs: <Object?>[normalized],
        orderBy: 'kind, entity_id',
      );
      final decoded = await compute(_decodeLibraryRows, (
        rows: rows,
        catalog: catalogRows,
      ));
      final values = decoded.values;
      final trackDetails = decoded.trackDetails;
      final albumDetails = decoded.albumDetails;
      final artistDetails = decoded.artistDetails;
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
      return LibraryProjection(
        serverId: serverId,
        catalogEpoch: catalogEpoch,
        cursor: cursor,
        eventCursor: eventCursor,
        values: values,
        trackDetails: trackDetails,
        albumDetails: albumDetails,
        artistDetails: artistDetails,
        pendingDetailRefresh: pendingDetailRefresh,
        pendingDetailTargetCursors: pendingDetailTargetCursors,
      );
    } catch (error, stack) {
      ClientLog.error('library.local.load_failed', error, stackTrace: stack);
      return const LibraryProjection(
        serverId: null,
        catalogEpoch: null,
        cursor: 0,
        eventCursor: 0,
        values: <String, dynamic>{},
        trackDetails: <int, Map<String, dynamic>>{},
        albumDetails: <int, Map<String, dynamic>>{},
        artistDetails: <int, Map<String, dynamic>>{},
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
      }
    }
    return _DecodedCacheRows(
      values: values,
      trackDetails: trackDetails,
      albumDetails: albumDetails,
      artistDetails: artistDetails,
    );
  }

  static void _decodeCatalogRows(
    List<Map<String, Object?>> rows,
    Map<String, dynamic> values,
  ) {
    if (rows.isEmpty) return;
    for (final key in const <String>[
      'albums',
      'artists',
      'tracks',
      'collections',
    ]) {
      values[key] = <dynamic>[];
    }
    for (final row in rows) {
      final overviewKey = _overviewKeyForCatalogKind(
        row['kind']?.toString() ?? '',
      );
      final payload = _decodeCachePayload(row['payload']);
      if (overviewKey == null || payload is! Map) continue;
      (values[overviewKey] as List<dynamic>).add(
        payload.cast<String, dynamic>(),
      );
    }
  }

  Future<void> replaceSnapshot(
    String coreUrl,
    Map<String, dynamic> snapshot,
  ) async {
    final serverId = snapshot['server_id']?.toString() ?? '';
    final catalogEpoch = snapshot['catalog_epoch']?.toString() ?? '';
    if (serverId.isEmpty || catalogEpoch.isEmpty) {
      throw StateError('Missing catalog identity');
    }
    final normalized = 'catalog:$serverId:$catalogEpoch';
    final cursor = _intValue(snapshot['cursor']) ?? 0;
    final catalogValues = <String, List<dynamic>>{
      'albums': (snapshot['albums'] as List?) ?? const <dynamic>[],
      'artists': (snapshot['artists'] as List?) ?? const <dynamic>[],
      'tracks': (snapshot['tracks'] as List?) ?? const <dynamic>[],
      'collections': (snapshot['collections'] as List?) ?? const <dynamic>[],
    };
    final values = <String, dynamic>{
      'playback_history':
          (snapshot['playback_history'] as List?) ?? const <dynamic>[],
      'playback_stats': jsonObjectOrEmpty(snapshot['playback_stats']),
      'library_roots':
          (snapshot['library_roots'] as List?) ?? const <dynamic>[],
      'client_library_roots':
          (snapshot['client_library_roots'] as List?) ?? const <dynamic>[],
      'client_file_bindings':
          (snapshot['client_file_bindings'] as List?) ?? const <dynamic>[],
      'settings': jsonObjectOrEmpty(snapshot['settings']),
      'generated_at': snapshot['generated_at']?.toString(),
      if (snapshot['status'] is Map)
        'status': jsonObjectOrEmpty(snapshot['status']),
      if (snapshot['diagnostics'] is Map)
        'diagnostics': jsonObjectOrEmpty(snapshot['diagnostics']),
    };
    _writeQueue = _writeQueue.catchError((_) {}).then((_) async {
      final database = await _open();
      await database.transaction((transaction) async {
        final previous = await transaction.query(
          'sync_state',
          columns: <String>['server_id', 'catalog_epoch', 'event_cursor'],
          where: 'core_url = ?',
          whereArgs: <Object?>[normalized],
          limit: 1,
        );
        final sameIdentity =
            previous.isNotEmpty &&
            previous.first['server_id']?.toString() == serverId &&
            previous.first['catalog_epoch']?.toString() == catalogEpoch;
        final eventCursor = sameIdentity
            ? _intValue(previous.first['event_cursor']) ?? 0
            : 0;
        if (previous.isNotEmpty && !sameIdentity) {
          await transaction.delete(
            'cache_entries',
            where: 'core_url = ?',
            whereArgs: <Object?>[normalized],
          );
          await transaction.delete(
            'catalog_entities',
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
              for (final value in catalogValues['tracks']!)
                if (value is Map && _intValue(value['id']) != null)
                  _intValue(value['id'])!.toString(),
            },
            'album_detail': {
              for (final value in catalogValues['albums']!)
                if (value is Map && _intValue(value['id']) != null)
                  _intValue(value['id'])!.toString(),
            },
            'artist_detail': {
              for (final value in catalogValues['artists']!)
                if (value is Map && _intValue(value['id']) != null)
                  _intValue(value['id'])!.toString(),
            },
          };
          final existingDetails = await transaction.query(
            'cache_entries',
            columns: <String>['kind', 'entity_key'],
            where:
                "core_url = ? AND kind IN "
                "('track_detail','album_detail','artist_detail')",
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
        batch.delete(
          'catalog_entities',
          where: 'core_url = ?',
          whereArgs: <Object?>[normalized],
        );
        for (final entry in catalogValues.entries) {
          final kind = _catalogKindForOverviewKey(entry.key)!;
          for (final value in entry.value) {
            _addCatalogEntityInsert(
              batch,
              normalized,
              serverId,
              kind,
              value,
              now,
            );
          }
        }
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
          'event_cursor': eventCursor,
          'last_sync_at': now,
          'last_error': null,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        batch.delete(
          'search_index',
          where: 'core_url = ?',
          whereArgs: <Object?>[normalized],
        );
        for (final track in catalogValues['tracks']!) {
          _addSearchInsert(batch, normalized, 'track', track);
        }
        for (final album in catalogValues['albums']!) {
          _addSearchInsert(batch, normalized, 'album', album);
        }
        for (final artist in catalogValues['artists']!) {
          _addSearchInsert(batch, normalized, 'artist', artist);
        }
        for (final playlist in catalogValues['collections']!) {
          _addSearchInsert(batch, normalized, 'playlist', playlist);
        }
        batch.insert('core_endpoints', {
          'url': CoreApiClient.normalizeBaseUrl(coreUrl),
          'library_key': normalized,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await batch.commit(noResult: true);
      });
      _database.rememberEndpoint(coreUrl, normalized);
    });
    return _writeQueue;
  }

  Future<void> advanceCursor(
    String coreUrl,
    String serverId,
    String epoch,
    int cursor,
  ) {
    final key = _normalizedCoreUrl(coreUrl);
    _writeQueue = _writeQueue.catchError((_) {}).then((_) async {
      final db = await _open();
      await db.update(
        'sync_state',
        {'cursor': cursor},
        where:
            'core_url = ? AND server_id = ? AND catalog_epoch = ? AND cursor < ?',
        whereArgs: [key, serverId, epoch, cursor],
      );
    });
    return _writeQueue;
  }

  Future<void> updateEventCursor(
    String coreUrl,
    String serverId,
    String? catalogEpoch,
    int eventCursor,
  ) {
    if (serverId.isEmpty || eventCursor <= 0) return Future<void>.value();
    final normalized = _normalizedCoreUrl(coreUrl);
    _writeQueue = _writeQueue.catchError((_) {}).then((_) async {
      final database = await _open();
      await database.rawInsert(
        '''
        INSERT INTO sync_state (
          core_url, server_id, catalog_epoch, cursor, event_cursor, last_sync_at
        ) VALUES (?, ?, ?, 0, ?, ?)
        ON CONFLICT(core_url) DO UPDATE SET
          server_id = excluded.server_id,
          catalog_epoch = excluded.catalog_epoch,
          cursor = CASE
            WHEN sync_state.server_id = excluded.server_id
              AND COALESCE(sync_state.catalog_epoch, '') =
                  COALESCE(excluded.catalog_epoch, '')
              THEN sync_state.cursor
            ELSE 0
          END,
          event_cursor = CASE
            WHEN sync_state.server_id = excluded.server_id
              AND COALESCE(sync_state.catalog_epoch, '') =
                  COALESCE(excluded.catalog_epoch, '')
              THEN MAX(sync_state.event_cursor, excluded.event_cursor)
            ELSE excluded.event_cursor
          END,
          last_sync_at = excluded.last_sync_at
        ''',
        <Object?>[
          normalized,
          serverId,
          catalogEpoch,
          eventCursor,
          DateTime.now().millisecondsSinceEpoch,
        ],
      );
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

  static String? _catalogKindForOverviewKey(String key) => switch (key) {
    'albums' => 'album',
    'artists' => 'artist',
    'tracks' => 'track',
    'collections' => 'playlist',
    _ => null,
  };

  static String? _overviewKeyForCatalogKind(String kind) => switch (kind) {
    'album' => 'albums',
    'artist' => 'artists',
    'track' => 'tracks',
    'playlist' => 'collections',
    _ => null,
  };

  static void _addCatalogEntityInsert(
    Batch batch,
    String coreUrl,
    String serverId,
    String kind,
    dynamic value,
    int updatedAt,
  ) {
    if (value is! Map) return;
    final entity = value.cast<String, dynamic>();
    final id = _intValue(entity['id']);
    if (id == null) return;
    batch.insert('catalog_entities', <String, Object?>{
      'core_url': coreUrl,
      'server_id': serverId,
      'kind': kind,
      'entity_id': id,
      'payload': jsonEncode(entity),
      'updated_at': updatedAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> putDetail(
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

  Future<void> putDetails(
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

  Future<void> putOverviewValues(
    String coreUrl,
    String serverId,
    Map<String, dynamic> values,
  ) {
    if (values.isEmpty) return Future<void>.value();
    final normalized = _normalizedCoreUrl(coreUrl);
    _writeQueue = _writeQueue.catchError((_) {}).then((_) async {
      final database = await _open();
      await database.transaction((transaction) async {
        final batch = transaction.batch();
        final now = DateTime.now().millisecondsSinceEpoch;
        for (final entry in values.entries) {
          final catalogKind = _catalogKindForOverviewKey(entry.key);
          if (catalogKind == null) {
            batch.insert('cache_entries', <String, Object?>{
              'core_url': normalized,
              'server_id': serverId,
              'kind': 'overview',
              'entity_key': entry.key,
              'payload': jsonEncode(entry.value),
              'updated_at': now,
            }, conflictAlgorithm: ConflictAlgorithm.replace);
            continue;
          }
          batch.delete(
            'catalog_entities',
            where: 'core_url = ? AND kind = ?',
            whereArgs: <Object?>[normalized, catalogKind],
          );
          batch.delete(
            'search_index',
            where: 'core_url = ? AND kind = ?',
            whereArgs: <Object?>[normalized, catalogKind],
          );
          for (final value in (entry.value as List?) ?? const <dynamic>[]) {
            _addCatalogEntityInsert(
              batch,
              normalized,
              serverId,
              catalogKind,
              value,
              now,
            );
            _addSearchInsert(batch, normalized, catalogKind, value);
          }
        }
        await batch.commit(noResult: true);
      });
    });
    return _writeQueue;
  }

  Future<void> invalidateDetails(String coreUrl, String kind) {
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

  Future<void> markDetailsForRefresh(
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

  Future<void> updateDetailWarmProgress(
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

  Future<Map<String, dynamic>> search(
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
        'collections': const <dynamic>[],
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
      'collections': <dynamic>[],
    };
    for (final row in rows) {
      final payload = _decodeCachePayload(row['payload']);
      if (payload is! Map) continue;
      final target = switch (row['kind']?.toString()) {
        'track' => result['tracks'] as List<dynamic>,
        'album' => result['albums'] as List<dynamic>,
        'artist' => result['artists'] as List<dynamic>,
        _ => result['collections'] as List<dynamic>,
      };
      target.add(payload.cast<String, dynamic>());
    }
    return result;
  }

  Future<void> recordError(String coreUrl, Object error) async {
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
  });

  final Map<String, dynamic> values;
  final Map<int, Map<String, dynamic>> trackDetails;
  final Map<int, Map<String, dynamic>> albumDetails;
  final Map<int, Map<String, dynamic>> artistDetails;
}

_DecodedCacheRows _decodeLibraryRows(
  ({List<Map<String, Object?>> rows, List<Map<String, Object?>> catalog}) data,
) {
  final result = ClientLibraryRepository._decodeRows(data.rows);
  ClientLibraryRepository._decodeCatalogRows(data.catalog, result.values);
  return result;
}

int? _intValue(Object? value) =>
    value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');
