import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'storage/client_cache_database.dart';
import 'logging/client_log.dart';
import 'network/core_api_client.dart';

typedef JsonMap = Map<String, dynamic>;
JsonMap _map(Object? value) => Map<String, dynamic>.from(value as Map);

JsonMap emptyCollection([String type = 'track']) => {
  'name': '',
  'description': '',
  'entity_type': type,
  'cover_album_id': null,
  'included': <int>[],
  'excluded': <int>[],
  'automatic': null,
  'sort': [
    {'field': 'name', 'descending': false},
  ],
  'limit': null,
  'refresh': 'live',
  'max_per_artist': null,
  'max_per_album': null,
  'playback': {'filter': null, 'artist_role': 'performer', 'order': 'album'},
};

/// Collections, layout and immutable result pages share a fenced catalog identity.
/// The player receives an explicit plan; refreshing this store never edits it.
class CollectionStore extends ChangeNotifier {
  CollectionStore({
    this.persist = true,
    bool backgroundSync = true,
    ClientLibraryDatabase? database,
  }) : _networkAvailable = backgroundSync,
       _database = database ?? ClientLibraryDatabase.shared;
  bool _networkAvailable;
  final ClientLibraryDatabase _database;
  Future<void> _hydration = Future.value();
  final Map<int, JsonMap> _tracksByRelease = {};
  final bool persist;
  CoreApiClient? _api;
  String? _identity, _server, _epoch;
  int _generation = 0;
  int _mutation = 0;
  bool _disposed = false;
  bool _backgrounded = false;
  bool supported = false, online = false, loading = false;
  bool hasSnapshot = false;
  bool get complete =>
      hasSnapshot &&
      items.every((item) {
        final page = pages[item['id']];
        return page != null &&
            page['result_version'] == item['result_version'] &&
            page['next_offset'] == null &&
            _hasPlaybackMembers(page);
      });
  String? error;
  List<JsonMap> items = [];
  JsonMap settings = {}, schema = {}, layout = {};
  final Map<int, JsonMap> pages = {};
  final Map<int, Future<JsonMap>> _reads = {};
  final Map<int, int> _demand = {};
  final Map<int, JsonMap> _refreshRequests = {};
  Timer? _timer;
  Future<void>? _refresh;
  bool _refreshAgain = false;
  Future<void> _cacheWrites = Future.value();
  String? get identity => _identity;
  bool _hasPlaybackMembers(JsonMap page) =>
      (page['items'] as List? ?? []).every(
        (item) =>
            item['entity_type'] == 'track' ||
            item['playback_track_ids'] is List,
      );
  JsonMap? summary(int id) => items.where((v) => v['id'] == id).firstOrNull;
  List<JsonMap> search(String query, {int limit = 120}) {
    final terms = query
        .toLowerCase()
        .trim()
        .split(RegExp(r'\s+'))
        .where((v) => v.isNotEmpty);
    return items
        .where(
          (item) =>
              item['system_key'] == null &&
              terms.every(
                ('${item['name']} ${item['description'] ?? ''}')
                    .toLowerCase()
                    .contains,
              ),
        )
        .take(limit)
        .toList();
  }

  Map<String, String> get _headers => {
    'x-intmusic-server-id': _server!,
    'x-intmusic-catalog-epoch': _epoch!,
  };
  bool _current(int generation) => !_disposed && generation == _generation;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _check(JsonMap data, int generation) {
    if (!_current(generation) ||
        data['server_id'] != _server ||
        data['catalog_epoch'] != _epoch) {
      throw StateError('资料库已切换，请重新打开集合');
    }
  }

  void configure(CoreApiClient api, JsonMap? status) {
    final supports =
        (status?['capabilities'] as List?)?.contains('collections_v1') == true;
    final server = status?['server_id']?.toString();
    final epoch = status?['catalog_epoch']?.toString();
    final identity = supports && server != null && epoch != null
        ? 'catalog:$server:$epoch'
        : null;
    // A missing network status must not discard a previously loaded library.
    if (identity == null) return;
    if (_identity == identity) {
      _api = api;
      return;
    }
    reset();
    supported = supports;
    _api = api;
    _identity = identity;
    _server = server;
    _epoch = epoch;
    final generation = _generation;
    _hydration = _restore(generation);
    unawaited(_start(generation));
  }

  Future<void> get ready => _hydration;
  Future<void> get persisted => _cacheWrites;

  void updateCatalog(List<dynamic> tracks) {
    _tracksByRelease.clear();
    for (final raw in tracks.whereType<Map>()) {
      final track = _map(raw);
      final release = track['release_identity_id'];
      if (release is int) _tracksByRelease[release] = track;
    }
  }

  void markUnavailable() => setNetworkAvailable(false);

  void setNetworkAvailable(bool available) {
    if (_networkAvailable == available) return;
    _networkAvailable = available;
    if (!available) {
      _timer?.cancel();
      _timer = null;
      online = false;
      _notify();
    } else if (supported && _api != null) {
      _startTimer();
    }
  }

  void _startTimer() {
    _timer ??= Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(refresh()),
    );
  }

  Future<void> _restore(int generation) async {
    if (!persist) return;
    try {
      final data = await _database.readDocument('collections', _identity!);
      if (!_current(generation) || data == null) return;
      hasSnapshot = true;
      items = (data['items'] as List).map(_map).toList();
      settings = _map(data['settings']);
      schema = _map(data['schema']);
      layout = _map(data['layout']);
      pages.addAll(
        _map(data['pages']).map((k, v) => MapEntry(int.parse(k), _map(v))),
      );
      _notify();
    } catch (e, stack) {
      ClientLog.error('library.collections.read_failed', e, stackTrace: stack);
      error = e.toString();
    }
  }

  Future<void> _start(int generation) async {
    await _hydration;
    if (!_current(generation) || !_networkAvailable) return;
    _startTimer();
    await refresh();
  }

  /// Pause catalog work while the screen is hidden; renderer tasks are separate.
  void setBackgrounded(bool value) {
    if (_disposed || value == _backgrounded) return;
    _backgrounded = value;
    if (!value) unawaited(refresh());
  }

  Future<void> refresh() {
    if (_disposed ||
        _backgrounded ||
        !_networkAvailable ||
        !supported ||
        _api == null) {
      return Future.value();
    }
    if (_refresh != null) {
      _refreshAgain = true;
      return _refresh!;
    }
    final generation = _generation;
    return _refresh =
        (() async {
          do {
            _refreshAgain = false;
            await _refreshData(generation);
          } while (_current(generation) && !_backgrounded && _refreshAgain);
        })().whenComplete(() {
          if (_current(generation)) _refresh = null;
        });
  }

  Future<void> _refreshData(int generation) async {
    await _hydration;
    if (!_current(generation)) return;
    final mutation = _mutation;
    final api = _api!;
    loading = true;
    _notify();
    try {
      final values = await Future.wait([
        api.getJson('/collections'),
        api.getJson('/settings/collections'),
        api.getJson('/collections/rule-schema'),
        api.getJson('/home-layout'),
      ]);
      if (!_networkAvailable) return;
      final maps = values.map(_map).toList();
      for (final data in maps) {
        _check(data, generation);
      }
      if (mutation != _mutation) {
        _refreshAgain = true;
        return;
      }
      final nextItems = (maps[0]['items'] as List).map(_map).toList();
      await _persistState(
        items: nextItems,
        settings: maps[1],
        schema: maps[2],
        layout: maps[3],
      );
      if (!_current(generation) || mutation != _mutation) return;
      hasSnapshot = true;
      items = nextItems;
      settings = maps[1];
      schema = maps[2];
      layout = maps[3];
      online = true;
      error = null;
      final ids = items.map((i) => i['id']).toSet();
      pages.removeWhere((id, _) => !ids.contains(id));
      _demand.removeWhere((id, _) => !ids.contains(id));
      _notify();
      // Cache complete immutable batches, including collections never opened.
      // Serial reads bound CPU, memory and Core database demand on small clients.
      for (final item in items.toList()) {
        if (!_current(generation)) return;
        final id = item['id'] as int;
        final cached = pages[id];
        if (cached == null ||
            cached['result_version'] != item['result_version'] ||
            cached['next_offset'] != null ||
            !_hasPlaybackMembers(cached)) {
          await load(id, count: 0x7fffffff, fresh: true);
        }
      }
    } catch (e, stack) {
      if (_current(generation)) {
        online = false;
        error = e.toString();
        ClientLog.error(
          'library.collections.sync_failed',
          e,
          stackTrace: stack,
        );
      }
    } finally {
      if (_current(generation)) {
        loading = false;
        _notify();
      }
    }
  }

  Future<JsonMap> load(int id, {int count = 50, bool fresh = false}) async {
    await _hydration;
    final generation = _generation;
    _demand[id] = max(count, _demand[id] ?? 0);
    final available = pages[id];
    if ((!fresh || !_networkAvailable) && available != null) return available;
    if (!_networkAvailable) throw StateError('集合尚未同步到本机');
    final pending = _reads[id];
    if (pending != null) {
      await pending;
      if (!_current(generation)) throw StateError('资料库已切换');
    }
    final cached = pages[id];
    if (!fresh &&
        cached != null &&
        (!online ||
            (cached['items'] as List).length >= count ||
            cached['next_offset'] == null)) {
      return cached;
    }
    final future = _read(id, count, generation, fresh: fresh);
    _reads[id] = future;
    try {
      return await future;
    } finally {
      if (identical(_reads[id], future)) _reads.remove(id);
    }
  }

  Future<JsonMap> _read(
    int id,
    int count,
    int generation, {
    required bool fresh,
  }) async {
    final api = _api!;
    final mutation = _mutation;
    final cached = pages[id];
    try {
      JsonMap page;
      final canExtend =
          !fresh &&
          cached != null &&
          cached['result_version'] == summary(id)?['result_version'];
      if (canExtend) {
        page = {
          ...cached,
          'items': [...cached['items'] as List],
        };
      } else {
        page = _map(
          await api.getJson('/collections/$id?limit=${min(count, 200)}'),
        );
        _check(page, generation);
      }
      final version = page['result_version'];
      while ((page['items'] as List).length < count &&
          page['next_offset'] != null) {
        final offset = page['next_offset'] as int;
        final next = _map(
          await api.getJson(
            '/collections/$id?limit=200&offset=$offset&result_version=${Uri.encodeQueryComponent(version.toString())}',
          ),
        );
        _check(next, generation);
        if (next['result_version'] != version ||
            (next['next_offset'] != null &&
                (next['next_offset'] as int) <= offset)) {
          throw StateError('集合分页无效');
        }
        (page['items'] as List).addAll(next['items'] as List);
        page['next_offset'] = next['next_offset'];
      }
      _check(page, generation);
      // A delayed read must never replace a newer acknowledged edit.
      if (mutation != _mutation) {
        final acknowledged = pages[id];
        if (acknowledged != null) return acknowledged;
        throw StateError('集合已更新，请重新加载');
      }
      final entries = page['items'] as List;
      if (!_hasPlaybackMembers(page)) {
        throw const FormatException('Core 未提供集合的本地播放信息，请更新 Core');
      }
      if (entries.map((v) => (v as Map)['entity_id']).toSet().length !=
              entries.length ||
          (page['next_offset'] == null &&
              entries.length != page['result_total'])) {
        throw StateError('集合结果不完整');
      }
      page['offline'] = false;
      await _persistState(pages: {...pages, id: page});
      if (!_current(generation) || mutation != _mutation) {
        return pages[id] ?? page;
      }
      pages[id] = page;
      _notify();
      return page;
    } catch (e) {
      if (!_current(generation) || cached == null || fresh) rethrow;
      online = false;
      error = e.toString();
      _notify();
      return {...cached, 'offline': true};
    }
  }

  Future<JsonMap> _write(
    String path,
    JsonMap body, {
    bool patch = false,
    bool refreshAfter = true,
  }) async {
    if (!online || _api == null) throw StateError('Core 未连接，无法保存或生成结果');
    final generation = _generation;
    final data = _map(
      await (patch
          ? _api!.patchJson(path, body, headers: _headers)
          : _api!.postJson(path, body, headers: _headers)),
    );
    _check(data, generation);
    if (refreshAfter) {
      _mutation++;
      var nextItems = items;
      var nextPages = Map<int, JsonMap>.of(pages);
      var nextLayout = layout;
      var nextSettings = settings;
      if (data['collection'] is Map) {
        final acknowledged = _map(data['collection']);
        final id = acknowledged['id'] as int;
        nextItems = [...items.where((v) => v['id'] != id), acknowledged];
        nextPages[id] = data;
      } else if (data['sections'] is List) {
        nextLayout = data;
      } else if (data['management_enabled'] is bool) {
        nextSettings = data;
      }
      await _persistState(
        items: nextItems,
        pages: nextPages,
        layout: nextLayout,
        settings: nextSettings,
      );
      if (!_current(generation)) return data;
      items = nextItems;
      pages
        ..clear()
        ..addAll(nextPages);
      layout = nextLayout;
      settings = nextSettings;
      _notify();
      unawaited(refresh());
    }
    return data;
  }

  Future<JsonMap> save(JsonMap definition, {int? id, int? revision}) => _write(
    id == null ? '/collections' : '/collections/$id',
    {'expected_revision': revision, 'definition': definition},
    patch: id != null,
  );

  Future<JsonMap> preview(JsonMap definition) =>
      _write('/collections/preview', definition, refreshAfter: false);
  Future<void> setManagement(bool enabled) async {
    await _write('/settings/collections', {
      'management_enabled': enabled,
      'expected_revision': settings['revision'],
    }, patch: true);
  }

  Future<void> saveLayout(List<JsonMap> sections, int revision) async {
    await _write('/home-layout', {
      'expected_revision': revision,
      'sections': sections,
    }, patch: true);
  }

  Future<void> remove(int id, int revision) async {
    if (!online) throw StateError('Core 未连接');
    final generation = _generation;
    final result = _map(
      await _api!.deleteJson(
        '/collections/$id?expected_revision=$revision',
        headers: _headers,
      ),
    );
    _check(result, generation);
    _mutation++;
    final nextItems = items.where((item) => item['id'] != id).toList();
    final nextPages = Map<int, JsonMap>.of(pages)..remove(id);
    final nextLayout = {
      ...layout,
      'sections': (layout['sections'] as List? ?? [])
          .where((s) => (s as Map)['collection_id'] != id)
          .toList(),
    };
    await _persistState(items: nextItems, pages: nextPages, layout: nextLayout);
    if (!_current(generation)) return;
    items = nextItems;
    pages
      ..clear()
      ..addAll(nextPages);
    layout = nextLayout;
    _demand.remove(id);
    _notify();
    unawaited(refresh());
  }

  Future<JsonMap> resetRules(int id, int revision) =>
      _write('/collections/$id/reset', {'expected_revision': revision});
  Future<JsonMap> refreshBatch(int id) async {
    final body = _refreshRequests.putIfAbsent(
      id,
      () => {
        'expected_result_version': summary(id)?['result_version'],
        'request_id':
            '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}',
      },
    );
    try {
      final result = await _write('/collections/$id/refresh', body);
      _refreshRequests.remove(id);
      return result;
    } on HttpException {
      _refreshRequests.remove(id);
      rethrow;
    }
  }

  Future<JsonMap> playPlan(int id, String version, {List<int>? entityIds}) =>
      _write('/collections/$id/play', {
        'result_version': version,
        'entity_ids': entityIds,
      }, refreshAfter: false);
  Future<JsonMap> browse(String type, String query, {int offset = 0}) async {
    final generation = _generation;
    final data = _map(
      await _api!.getJson(
        '/collections/entities/$type?q=${Uri.encodeQueryComponent(query)}&offset=$offset&limit=50',
      ),
    );
    _check(data, generation);
    return data;
  }

  Future<List<JsonMap>> lookup(String type, List<int> ids) async {
    final generation = _generation;
    final found = <JsonMap>[];
    for (var offset = 0; offset < ids.length; offset += 100) {
      final chunk = ids.skip(offset).take(100).join(',');
      final data = _map(
        await _api!.getJson('/collections/entities/$type?ids=$chunk&limit=200'),
      );
      _check(data, generation);
      found.addAll((data['items'] as List).map(_map));
    }
    return found;
  }

  Future<void> _persistState({
    List<JsonMap>? items,
    JsonMap? settings,
    JsonMap? schema,
    JsonMap? layout,
    Map<int, JsonMap>? pages,
  }) {
    if (!persist || _identity == null) return Future.value();
    final identity = _identity!;
    final data = {
      'items': items ?? this.items,
      'settings': settings ?? this.settings,
      'schema': schema ?? this.schema,
      'layout': layout ?? this.layout,
      'pages': (pages ?? this.pages).map((k, v) => MapEntry('$k', v)),
    };
    final payload = encodeLocalLibraryDocument(data);
    // A failed write is reported to the synchronizer and never publishes new UI state.
    _cacheWrites = _cacheWrites
        .catchError((_) {})
        .then(
          (_) async => _database.writeEncodedDocument(
            'collections',
            identity,
            await payload,
          ),
        );
    return _cacheWrites;
  }

  JsonMap? localGenreDetail(int id) {
    for (final page in pages.values) {
      for (final raw in page['items'] as List? ?? []) {
        final item = _map(raw);
        if (item['entity_type'] != 'genre' || item['entity_id'] != id) continue;
        final genre = _map(item['data']);
        final name = genre['name'].toString().trim().toLowerCase();
        return {
          'genre': genre,
          'tracks': _tracksByRelease.values
              .where(
                (track) => (track['genres'] as List? ?? []).any(
                  (tag) => tag.toString().trim().toLowerCase() == name,
                ),
              )
              .toList(),
        };
      }
    }
    return null;
  }

  JsonMap localPlayPlan(int id, String version, {List<int>? entityIds}) {
    final page = pages[id];
    if (page == null || page['result_version'] != version) {
      throw StateError('集合内容尚未同步到本机');
    }
    final tracks = <JsonMap>[];
    final seen = <int>{};
    for (final raw in page['items'] as List) {
      final item = _map(raw);
      if (entityIds != null && !entityIds.contains(item['entity_id'])) continue;
      if (item['entity_type'] == 'track') {
        final track = _tracksByRelease[item['entity_id']] ?? _map(item['data']);
        if (seen.add(track['id'] as int)) tracks.add(track);
      } else {
        for (final release in item['playback_track_ids'] as List? ?? []) {
          final track = _tracksByRelease[release];
          if (track != null && seen.add(track['id'] as int)) tracks.add(track);
        }
      }
    }
    return {'tracks': tracks, 'missing_count': 0, 'source': null};
  }

  void reset() {
    _generation++;
    _hydration = Future.value();
    _timer?.cancel();
    _timer = null;
    _refresh = null;
    _refreshAgain = false;
    _api = null;
    _identity = null;
    _server = null;
    _epoch = null;
    supported = false;
    hasSnapshot = false;
    online = false;
    loading = false;
    error = null;
    items = [];
    settings = {};
    schema = {};
    layout = {};
    pages.clear();
    _reads.clear();
    _demand.clear();
    _refreshRequests.clear();
  }

  @override
  void dispose() {
    _disposed = true;
    reset();
    super.dispose();
  }
}
