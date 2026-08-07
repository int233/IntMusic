import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/core/playback_queue_policy.dart';

void main() {
  const itemIds = <int>[11, 12, 13];

  test('sequential automatic advance stops at queue end', () {
    final advance = nextPlaybackQueueItem(
      itemIds: itemIds,
      currentIndex: 2,
      mode: 'sequential',
      shuffleSeed: 7,
      automatic: true,
    );

    expect(advance.kind, PlaybackQueueAdvanceKind.stop);
  });

  test('manual next wraps with the legacy Core semantics', () {
    final advance = nextPlaybackQueueItem(
      itemIds: itemIds,
      currentIndex: 2,
      mode: 'sequential',
      shuffleSeed: 7,
      automatic: false,
    );

    expect(advance.index, 0);
  });

  test('repeat one affects completion but not a manual next', () {
    final automatic = nextPlaybackQueueItem(
      itemIds: itemIds,
      currentIndex: 1,
      mode: 'repeat_one',
      shuffleSeed: 7,
      automatic: true,
    );
    final manual = nextPlaybackQueueItem(
      itemIds: itemIds,
      currentIndex: 1,
      mode: 'repeat_one',
      shuffleSeed: 7,
      automatic: false,
    );

    expect(automatic.index, 1);
    expect(manual.index, 2);
  });

  test('shuffle is deterministic for a persisted seed', () {
    List<int> traversal() {
      final result = <int>[];
      int? current = 0;
      for (var count = 0; count < itemIds.length; count += 1) {
        final advance = nextPlaybackQueueItem(
          itemIds: itemIds,
          currentIndex: current,
          mode: 'shuffle',
          shuffleSeed: 41,
          automatic: true,
        );
        current = advance.index;
        result.add(current!);
      }
      return result;
    }

    expect(traversal(), traversal());
  });
}
