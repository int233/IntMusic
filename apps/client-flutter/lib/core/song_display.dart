import 'package:flutter/foundation.dart';

import 'serial_task_queue.dart';

/// The catalog owns saved modes; edits take effect immediately, including on
/// cached detail pages. A saved edit stays visible until a snapshot confirms it.
class SongDisplayState extends ChangeNotifier {
  final _writes = SerialTaskQueue();
  Map<String, String> _catalog = {};
  final _confirmed = <String, ({String mode, int cursor})>{};
  int _catalogCursor = 0;
  final _pending = <String, ({Object token, String mode})>{};
  Object _identity = Object();

  static String _key(Map track) => track['release_identity_id'] != null
      ? 'edition:${track['release_identity_id']}'
      : 'track:${track['id']}';

  void updateCatalog(Iterable<dynamic> tracks, {required int cursor}) {
    if (cursor < _catalogCursor) return;
    _catalogCursor = cursor;
    _catalog = {
      for (final track in tracks.whereType<Map>())
        _key(track): track['display_mode']?.toString() ?? 'inherit',
    };
    _confirmed.removeWhere((key, edit) => cursor >= edit.cursor);
    notifyListeners();
  }

  Map<String, dynamic> project(Map<String, dynamic> track) {
    final key = _key(track);
    return {
      ...track,
      'display_mode':
          _pending[key]?.mode ??
          _confirmed[key]?.mode ??
          _catalog[key] ??
          track['display_mode'] ??
          'inherit',
    };
  }

  Future<void> setMode(
    Map<String, dynamic> track,
    String mode,
    Future<Map<String, dynamic>> Function() save,
  ) async {
    final key = _key(track);
    final token = Object();
    final identity = _identity;
    _pending[key] = (token: token, mode: mode);
    notifyListeners();
    try {
      await _writes.run(() async {
        if (!identical(identity, _identity)) return;
        final saved = await save();
        if (!identical(identity, _identity)) return;
        final cursor = saved['cursor'] as int;
        if (cursor > _catalogCursor) {
          _confirmed[key] = (mode: mode, cursor: cursor);
        }
      });
    } finally {
      if (identical(identity, _identity)) {
        if (identical(_pending[key]?.token, token)) _pending.remove(key);
        notifyListeners();
      }
    }
  }

  void reset() {
    _identity = Object();
    _catalog.clear();
    _catalogCursor = 0;
    _confirmed.clear();
    _pending.clear();
  }

  @override
  void dispose() {
    reset();
    super.dispose();
  }
}

/// A list projection only. The members retain their album identity and file
/// routing; the representative is an existing member, never a synthetic song.
List<Map<String, dynamic>> projectSongList(
  Iterable<dynamic> tracks, {
  required bool mergeSameName,
  String filter = 'all',
  bool sortByMode = false,
}) {
  final groups = <String, List<Map<String, dynamic>>>{};
  var occurrence = 0;
  for (final value in tracks) {
    final track = Map<String, dynamic>.from(value as Map);
    final mode = track['display_mode']?.toString() ?? 'inherit';
    if (filter != 'all' && filter != mode) continue;
    final merge = mode == 'merged' || (mode == 'inherit' && mergeSameName);
    final key = track['display_group_key']?.toString();
    // Missing artist metadata must never collapse unrelated songs.
    final group = merge && key != null && key.isNotEmpty
        ? 'group:$key'
        : 'occurrence:${occurrence++}';
    (groups[group] ??= []).add(track);
  }
  final result = groups.values.map((members) {
    // Stable order among equally usable copies. Do not combine metadata from
    // different albums or choose an unavailable version over a playable one.
    var representative = members.first;
    for (final member in members.skip(1)) {
      if (_availabilityRank(member) > _availabilityRank(representative)) {
        representative = member;
      }
    }
    return <String, dynamic>{
      ...representative,
      if (members.length > 1) '_display_members': members,
    };
  }).toList();
  if (sortByMode) {
    final indexed = result.indexed.toList();
    indexed.sort((a, b) {
      final mode = (a.$2['display_mode'] ?? 'inherit').toString().compareTo(
        (b.$2['display_mode'] ?? 'inherit').toString(),
      );
      return mode != 0 ? mode : a.$1.compareTo(b.$1);
    });
    return indexed.map((item) => item.$2).toList();
  }
  return result;
}

int _availabilityRank(Map<String, dynamic> track) {
  final availability = track['_availability'];
  if (availability is! Map || availability['state'] == 'checking') {
    return track['is_available'] == true ? 2 : 0;
  }
  return switch (availability['state']) {
    'local' || 'core' => 3,
    'remote' || 'available' => 2,
    'offline' || 'missing' || 'unavailable' => -1,
    _ => 0,
  };
}

String songDisplayModeLabel(Object? mode) => switch (mode) {
  'merged' => '合并展示',
  'independent' => '独立展示',
  _ => '跟随设置',
};
