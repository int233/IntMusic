import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/core/library_sync.dart';
import 'package:intmusic_client/core/serial_task_queue.dart';

void main() {
  const identity = CatalogIdentity('core-a', 'epoch-a');
  Map<String, dynamic> response(Map<String, dynamic> fields) => {
    'server_id': 'core-a',
    'catalog_epoch': 'epoch-a',
    for (final key in [
      'tracks',
      'albums',
      'artists',
      'collections',
      'library_roots',
      'client_library_roots',
      'client_file_bindings',
      'playback_history',
    ])
      key: <dynamic>[],
    'settings': <String, dynamic>{},
    'playback_stats': <String, dynamic>{},
    ...fields,
  };
  Future<LibrarySyncResult> sync(
    Future<Map<String, dynamic>> Function(String) get, {
    bool force = false,
  }) => fetchLibrarySnapshot(
    identity: identity,
    cursor: 10,
    deviceId: 'device/a & b',
    force: force,
    get: get,
  );

  test(
    'pending favorites survive downloads without changing ratings or other devices updates',
    () {
      final serverTracks = [
        {'id': 1, 'is_favorite': false, 'user_rating': 20},
        {'id': 2, 'is_favorite': true, 'title': 'Updated on device B'},
      ];
      final projected = projectPendingFavorites(serverTracks, {1: true});
      expect(projected[0]['is_favorite'], isTrue);
      expect(projected[0]['user_rating'], 20);
      expect(projected[1], serverTracks[1]);
      expect(serverTracks[0]['is_favorite'], isFalse);
      expect(projectPendingFavorites(serverTracks, {}), same(serverTracks));
    },
  );

  test('unchanged catalog avoids a snapshot', () async {
    var calls = 0;
    final result = await sync((_) async {
      calls++;
      return response({
        'cursor': 10,
        'requires_snapshot': false,
        'changes': [],
      });
    });
    expect(calls, 1);
    expect(result.snapshot, isNull);
    expect(result.detailKinds, isEmpty);
  });

  test(
    'a write between empty changes and cursor reads is not skipped',
    () async {
      final paths = <String>[];
      final result = await sync((path) async {
        paths.add(path);
        return response(
          path.contains('/changes')
              ? {'cursor': 11, 'requires_snapshot': false, 'changes': []}
              : {
                  'cursor': 11,
                  'tracks': [
                    {'id': 7},
                  ],
                },
        );
      });
      expect(result.snapshot?['tracks'], [
        {'id': 7},
      ]);
      expect(result.detailKinds, libraryDetailKinds);
      expect(
        Uri.parse(paths.last).queryParameters['device_id'],
        'device/a & b',
      );
    },
  );

  test(
    'cursor rollback forces a snapshot instead of accepting stale state',
    () async {
      final result = await sync(
        (path) async => response(
          path.contains('/changes')
              ? {'cursor': 3, 'requires_snapshot': false, 'changes': []}
              : {'cursor': 3, 'tracks': []},
        ),
      );
      expect(result.snapshot?['cursor'], 3);
      expect(result.detailKinds, libraryDetailKinds);
    },
  );

  test('change page truncation refreshes scopes outside the page', () async {
    final result = await sync(
      (path) async => response(
        path.contains('/changes')
            ? {
                'cursor': 900,
                'requires_snapshot': true,
                'changes': [
                  {
                    'cursor': 510,
                    'scope': 'tracks',
                    'reason': 'favorite updated',
                  },
                ],
              }
            : {'cursor': 900},
      ),
    );
    expect(result.detailKinds, libraryDetailKinds);
  });

  test(
    'fully covered favorite changes avoid unnecessary detail downloads',
    () async {
      final result = await sync(
        (path) async => response(
          path.contains('/changes')
              ? {
                  'cursor': 11,
                  'requires_snapshot': true,
                  'changes': [
                    {
                      'cursor': 11,
                      'scope': 'tracks',
                      'reason': 'favorite updated',
                    },
                  ],
                }
              : {'cursor': 11},
        ),
      );
      expect(result.snapshot, isNotNull);
      expect(result.detailKinds, isEmpty);
    },
  );

  for (final mismatch in [
    {'server_id': 'core-b'},
    {'catalog_epoch': 'rebuilt'},
    {'catalog_epoch': null},
  ]) {
    test('rejects changed or missing identity: $mismatch', () async {
      await expectLater(
        sync(
          (_) async => response({
            'cursor': 10,
            'requires_snapshot': false,
            'changes': [],
            ...mismatch,
          }),
        ),
        throwsStateError,
      );
      await expectLater(
        sync((_) async => response({'cursor': 11, ...mismatch}), force: true),
        throwsStateError,
      );
    });
  }

  for (final code in [404, 500, 503]) {
    test(
      'HTTP $code propagates without falling back to legacy endpoints',
      () async {
        var calls = 0;
        await expectLater(
          sync((_) async {
            calls++;
            throw HttpException('HTTP $code: failure');
          }),
          throwsA(isA<HttpException>()),
        );
        expect(calls, 1);
      },
    );
  }

  test('incomplete snapshot cannot erase the local catalog', () async {
    await expectLater(
      sync((_) async => response({'cursor': 11, 'tracks': null}), force: true),
      throwsFormatException,
    );
  });

  test('suspended detail download resumes from its last saved page', () async {
    var active = true;
    var after = 0;
    final completedFlags = <bool>[];
    Future<Map<String, dynamic>> load(int cursor) async => {
      'next_after_id': cursor + 100,
      'has_more': cursor == 0,
    };
    Future<void> save(Map<String, dynamic> _, int next, bool done) async {
      after = next;
      completedFlags.add(done);
      active = false;
    }

    expect(
      await syncLibraryDetailPages(
        afterId: after,
        canContinue: () => active,
        load: load,
        save: save,
      ),
      isFalse,
    );
    expect(after, 100);
    expect(completedFlags, [false]);
    active = true;
    expect(
      await syncLibraryDetailPages(
        afterId: after,
        canContinue: () => active,
        load: load,
        save: (_, next, done) async {
          after = next;
          completedFlags.add(done);
        },
      ),
      isTrue,
    );
    expect(after, 200);
    expect(completedFlags, [false, true]);
  });

  test('response from a superseded session is never saved', () async {
    var current = true;
    final pending = Completer<Map<String, dynamic>>();
    final started = Completer<void>();
    var saved = false;
    final operation = syncLibraryDetailPages(
      afterId: 0,
      canContinue: () => current,
      load: (_) {
        started.complete();
        return pending.future;
      },
      save: (_, _, _) async {
        saved = true;
      },
    );
    await started.future;
    current = false;
    pending.complete({'next_after_id': 1, 'has_more': false});
    expect(await operation, isFalse);
    expect(saved, isFalse);
  });

  test('nonadvancing detail pages fail without declaring completion', () async {
    await expectLater(
      syncLibraryDetailPages(
        afterId: 100,
        canContinue: () => true,
        load: (_) async => {'next_after_id': 100, 'has_more': true},
        save: (_, _, _) async => fail('Invalid page must not be saved'),
      ),
      throwsFormatException,
    );
  });

  test(
    'queued removal waits for scan and later tasks survive scan failure',
    () async {
      final queue = SerialTaskQueue();
      final gate = Completer<void>();
      final events = <String>[];
      final scan = queue.run(() async {
        events.add('scan');
        await gate.future;
        throw StateError('connection lost');
      });
      final failed = expectLater(scan, throwsStateError);
      final removal = queue.run(() async {
        events.add('remove');
      });
      final rescan = queue.run(() async {
        events.add('rescan');
      });
      await Future<void>.delayed(Duration.zero);
      expect(events, ['scan']);
      gate.complete();
      await Future.wait([failed, removal, rescan]);
      expect(events, ['scan', 'remove', 'rescan']);
    },
  );
}
