import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/core/collections.dart';
import 'package:intmusic_client/core/local_library_projection.dart';
import 'package:intmusic_client/core/library_repository.dart';
import 'package:intmusic_client/core/network/core_api_client.dart';
import 'package:intmusic_client/core/storage/client_cache_database.dart';
import 'package:intmusic_client/core/playback/renderer_session.dart';
import 'package:intmusic_client/intmusic_client.dart'
    show playDeviceFileForTesting;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'collections_test.dart' show CollectionFixture, collectionSong;
import 'renderer_session_test.dart' show FakeEngine;

class _FileEngine extends FakeEngine {
  String? openedPath;
  bool? openedLocally;
  @override
  Future<void> open(String uri, {bool localFile = false}) async {
    openedPath = uri;
    openedLocally = localFile;
    await super.open(uri, localFile: localFile);
  }
}

void main() {
  late Directory directory;
  late ClientLibraryDatabase database;
  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp(
      'intmusic-local-library-',
    );
    database = ClientLibraryDatabase(
      path: '${directory.path}/cache/library.sqlite3',
      factory: databaseFactoryFfi,
    );
  });
  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  test(
    'home and unopened collection results survive a database cold start',
    () async {
      final fixture = await CollectionFixture.create(
        count: 241,
        database: database,
      );
      final layout = fixture.store.layout;
      expect(fixture.store.complete, isTrue, reason: fixture.store.error);
      await fixture.store.persisted;
      await fixture.close();
      await database.close();

      final restored = CollectionStore(database: database);
      final unreachable = CoreApiClient('http://127.0.0.1:1');
      restored.configure(unreachable, {
        'server_id': 'server',
        'catalog_epoch': 'epoch',
        'capabilities': ['collections_v1'],
      });
      await restored.ready;
      expect(restored.items.single['name'], 'My collection');
      expect(restored.layout, layout);
      expect(restored.complete, isTrue);
      // A pending background connection must not delay reading durable results.
      final page = await restored
          .load(1)
          .timeout(const Duration(milliseconds: 200));
      expect((page['items'] as List).length, 241);
      expect((restored.localPlayPlan(1, 'v1')['tracks'] as List).length, 241);
      restored.dispose();
      unreachable.close();
    },
  );

  test(
    'database upgrade imports saved collection caches before offline readers switch',
    () async {
      final sql = await database.open();
      await sql.insert('sync_state', {
        'core_url': 'http://core:49338',
        'server_id': 'server',
        'catalog_epoch': 'epoch',
      });
      await sql.setVersion(1);
      await database.close();
      final hash = sha256.convert(
        utf8.encode('http://core:49338|server|epoch'),
      );
      final file = File('${directory.path}/collections/$hash.json');
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'items': [
            {'id': 9, 'name': 'Saved collection'},
          ],
        }),
      );
      final imported = await database.readDocument(
        'collections',
        'catalog:server:epoch',
      );
      expect((imported!['items'] as List).single['name'], 'Saved collection');
    },
  );

  test(
    'HTTP 500 refresh retains the complete last committed collection',
    () async {
      final fixture = await CollectionFixture.create(database: database);
      addTearDown(fixture.close);
      final previous = fixture.store.pages[1];
      fixture.unavailable = true;
      await fixture.store.refresh();
      expect(fixture.store.online, isFalse);
      expect(fixture.store.pages[1], same(previous));
      expect(fixture.store.complete, isTrue, reason: fixture.store.error);
      expect((await fixture.store.load(1))['items'], previous!['items']);
    },
  );

  test(
    'offline reads and refresh requests use the same cache without network access',
    () async {
      final fixture = await CollectionFixture.create(database: database);
      addTearDown(fixture.close);
      fixture.store.markUnavailable();
      fixture.requests.clear();
      final before = fixture.store.pages[1];
      await fixture.store.refresh();
      expect(await fixture.store.load(1, fresh: true), same(before));
      expect(fixture.requests, isEmpty);
      expect(fixture.store.complete, isTrue);
    },
  );

  test(
    'catalog identity persists across endpoint changes and isolates replacement epochs',
    () async {
      final key = await database.bindCatalog(
        'http://old:49338',
        'server',
        'epoch',
      );
      final sql = await database.open();
      await sql.insert('sync_state', {
        'core_url': key,
        'server_id': 'server',
        'catalog_epoch': 'epoch',
        'cursor': 10,
      });
      await database.writeDocument('collections', key, {
        'items': [1, 2],
      });
      expect(
        await database.bindCatalog('http://new:49338', 'server', 'epoch'),
        key,
      );
      await database.close();
      expect(await database.resolveEndpoint('http://new:49338'), key);
      expect(await database.readDocument('collections', key), {
        'items': [1, 2],
      });
      final replacement = await database.bindCatalog(
        'http://new:49338',
        'server',
        'replacement',
      );
      expect(replacement, isNot(key));
      expect(await database.readDocument('collections', replacement), isNull);
      expect(await database.readDocument('collections', key), isNotNull);
    },
  );

  test(
    'catalog and search are readable after restart with no Core requests',
    () async {
      final repository = ClientLibraryRepository(database);
      await repository.replaceSnapshot('http://core:49338', {
        'server_id': 'server',
        'catalog_epoch': 'epoch',
        'cursor': 42,
        'tracks': [collectionSong(1), collectionSong(2)],
        'albums': [
          {'id': 1, 'title': 'Album'},
        ],
        'artists': [
          {'id': 1, 'name': 'Artist'},
        ],
        'collections': [
          {'id': 9, 'name': 'My collection'},
        ],
      });
      await database.close();
      final cold = ClientLibraryRepository(database);
      final library = await cold.load('http://core:49338');
      expect(library.serverId, 'server');
      expect(library.cursor, 42);
      expect((library.values['tracks'] as List).length, 2);
      expect((library.values['albums'] as List).single['title'], 'Album');
      expect((library.values['artists'] as List).single['name'], 'Artist');
      expect(
        (library.values['collections'] as List).single['name'],
        'My collection',
      );
      final found = await cold.search('http://core:49338', 'Song 2');
      expect((found['tracks'] as List).single['id'], 2);
      // Changing the address while offline must not hide the saved library.
      final moved = await cold.load('http://new-address:49338');
      expect(moved.serverId, 'server');
      expect((moved.values['tracks'] as List).length, 2);
    },
  );

  test(
    'failed replacement rolls back both catalog contents and endpoint identity',
    () async {
      final repository = ClientLibraryRepository(database);
      await repository.replaceSnapshot('http://core:49338', {
        'server_id': 'server',
        'catalog_epoch': 'old',
        'cursor': 42,
        'tracks': [collectionSong(1)],
      });
      final sql = await database.open();
      await sql.execute(
        "CREATE TRIGGER fail_replacement BEFORE INSERT ON catalog_entities "
        "WHEN NEW.entity_id = 2 BEGIN SELECT RAISE(ABORT, 'simulated disk write failure'); END",
      );
      await expectLater(
        repository.replaceSnapshot('http://core:49338', {
          'server_id': 'server',
          'catalog_epoch': 'new',
          'cursor': 43,
          'tracks': [collectionSong(2)],
        }),
        throwsA(isA<DatabaseException>()),
      );
      await database.close();
      final cold = await ClientLibraryRepository(
        database,
      ).load('http://core:49338');
      expect(cold.catalogEpoch, 'old');
      expect(cold.cursor, 42);
      expect((cold.values['tracks'] as List).single['id'], 1);
    },
  );

  test(
    'album and artist collections retain playback filters, ordering and deduplication offline',
    () async {
      final store = CollectionStore(persist: false);
      addTearDown(store.dispose);
      store.updateCatalog([
        collectionSong(1),
        collectionSong(2),
        collectionSong(3),
      ]);
      store.pages[1] = {
        'result_version': 'batch',
        'next_offset': null,
        'items': [
          {
            'entity_id': 10,
            'entity_type': 'album',
            'playback_track_ids': [3, 1],
          },
          {
            'entity_id': 20,
            'entity_type': 'artist',
            'playback_track_ids': [1, 2],
          },
        ],
      };
      final all = store.localPlayPlan(1, 'batch');
      expect((all['tracks'] as List).map((t) => t['id']), [3, 1, 2]);
      final selected = store.localPlayPlan(1, 'batch', entityIds: [20]);
      expect((selected['tracks'] as List).map((t) => t['id']), [1, 2]);
      store.pages[2] = {
        'items': [
          {
            'entity_id': 90,
            'entity_type': 'genre',
            'data': {'id': 90, 'name': '流行'},
          },
        ],
      };
      expect((store.localGenreDetail(90)!['tracks'] as List).length, 3);
      store.hasSnapshot = true;
      store.items = [
        {'id': 2, 'result_version': 'genre'},
      ];
      store.pages[2]!['result_version'] = 'genre';
      expect(store.complete, isFalse);
      (store.pages[2]!['items'] as List).single['playback_track_ids'] = [
        1,
        2,
        3,
      ];
      expect(store.complete, isTrue);
    },
  );

  test(
    'inspected device file metadata is usable without a Core song ID',
    () async {
      final id = localLibraryId('file:root/song.flac');
      expect(id, lessThan(0));
      await database.writeDocument('device', 'media-index', {
        'copies': [
          {
            'track_id': id,
            'relative_path': 'song.flac',
            'metadata': {
              'title': '本地歌曲',
              'album': '本地专辑',
              'track_artists': ['艺术家'],
            },
          },
        ],
      });
      await database.close();
      final saved = await database.readDocument('device', 'media-index');
      final track = localFileTrack(
        Map<String, dynamic>.from((saved!['copies'] as List).single),
      );
      expect(track['title'], '本地歌曲');
      expect(track['artist_display'], '艺术家');
      expect(track['id'], id);
      expect(track['is_available'], isTrue);
    },
  );

  test(
    'local file reaches the decoder without any Core projection or assigned song ID',
    () async {
      final file = File.fromUri(directory.uri.resolve('local.flac'));
      await file.writeAsBytes([1, 2, 3]);
      final engine = _FileEngine();
      final player = RendererSession(createEngine: () async => engine);
      addTearDown(player.dispose);
      final playback = await playDeviceFileForTesting(file.path, player);
      expect(playback['state'], 'playing');
      expect(engine.openedPath, file.path);
      expect(engine.openedLocally, isTrue);
      expect(player.snapshot.phase, RendererPhase.playing);
    },
  );
}
