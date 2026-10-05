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
  Map<String, dynamic>? queueSource;
  int sessionEpoch = 0;
  int sessionRevision = 0;
  int eventCursor = 0;
  String repeatMode = 'off';
  bool shuffle = false;
  bool stopAfterCurrent = false;

  List<PlaybackAgentItem> get items => _items;

  bool get hasSession => sessionId != null && sessionEpoch > 0;

  void restore(Map<String, dynamic> queue) {
    sessionId = null;
    queueSource = (queue['queue_source'] as Map?)?.cast<String, dynamic>();
    sessionEpoch = 0;
    sessionRevision = 0;
    revision = _intValue(queue['revision']) ?? revision;
    shuffleSeed = _intValue(queue['shuffle_seed']) ?? shuffleSeed;
    mode = queue['mode']?.toString() ?? mode;
    _restoreUiMode(mode);
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

  /// Ignores stale responses from overlapping reads and command receipts.
  void restoreSession(Map<String, dynamic> snapshot) {
    final restoredSessionId = snapshot['session_id']?.toString();
    if (restoredSessionId == null || restoredSessionId.isEmpty) return;
    final epoch = _intValue(snapshot['epoch']) ?? 0;
    final revision = _intValue(snapshot['revision']) ?? 0;
    if (restoredSessionId == sessionId &&
        (epoch < sessionEpoch ||
            epoch == sessionEpoch && revision < sessionRevision)) {
      return;
    }
    sessionId = restoredSessionId;
    queueSource = (snapshot['queue_source'] as Map?)?.cast<String, dynamic>();
    sessionEpoch = _intValue(snapshot['epoch']) ?? sessionEpoch;
    sessionRevision = _intValue(snapshot['revision']) ?? sessionRevision;
    eventCursor = _intValue(snapshot['event_cursor']) ?? eventCursor;
    shuffleSeed = _intValue(snapshot['shuffle_seed']) ?? shuffleSeed;
    final modeValue = snapshot['mode'];
    if (modeValue is Map) {
      repeatMode = modeValue['repeat']?.toString() ?? 'off';
      shuffle = modeValue['shuffle'] == true;
      stopAfterCurrent = modeValue['stop_after_current'] == true;
      mode = _uiModeName();
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
    final order = shuffle
        ? _shuffleOrder()
        : List<int>.generate(_items.length, (i) => i);
    final cursor = order.indexOf(current);
    return [
      for (final index in order.skip(cursor + 1)) _items[index],
      if (repeatMode == 'all')
        for (final index in order.take(cursor + 1)) _items[index],
    ];
  }

  List<PlaybackAgentItem> previousCandidates() {
    if (_items.isEmpty) return const [];
    final order = shuffle
        ? _shuffleOrder()
        : List<int>.generate(_items.length, (i) => i);
    final cursor = currentIndex == null
        ? order.length
        : order.indexOf(currentIndex!);
    if (cursor == 0 && repeatMode != 'all') return [_items[order.first]];
    return [
      for (final index in order.take(cursor).toList().reversed) _items[index],
      if (repeatMode == 'all')
        for (final index in order.skip(cursor).toList().reversed) _items[index],
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
      itemId: value['id'] as String,
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

  void _restoreUiMode(String value) {
    repeatMode = switch (value) {
      'repeat_one' => 'one',
      'repeat_all' => 'all',
      _ => 'off',
    };
    shuffle = value == 'shuffle';
    stopAfterCurrent = value == 'single';
  }

  String _uiModeName() {
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

// Identical to Core's UUID-based splitmix64 ordering, including unsigned math.
BigInt _shuffleKey(String itemId, int seed) {
  final hex = itemId.replaceAll('-', '');
  final high = BigInt.parse(hex.substring(0, 16), radix: 16);
  final low = BigInt.parse(hex.substring(16), radix: 16);
  final mask = (BigInt.one << 64) - BigInt.one;
  var value =
      (high ^
          low ^
          (BigInt.from(seed) * BigInt.parse('9E3779B97F4A7C15', radix: 16))) &
      mask;
  value ^= value >> 30;
  value = (value * BigInt.parse('BF58476D1CE4E5B9', radix: 16)) & mask;
  value ^= value >> 27;
  value = (value * BigInt.parse('94D049BB133111EB', radix: 16)) & mask;
  return (value ^ (value >> 31)) & mask;
}
