enum PlaybackQueueAdvanceKind { select, stop }

class PlaybackQueueAdvance {
  const PlaybackQueueAdvance.select(this.index)
    : kind = PlaybackQueueAdvanceKind.select;

  const PlaybackQueueAdvance.stop()
    : kind = PlaybackQueueAdvanceKind.stop,
      index = null;

  final PlaybackQueueAdvanceKind kind;
  final int? index;
}

/// Deterministic legacy queue projection used while V3 sessions are rolled out.
///
/// This mirrors Core's queue transition exactly. It intentionally accepts the
/// serialized API mode so cached and live queues take the same path.
PlaybackQueueAdvance nextPlaybackQueueItem({
  required List<int> itemIds,
  required int? currentIndex,
  required String mode,
  required int shuffleSeed,
  required bool automatic,
}) {
  if (itemIds.isEmpty || (automatic && mode == 'single')) {
    return const PlaybackQueueAdvance.stop();
  }
  final current = currentIndex ?? -1;
  if (automatic && mode == 'repeat_one' && current >= 0) {
    return PlaybackQueueAdvance.select(current);
  }
  if (mode == 'shuffle') {
    final order = _shuffleOrder(itemIds, shuffleSeed);
    final cursor = order.indexOf(current);
    final effectiveCursor = cursor >= 0 ? cursor : order.length - 1;
    return PlaybackQueueAdvance.select(
      order[(effectiveCursor + 1) % order.length],
    );
  }

  final candidate = current + 1;
  if (candidate < itemIds.length) {
    return PlaybackQueueAdvance.select(candidate);
  }
  if (mode == 'repeat_all' || !automatic) {
    return const PlaybackQueueAdvance.select(0);
  }
  return const PlaybackQueueAdvance.stop();
}

PlaybackQueueAdvance previousPlaybackQueueItem({
  required List<int> itemIds,
  required int? currentIndex,
  required String mode,
  required int shuffleSeed,
}) {
  if (itemIds.isEmpty) return const PlaybackQueueAdvance.stop();
  final current = currentIndex ?? itemIds.length;
  if (mode == 'shuffle') {
    final order = _shuffleOrder(itemIds, shuffleSeed);
    final cursor = order.indexOf(current);
    final effectiveCursor = cursor >= 0 ? cursor : 0;
    return PlaybackQueueAdvance.select(
      order[(effectiveCursor - 1) % order.length],
    );
  }

  final candidate = current - 1;
  if (candidate >= 0) return PlaybackQueueAdvance.select(candidate);
  return PlaybackQueueAdvance.select(itemIds.length - 1);
}

List<int> _shuffleOrder(List<int> itemIds, int seed) {
  final order = List<int>.generate(itemIds.length, (index) => index);
  order.sort((left, right) {
    final leftKey = _shuffleKey(itemIds[left], seed);
    final rightKey = _shuffleKey(itemIds[right], seed);
    final keyComparison = leftKey.compareTo(rightKey);
    return keyComparison == 0 ? left.compareTo(right) : keyComparison;
  });
  return order;
}

const int _mask64 = 0xFFFFFFFFFFFFFFFF;

int _shuffleKey(int itemId, int seed) {
  var value = _u64(itemId) ^ _u64(seed * 0x9E3779B97F4A7C15);
  value ^= value >> 30;
  value = _u64(value * 0xBF58476D1CE4E5B9);
  value ^= value >> 27;
  value = _u64(value * 0x94D049BB133111EB);
  return _u64(value ^ (value >> 31));
}

int _u64(int value) => value & _mask64;
