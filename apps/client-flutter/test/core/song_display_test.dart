import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/core/song_display.dart';

Map<String, dynamic> song(
  int id, {
  String? group = 'taylor:cruel summer',
  String mode = 'inherit',
  bool available = true,
}) => {
  'id': id,
  'release_identity_id': id,
  'title': 'Cruel Summer',
  'artist_display': 'Taylor Swift',
  'display_group_key': group,
  'display_mode': mode,
  'is_available': available,
  'album_title': id == 1 ? 'Lover' : 'The Eras Tour',
  'duration_ms': 178000,
};

void main() {
  test(
    'immediate edition edits survive stale snapshots and detail caches',
    () async {
      final state = SongDisplayState();
      addTearDown(state.dispose);
      final lover = {...song(1), 'release_identity_id': 10};
      final copy = {...song(3), 'release_identity_id': 10};
      final tour = {...song(2), 'release_identity_id': 20};
      state.updateCatalog([lover, copy, tour], cursor: 0);
      final response = Completer<Map<String, dynamic>>();
      final save = state.setMode(lover, 'independent', () => response.future);
      expect(state.project(copy)['display_mode'], 'independent');
      expect(state.project(tour)['display_mode'], 'inherit');
      state.updateCatalog([lover, copy, tour], cursor: 0);
      expect(state.project(copy)['display_mode'], 'independent');
      response.complete({'cursor': 1});
      await save;
      state.updateCatalog([lover, copy, tour], cursor: 0);
      expect(state.project(copy)['display_mode'], 'independent');
      state.updateCatalog([
        {...lover, 'display_mode': 'independent'},
        {...copy, 'display_mode': 'independent'},
        tour,
      ], cursor: 1);
      expect(state.project(lover)['display_mode'], 'independent');
      // A later change on another device is authoritative after acknowledgement.
      state.updateCatalog([lover, copy, tour], cursor: 2);
      expect(state.project(lover)['display_mode'], 'inherit');
    },
  );
  test(
    'failed saves roll back and rapid choices are written in submission order',
    () async {
      final state = SongDisplayState();
      addTearDown(state.dispose);
      final track = song(1);
      state.updateCatalog([track], cursor: 0);
      final first = Completer<Map<String, dynamic>>();
      final calls = <String>[];
      final a = state.setMode(track, 'independent', () {
        calls.add('independent');
        return first.future;
      });
      final b = state.setMode(track, 'merged', () async {
        calls.add('merged');
        throw StateError('offline');
      });
      final failed = expectLater(b, throwsStateError);
      expect(state.project(track)['display_mode'], 'merged');
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['independent']);
      first.complete({'cursor': 1});
      await a;
      await failed;
      expect(calls, ['independent', 'merged']);
      expect(state.project(track)['display_mode'], 'independent');
      await expectLater(
        state.setMode(
          track,
          'inherit',
          () async => throw StateError('offline'),
        ),
        throwsStateError,
      );
      expect(state.project(track)['display_mode'], 'independent');
    },
  );
  test('a catalog reset discards in-flight edit results', () async {
    final state = SongDisplayState();
    addTearDown(state.dispose);
    final track = song(1);
    final response = Completer<Map<String, dynamic>>();
    final save = state.setMode(track, 'independent', () => response.future);
    await Future<void>.delayed(Duration.zero);
    state.reset();
    state.updateCatalog([track], cursor: 0);
    response.complete({'cursor': 1});
    await save;
    expect(state.project(track)['display_mode'], 'inherit');
  });

  test(
    'newer remote changes win even when the intermediate snapshot was missed',
    () async {
      final state = SongDisplayState();
      addTearDown(state.dispose);
      final track = song(1);
      state.updateCatalog([track], cursor: 10);
      await state.setMode(track, 'independent', () async => {'cursor': 11});
      // Another device changes it before we ever download our own saved value.
      state.updateCatalog([
        {...track, 'display_mode': 'merged'},
      ], cursor: 12);
      expect(state.project(track)['display_mode'], 'merged');
      state.updateCatalog([track], cursor: 10);
      expect(state.project(track)['display_mode'], 'merged');
    },
  );
  test(
    'snapshot received before the save response is already authoritative',
    () async {
      final state = SongDisplayState();
      addTearDown(state.dispose);
      final track = song(1);
      final response = Completer<Map<String, dynamic>>();
      final save = state.setMode(track, 'independent', () => response.future);
      state.updateCatalog([
        {...track, 'display_mode': 'merged'},
      ], cursor: 12);
      response.complete({'cursor': 11});
      await save;
      expect(state.project(track)['display_mode'], 'merged');
    },
  );
  test('projection keeps album metadata and selects an available version', () {
    final a = song(1, available: false);
    final b = song(2);
    final grouped = projectSongList([a, b], mergeSameName: true);
    expect(grouped.single['id'], 2);
    expect(grouped.single['album_title'], 'The Eras Tour');
    expect((grouped.single['_display_members'] as List).map((t) => t['id']), [
      1,
      2,
    ]);
    expect(a.containsKey('_display_members'), isFalse);
    expect(projectSongList([a, b], mergeSameName: false).length, 2);
  });
  test(
    'independent overrides global merge; artists and missing identity remain separate',
    () {
      final tracks = [
        song(1),
        song(2, mode: 'independent'),
        song(3, group: 'other artist'),
        song(4, group: null),
        song(5, group: null),
      ];
      expect(projectSongList(tracks, mergeSameName: true).length, 5);
      expect(
        projectSongList(
          tracks,
          mergeSameName: true,
          filter: 'independent',
        ).single['id'],
        2,
      );
      expect(
        projectSongList([
          song(1, mode: 'merged'),
          song(2, mode: 'merged'),
        ], mergeSameName: false).length,
        1,
      );
    },
  );
  test('ungrouped queue occurrences remain distinct and sorting is stable', () {
    final repeated = [song(1), song(1), song(2)];
    expect(
      projectSongList(repeated, mergeSameName: false).map((t) => t['id']),
      [1, 1, 2],
    );
    expect(
      projectSongList(
        repeated,
        mergeSameName: false,
        sortByMode: true,
      ).map((t) => t['id']),
      [1, 1, 2],
    );
  });
}
