import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/core/playback_agent.dart';

Map<String, dynamic> queue({
  String mode = 'sequential',
  int? currentIndex = 0,
}) => <String, dynamic>{
  'revision': 7,
  'shuffle_seed': 41,
  'mode': mode,
  'current_index': currentIndex,
  'items': <Map<String, dynamic>>[
    <String, dynamic>{
      'id': '00000000-0000-4000-8000-000000000011',
      'track': <String, dynamic>{'id': 11},
    },
    <String, dynamic>{
      'id': '00000000-0000-4000-8000-000000000012',
      'track': <String, dynamic>{'id': 12},
    },
    <String, dynamic>{
      'id': '00000000-0000-4000-8000-000000000013',
      'track': <String, dynamic>{'id': 13},
    },
  ],
};

void main() {
  test(
    'sequential completion exposes remaining candidates without wrapping',
    () {
      final agent = PlaybackAgent('output')..restore(queue());

      expect(
        agent.nextCandidates(automatic: true).map((item) => item.trackId),
        <int>[12, 13],
      );
    },
  );

  test('manual next stops at the end unless repeat-all is enabled', () {
    final agent = PlaybackAgent('output')..restore(queue(currentIndex: 2));

    expect(
      agent.nextCandidates(automatic: false).map((item) => item.trackId),
      <int>[],
    );
  });

  test('repeat one keeps the current item only for automatic completion', () {
    final agent = PlaybackAgent('output')
      ..restore(queue(mode: 'repeat_one', currentIndex: 1));

    expect(
      agent.nextCandidates(automatic: true).map((item) => item.trackId),
      <int>[12],
    );
    expect(agent.nextCandidates(automatic: false).first.trackId, 13);
  });

  test('shuffle traversal is stable and covers every queue item once', () {
    List<int> traversal() {
      final agent = PlaybackAgent('output')
        ..restore(queue(mode: 'shuffle', currentIndex: null));
      return agent
          .nextCandidates(automatic: true)
          .map((item) => item.trackId)
          .toList(growable: false);
    }

    expect(traversal(), traversal());
    expect(traversal().toSet(), <int>{11, 12, 13});
  });

  test('checkpoint preserves the selected cursor', () {
    final source = queue();
    final agent = PlaybackAgent('output')..restore(source);

    expect(agent.selectIndex(2), isTrue);
    expect(agent.checkpoint(source)['current_index'], 2);
  });

  test('can recover a missing queue cursor from the canonical track id', () {
    final agent = PlaybackAgent('output')..restore(queue(currentIndex: null));

    expect(agent.selectTrack(12), isTrue);
    expect(agent.currentIndex, 1);
  });

  test('v3 snapshot keeps stable item identity and independent mode flags', () {
    final agent = PlaybackAgent('output')
      ..restoreSession(<String, dynamic>{
        'session_id': '01900000-0000-7000-8000-000000000001',
        'epoch': 3,
        'revision': 12,
        'event_cursor': 98,
        'shuffle_seed': 44,
        'current_item_id': '01900000-0000-7000-8000-000000000012',
        'mode': <String, dynamic>{
          'repeat': 'all',
          'shuffle': true,
          'stop_after_current': false,
        },
        'queue': <Map<String, dynamic>>[
          <String, dynamic>{
            'item_id': '01900000-0000-7000-8000-000000000011',
            'track_id': 11,
          },
          <String, dynamic>{
            'item_id': '01900000-0000-7000-8000-000000000012',
            'track_id': 12,
          },
        ],
      });

    expect(agent.hasSession, isTrue);
    expect(agent.sessionEpoch, 3);
    expect(agent.sessionRevision, 12);
    expect(agent.eventCursor, 98);
    expect(agent.currentIndex, 1);
    expect(agent.shuffle, isTrue);
    expect(agent.repeatMode, 'all');
    expect(
      agent.command(
        commandId: '01900000-0000-7000-8000-000000000099',
        originDeviceId: 'client-a',
        action: const <String, dynamic>{'type': 'next'},
      )['expected_revision'],
      12,
    );
  });
}
