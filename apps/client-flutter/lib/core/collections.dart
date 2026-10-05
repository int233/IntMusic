import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
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
  CollectionStore({this.persist = true});
  final bool persist;
  CoreApiClient? _api;
  String? _identity, _server, _epoch;
  int _generation = 0;
  int _mutation = 0;
  bool _disposed = false;
  bool _backgrounded = false;
  bool supported = false, online = false, loading = false;
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
        ? '${api.baseUrl}|$server|$epoch'
        : null;
    if (_identity == identity && supported == supports) return;
    reset();
    supported = supports;
    if (identity == null) return;
    _api = api;
    _identity = identity;
    _server = server;
    _epoch = epoch;
    final generation = _generation;
    unawaited(Future.microtask(() => _start(generation)));
  }

  Future<void> _start(int generation) async {
    if (!_current(generation)) return;
    if (persist) {
      try {
        final file = await _cacheFile(_identity!);
        if (!_current(generation)) return;
        if (await file.exists()) {
          final data = _map(jsonDecode(await file.readAsString()));
          if (!_current(generation)) return;
          items = (data['items'] as List).map(_map).toList();
          settings = _map(data['settings']);
          schema = _map(data['schema']);
          layout = _map(data['layout']);
          pages.addAll(
            _map(data['pages']).map((k, v) => MapEntry(int.parse(k), _map(v))),
          );
          _notify();
        }
      } catch (_) {
        /* Cache failure does not block the current Core. */
      }
    }
    if (!_current(generation)) return;
    _timer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(refresh()),
    );
    await refresh();
  }

  /// Pause catalog work while the screen is hidden; renderer tasks are separate.
  void setBackgrounded(bool value) {
    if (_disposed || value == _backgrounded) return;
    _backgrounded = value;
    if (!value) unawaited(refresh());
  }

  Future<void> refresh() {
    if (_disposed || _backgrounded || !supported || _api == null) {
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
      final maps = values.map(_map).toList();
      for (final data in maps) {
        _check(data, generation);
      }
      if (mutation != _mutation) {
        _refreshAgain = true;
        return;
      }
      items = (maps[0]['items'] as List).map(_map).toList();
      settings = maps[1];
      schema = maps[2];
      layout = maps[3];
      online = true;
      error = null;
      final ids = items.map((i) => i['id']).toSet();
      pages.removeWhere((id, _) => !ids.contains(id));
      _demand.removeWhere((id, _) => !ids.contains(id));
      _notify();
      // Read only requested result sets. Multiple home sections reuse one batch.
      await Future.wait(
        _demand.keys.toList().map((id) async {
          if (pages[id]?['result_version'] != summary(id)?['result_version']) {
            try {
              await load(id, count: _demand[id] ?? 50, fresh: true);
            } catch (e) {
              if (_current(generation)) error = e.toString();
            }
          }
        }),
      );
      if (!_current(generation)) return;
      _saveCache();
    } catch (e) {
      if (_current(generation)) {
        online = false;
        error = e.toString();
      }
    } finally {
      if (_current(generation)) {
        loading = false;
        _notify();
      }
    }
  }

  Future<JsonMap> load(int id, {int count = 50, bool fresh = false}) async {
    final generation = _generation;
    _demand[id] = max(count, _demand[id] ?? 0);
    final pending = _reads[id];
    if (pending != null) {
      await pending;
      if (!_current(generation)) throw StateError('资料库已切换');
    }
    final cached = pages[id];
    if (!fresh &&
        cached != null &&
        (cached['result_version'] == summary(id)?['result_version'] ||
            !online) &&
        ((cached['items'] as List).length >= count ||
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
      if (entries.map((v) => (v as Map)['entity_id']).toSet().length !=
              entries.length ||
          (page['next_offset'] == null &&
              entries.length != page['result_total'])) {
        throw StateError('集合结果不完整');
      }
      page['offline'] = false;
      pages[id] = page;
      _saveCache();
      _notify();
      return page;
    } on SocketException {
      if (!_current(generation) || cached == null) rethrow;
      return {...cached, 'offline': true};
    } on TimeoutException {
      if (!_current(generation) || cached == null) rethrow;
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
      if (data['collection'] is Map) {
        final summary = _map(data['collection']);
        final id = summary['id'] as int;
        items = [...items.where((v) => v['id'] != id), summary];
        pages[id] = data;
      } else if (data['sections'] is List) {
        layout = data;
      } else if (data['management_enabled'] is bool) {
        settings = data;
      }
      _notify();
      _saveCache();
      // Saving is complete at acknowledgement; background revalidation must
      // not keep the editor waiting for unrelated pages or slow readers.
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
    items = items.where((item) => item['id'] != id).toList();
    pages.remove(id);
    _demand.remove(id);
    layout = {
      ...layout,
      'sections': (layout['sections'] as List? ?? [])
          .where((s) => (s as Map)['collection_id'] != id)
          .toList(),
    };
    _notify();
    await refresh();
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

  static Future<File> _cacheFile(String identity) async {
    final dir = Directory(
      '${(await getApplicationSupportDirectory()).path}/collections',
    );
    await dir.create(recursive: true);
    return File('${dir.path}/${sha256.convert(utf8.encode(identity))}.json');
  }

  void _saveCache() {
    if (!persist || _identity == null) return;
    final identity = _identity!;
    final data = jsonEncode({
      'items': items,
      'settings': settings,
      'schema': schema,
      'layout': layout,
      'pages': pages.map((k, v) => MapEntry('$k', v)),
    });
    _cacheWrites = _cacheWrites
        .then((_) async {
          final file = await _cacheFile(identity);
          final temp = File('${file.path}.tmp');
          await temp.writeAsString(data, flush: true);
          await temp.rename(file.path);
        })
        .catchError((_) {});
  }

  void reset() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _refresh = null;
    _refreshAgain = false;
    _api = null;
    _identity = null;
    _server = null;
    _epoch = null;
    supported = false;
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
