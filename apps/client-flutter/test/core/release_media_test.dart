import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/core/release_media.dart';

Map<String, dynamic> releaseFixture() => {
  'related_release_tracks': [
    {
      'release_identity_id': 1,
      'release_track_id': 1,
      'legacy_track_id': 10,
      'is_current': true,
      'release': {'title': 'Lover', 'year': 2019},
    },
    {
      'release_identity_id': 1,
      'release_track_id': 2,
      'legacy_track_id': 20,
      'release': {'title': 'Lover'},
    },
    {
      'release_identity_id': 3,
      'release_track_id': 3,
      'legacy_track_id': 30,
      'release': {'title': 'The Eras Tour', 'year': 2023},
    },
  ],
  'variants': [
    {
      'id': 100,
      'release_track_ids': [1],
      'codec': 'flac',
      'replicas': [
        {
          'file_id': 1,
          'device_name': 'LabPC',
          'source_kind': 'core',
          'availability_state': 'ready',
          'presence_state': 'available',
        },
      ],
    },
    {
      'id': 200,
      'release_track_ids': [2],
      'codec': 'm4a',
      'replicas': [
        {
          'file_id': 2,
          'device_name': 'Mate80PM',
          'source_kind': 'client',
          'availability_state': 'ready',
          'online_until': '2000-01-01T00:00:00Z',
        },
      ],
    },
    {
      'id': 300,
      'release_track_ids': [3],
      'codec': 'flac',
      'replicas': [
        {
          'file_id': 3,
          'device_name': 'LabPC',
          'source_kind': 'core',
          'availability_state': 'ready',
          'presence_state': 'available',
        },
      ],
    },
    {
      'id': 400,
      'release_track_ids': [1],
      'codec': 'flac',
      'replicas': [],
    },
    {
      'id': 500,
      'release_track_ids': [999],
      'replicas': [
        {'file_id': 5},
      ],
    },
  ],
};

void main() {
  test(
    'album cards combine encodings and devices, never distinct editions',
    () {
      final groups = groupReleaseMedia(releaseFixture());
      expect(groups.map((g) => g.release['title']), ['Lover', 'The Eras Tour']);
      expect(groups[0].copies.map((c) => c['file_id']), [1, 2]);
      expect(groups[1].copies.map((c) => c['file_id']), [3]);
      expect(groups.first.trackId, 10);
    },
  );
  test('unbound local copy cannot be guessed into a preferred edition', () {
    final groups = groupReleaseMedia(
      releaseFixture(),
      localCopy: {'file_id': 90, 'media_variant_id': 900},
    );
    expect(groups.expand((g) => g.copies).length, 3);
    final bound = groupReleaseMedia(
      releaseFixture(),
      localCopy: {'file_id': 90, 'media_variant_id': 300},
    );
    expect(bound.first.copies.length, 2);
    expect(bound.last.copies.map((c) => c['file_id']), [3, 90]);
  });
  test(
    'inventory readiness cannot keep a device available after lease expiry',
    () {
      final copy = {
        'source_kind': 'client',
        'availability_state': 'ready',
        'online_until': '2026-10-04T01:00:00Z',
      };
      expect(
        replicaPresence(
          copy,
          coreConnected: true,
          now: DateTime.utc(2026, 10, 4, 0, 59),
        ),
        'available',
      );
      expect(
        replicaPresence(
          copy,
          coreConnected: true,
          now: DateTime.utc(2026, 10, 4, 1, 1),
        ),
        'offline',
      );
      expect(replicaPresence(copy, coreConnected: false), 'offline');
      expect(
        replicaPresence({
          ...copy,
          'local_verified': true,
        }, coreConnected: false),
        'available',
      );
      expect(
        replicaPresence({
          ...copy,
          'local_verified': true,
          'availability_state': 'missing',
        }, coreConnected: false),
        'missing',
      );
    },
  );
}
