class PlaybackAgentItem {
  const PlaybackAgentItem({
    required this.index,
    required this.itemId,
    required this.trackId,
  });

  final int index;
  final String itemId;
  final int trackId;
}

/// Durable queue cursor for one renderer output.
///
/// Transport quality deliberately does not appear in this class. The agent
/// decides queue order; callers independently decide whether a candidate has
/// a local or remote playable media copy.
class PlaybackAgent {
  PlaybackAgent(this.outputId);

  final String outputId;
  List<PlaybackAgentItem> _items = const <PlaybackAgentItem>[];
  int? currentIndex;
  int revision = 0;
  int shuffleSeed = 1;
  String mode = 'sequential';
  String? sessionId;
  int sessionEpoch = 0;
  int sessionRevision = 0;
  int eventCursor = 0;
  String repeatMode = 'off';
  bool shuffle = false;
  bool stopAfterCurrent = false;

  List<PlaybackAgentItem> get items => _items;

  bool get hasSession => sessionId != null && sessionEpoch > 0;

  void restore(Map<String, dynamic> queue) {
    revision = _intValue(queue['revision']) ?? revision;
    shuffleSeed = _intValue(queue['shuffle_seed']) ?? shuffleSeed;
    mode = queue['mode']?.toString() ?? mode;
    _restoreLegacyMode(mode);
    final values = (queue['items'] as List?) ?? const <dynamic>[];
    _items = <PlaybackAgentItem>[
      for (var index = 0; index < values.length; index += 1)
        ?_item(values[index], index),
    ];
    final restoredIndex = _intValue(queue['current_index']);
    currentIndex =
        restoredIndex != null &&
            restoredIndex >= 0 &&
            restoredIndex < _items.length
        ? restoredIndex
        : null;
  }

  /// Applies the authoritative v3 session without replacing the richer legacy
  /// queue projection used by queue UI rows.
  void restoreSession(Map<String, dynamic> snapshot) {
    final restoredSessionId = snapshot['session_id']?.toString();
    if (restoredSessionId == null || restoredSessionId.isEmpty) return;
    sessionId = restoredSessionId;
    sessionEpoch = _intValue(snapshot['epoch']) ?? sessionEpoch;
    sessionRevision = _intValue(snapshot['revision']) ?? sessionRevision;
    eventCursor = _intValue(snapshot['event_cursor']) ?? eventCursor;
    shuffleSeed = _intValue(snapshot['shuffle_seed']) ?? shuffleSeed;
    final modeValue = snapshot['mode'];
    if (modeValue is Map) {
      repeatMode = modeValue['repeat']?.toString() ?? 'off';
      shuffle = modeValue['shuffle'] == true;
      stopAfterCurrent = modeValue['stop_after_current'] == true;
      mode = _legacyModeName();
    }
    final values = (snapshot['queue'] as List?) ?? const <dynamic>[];
    final restoredItems = <PlaybackAgentItem>[
      for (var index = 0; index < values.length; index += 1)
        ?_sessionItem(values[index], index),
    ];
    if (restoredItems.isNotEmpty || values.isEmpty) {
      _items = restoredItems;
    }
    final currentItemId = snapshot['current_item_id']?.toString();
    currentIndex = currentItemId == null
        ? null
        : _items.indexWhere((item) => item.itemId == currentItemId);
    if (currentIndex != null && currentIndex! < 0) currentIndex = null;
  }

  Map<String, dynamic> command({
    required String commandId,
    required String originDeviceId,
    required Map<String, dynamic> action,
  }) {
    final id = sessionId;
    if (id == null) {
      throw StateError('Playback session for $outputId has not been restored.');
    }
    return <String, dynamic>{
      'command_id': commandId,
      'session_id': id,
      'epoch': sessionEpoch,
      'expected_revision': sessionRevision,
      'origin_device_id': originDeviceId,
      'issued_at': DateTime.now().toUtc().toIso8601String(),
      'action': action,
    };
  }

  String? applyAck(Map<String, dynamic> ack) {
    final snapshot = ack['snapshot'];
    if (snapshot is Map) {
      restoreSession(snapshot.cast<String, dynamic>());
    }
    return ack['status']?.toString();
  }

  List<PlaybackAgentItem> nextCandidates({required bool automatic}) {
    if (_items.isEmpty || (automatic && stopAfterCurrent)) {
      return const <PlaybackAgentItem>[];
    }
    final current = currentIndex ?? -1;
    if (automatic && repeatMode == 'one' && current >= 0) {
      return <PlaybackAgentItem>[_items[current]];
    }
    if (shuffle) {
      final order = _shuffleOrder();
      final cursor = order.indexOf(current);
      final start = cursor >= 0 ? cursor + 1 : 0;
      return <PlaybackAgentItem>[
        for (var offset = 0; offset < order.length; offset += 1)
          _items[order[(start + offset) % order.length]],
      ];
    }

    final result = <PlaybackAgentItem>[];
    for (var index = current + 1; index < _items.length; index += 1) {
      result.add(_items[index]);
    }
    if (repeatMode == 'all' || !automatic) {
      final wrapEnd = current < 0 ? 0 : current + 1;
      for (
        var index = 0;
        index < wrapEnd && index < _items.length;
        index += 1
      ) {
        result.add(_items[index]);
      }
    }
    return result;
  }

  List<PlaybackAgentItem> previousCandidates() {
    if (_items.isEmpty) return const <PlaybackAgentItem>[];
    final current = currentIndex ?? _items.length;
    if (shuffle) {
      final order = _shuffleOrder();
      final cursor = order.indexOf(current);
      final start = cursor >= 0 ? cursor - 1 : order.length - 1;
      return <PlaybackAgentItem>[
        for (var offset = 0; offset < order.length; offset += 1)
          _items[order[(start - offset) % order.length]],
      ];
    }

    return <PlaybackAgentItem>[
      for (var index = current - 1; index >= 0; index -= 1) _items[index],
      for (var index = _items.length - 1; index >= current; index -= 1)
        _items[index],
    ];
  }

  bool selectIndex(int index) {
    if (index < 0 || index >= _items.length) return false;
    currentIndex = index;
    return true;
  }

  bool selectTrack(int trackId) {
    final index = _items.indexWhere((item) => item.trackId == trackId);
    return index >= 0 && selectIndex(index);
  }

  Map<String, dynamic> checkpoint(Map<String, dynamic> queue) =>
      <String, dynamic>{
        ...queue,
        'revision': revision,
        'shuffle_seed': shuffleSeed,
        'mode': mode,
        'current_index': currentIndex,
      };

  List<int> _shuffleOrder() {
    final order = List<int>.generate(_items.length, (index) => index);
    order.sort((left, right) {
      final leftKey = _shuffleKey(_items[left].itemId, shuffleSeed);
      final rightKey = _shuffleKey(_items[right].itemId, shuffleSeed);
      final comparison = leftKey.compareTo(rightKey);
      return comparison == 0 ? left.compareTo(right) : comparison;
    });
    return order;
  }

  static PlaybackAgentItem? _item(Object? value, int index) {
    if (value is! Map) return null;
    final track = value['track'];
    if (track is! Map) return null;
    final trackId = _intValue(track['id']);
    if (trackId == null) return null;
    return PlaybackAgentItem(
      index: index,
      itemId: value['id']?.toString() ?? 'index:$index:track:$trackId',
      trackId: trackId,
    );
  }

  static PlaybackAgentItem? _sessionItem(Object? value, int index) {
    if (value is! Map) return null;
    final trackId = _intValue(value['track_id']);
    final itemId = value['item_id']?.toString();
    if (trackId == null || itemId == null || itemId.isEmpty) return null;
    return PlaybackAgentItem(index: index, itemId: itemId, trackId: trackId);
  }

  void _restoreLegacyMode(String value) {
    repeatMode = switch (value) {
      'repeat_one' => 'one',
      'repeat_all' => 'all',
      _ => 'off',
    };
    shuffle = value == 'shuffle';
    stopAfterCurrent = value == 'single';
  }

  String _legacyModeName() {
    if (stopAfterCurrent) return 'single';
    if (repeatMode == 'one') return 'repeat_one';
    if (shuffle) return 'shuffle';
    if (repeatMode == 'all') return 'repeat_all';
    return 'sequential';
  }
}

int? _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

const int _mask64 = 0xFFFFFFFFFFFFFFFF;

int _shuffleKey(String itemId, int seed) {
  var identity = int.tryParse(itemId);
  if (identity == null) {
    var hash = 0xcbf29ce484222325;
    for (final codeUnit in itemId.codeUnits) {
      hash = ((hash ^ codeUnit) * 0x100000001b3) & _mask64;
    }
    identity = hash;
  }
  var value = (identity & _mask64) ^ ((seed * 0x9E3779B97F4A7C15) & _mask64);
  value ^= value >> 30;
  value = (value * 0xBF58476D1CE4E5B9) & _mask64;
  value ^= value >> 27;
  value = (value * 0x94D049BB133111EB) & _mask64;
  return (value ^ (value >> 31)) & _mask64;
}
