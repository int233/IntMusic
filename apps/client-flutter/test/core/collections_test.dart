import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/core/collections.dart';
import 'package:intmusic_client/core/network/core_api_client.dart';

JsonMap collectionSong(int id) => {
  'id': id,
  'release_identity_id': id,
  'title': 'Song $id',
  'artist_display': 'Artist',
  'album_title': 'Album',
  'album_id': 1,
  'year': 2020,
  'duration_ms': 180000,
  'is_favorite': false,
  'genres': ['流行'],
  'display_mode': 'inherit',
  'is_available': true,
};

class CollectionFixture {
  CollectionFixture(this.server, {this.count = 240});
  final HttpServer server;
  final int count;
  late final api = CoreApiClient(
    'http://${server.address.address}:${server.port}',
  );
  late final store = CollectionStore(persist: false);
  final requests = <String>[];
  int revision = 1;
  String version = 'v1';
  String epoch = 'epoch';
  bool breakPage = false;
  Completer<void>? pausePage;
  Completer<void>? pageStarted;
  JsonMap definition = {
    ...emptyCollection(),
    'name': 'My collection',
    'automatic': {'kind': 'all', 'conditions': []},
  };
  List<int>? members;
  List<int> get ids => members ?? List.generate(count, (i) => i + 1);
  JsonMap get summary => {
    'id': 1,
    'name': definition['name'],
    'description': '',
    'entity_type': definition['entity_type'],
    'system_key': null,
    'cover_album_id': null,
    'revision': revision,
    'result_version': version,
    'result_total': ids.length,
    'can_edit': true,
    'can_delete': true,
  };
  JsonMap get schema => {
    'types': [
      for (final type in ['track', 'album', 'artist', 'genre'])
        {
          'entity_type': type,
          'fields': [
            {
              'field': 'name',
              'label': '名称',
              'type': 'text',
              'operators': ['eq', 'contains'],
            },
            {
              'field': 'track_count',
              'label': '歌曲数量',
              'type': 'number',
              'operators': ['gte', 'lte', 'eq'],
            },
            {
              'field': 'genres',
              'label': '流派',
              'type': 'tags',
              'operators': ['eq', 'contains'],
            },
          ],
        },
    ],
  };
  JsonMap layout = {
    'revision': 1,
    'sections': [
      {
        'id': 'first',
        'collection_id': 1,
        'builtin': null,
        'title': null,
        'layout': 'list',
        'preview_count': 6,
        'width': 'wide',
        'hidden': false,
        'track_columns': ['artist', 'album', 'duration'],
      },
    ],
  };
  JsonMap envelope(JsonMap value) => {
    ...value,
    'server_id': 'server',
    'catalog_epoch': epoch,
  };
  List<JsonMap> entries(Iterable<int> ids) => [
    for (final id in ids)
      {
        'entity_id': id,
        'entity_type': 'track',
        'data': collectionSong(id),
        'reason': 'rule',
      },
  ];
  Future<void> start() async {
    server.listen((request) async {
      try {
        final path = request.uri.path.replaceFirst('/api/v1', '');
        requests.add('${request.method} $path');
        JsonMap body = {};
        if (request.method == 'POST' || request.method == 'PATCH') {
          body = Map<String, dynamic>.from(
            jsonDecode(await utf8.decoder.bind(request).join()) as Map,
          );
        }
        JsonMap result;
        if (request.method != 'GET') {
          expect(request.headers.value('x-intmusic-server-id'), 'server');
          expect(request.headers.value('x-intmusic-catalog-epoch'), epoch);
        }
        if (path == '/collections/rule-schema') {
          result = schema;
        } else if (path == '/settings/collections') {
          result = {'management_enabled': false, 'revision': 1};
        } else if (path == '/home-layout') {
          if (request.method == 'PATCH') {
            layout = {
              'revision': (layout['revision'] as int) + 1,
              'sections': body['sections'],
            };
          }
          result = layout;
        } else if (path == '/collections/preview') {
          result = {
            'matched_total': count,
            'result_total': body['automatic'] == null
                ? (body['included'] as List).length
                : count,
            'items': entries(ids.take(3)),
            'missing_members': [],
          };
        } else if (path.startsWith('/collections/entities/')) {
          final selected = request.uri.queryParameters['ids']
              ?.split(',')
              .map(int.parse);
          result = {
            'items': entries(selected ?? ids.take(50)),
            'total': ids.length,
            'next_offset': null,
          };
        } else if (path == '/collections/1/play') {
          final selected = (body['entity_ids'] as List?)?.cast<int>() ?? ids;
          result = {
            'source': {
              'collection_id': 1,
              'result_version': body['result_version'],
              'plan_id': 'plan',
              'name': 'My collection',
            },
            'tracks': selected.map(collectionSong).toList(),
            'missing_count': 0,
          };
        } else if (path == '/collections' && request.method == 'GET') {
          result = {
            'items': [summary],
          };
        } else {
          if (request.method == 'PATCH' || request.method == 'POST') {
            definition = Map<String, dynamic>.from(body['definition'] as Map);
            revision++;
            version = 'v$revision';
            members = definition['automatic'] == null
                ? (definition['included'] as List).cast<int>()
                : null;
          }
          final offset = int.parse(
            request.uri.queryParameters['offset'] ?? '0',
          );
          final limit = int.parse(request.uri.queryParameters['limit'] ?? '50');
          final values = ids.skip(offset).take(limit).toList();
          result = {
            'collection': summary,
            'definition': definition,
            'result_version': breakPage && offset > 0 ? 'wrong' : version,
            'generated_at': '2026-10-05T00:00:00Z',
            'matched_total': ids.length,
            'result_total': ids.length,
            'offset': offset,
            'next_offset': offset + values.length < ids.length
                ? offset + values.length
                : null,
            'items': entries(values),
            'missing_members': [],
          };
        }
        final data = jsonEncode(envelope(result));
        if (path == '/collections/1' &&
            request.method == 'GET' &&
            pausePage != null) {
          pageStarted?.complete();
          pageStarted = null;
          await pausePage!.future;
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(data);
        await request.response.close();
      } catch (e) {
        request.response.statusCode = 500;
        request.response.write('$e');
        await request.response.close();
      }
    });
    store.configure(api, {
      'server_id': 'server',
      'catalog_epoch': epoch,
      'capabilities': ['collections_v1'],
    });
    await Future<void>.delayed(Duration.zero);
    await store.refresh();
  }

  Future<void> close() async {
    store.dispose();
    api.close();
    await server.close(force: true);
  }

  static Future<CollectionFixture> create({int count = 240}) async {
    final f = CollectionFixture(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      count: count,
    );
    await f.start();
    return f;
  }
}

void main() {
  test(
    'one shared result cache pages beyond the home preview; playback uses the complete batch',
    () async {
      final f = await CollectionFixture.create();
      addTearDown(f.close);
      await Future.wait([f.store.load(1, count: 6), f.store.load(1, count: 6)]);
      expect(f.requests.where((p) => p == 'GET /collections/1').length, 1);
      final page = await f.store.load(1, count: 240);
      expect((page['items'] as List).length, 240);
      expect(page['next_offset'], null);
      final plan = await f.store.playPlan(1, 'v1');
      expect((plan['tracks'] as List).length, 240);
      expect((plan['source'] as Map)['result_version'], 'v1');
    },
  );
  test(
    'saving replaces visible results and settings independently of layout',
    () async {
      final f = await CollectionFixture.create();
      addTearDown(f.close);
      await f.store.load(1, count: 6);
      final observed = <int>[];
      f.store.addListener(() {
        final p = f.store.pages[1];
        if (p != null) observed.add((p['items'] as List).length);
      });
      await f.store.save(
        {
          ...emptyCollection(),
          'name': 'Fixed',
          'included': [3, 1],
        },
        id: 1,
        revision: 1,
      );
      expect(f.store.summary(1)?['name'], 'Fixed');
      expect(
        (f.store.pages[1]!['items'] as List).map(
          (v) => (v as Map)['entity_id'],
        ),
        [3, 1],
      );
      expect(observed, contains(2));
      expect(f.layout['revision'], 1);
    },
  );
  test('a delayed read cannot overwrite an acknowledged edit', () async {
    final f = await CollectionFixture.create();
    addTearDown(f.close);
    await f.store.load(1, count: 6);
    f.pausePage = Completer<void>();
    f.pageStarted = Completer<void>();
    final oldRead = f.store.load(1, fresh: true);
    await f.pageStarted!.future;
    final acknowledged = Completer<void>();
    f.store.addListener(() {
      if (f.store.summary(1)?['name'] == 'New choice' &&
          !acknowledged.isCompleted) {
        acknowledged.complete();
      }
    });
    final saving = f.store.save(
      {
        ...emptyCollection(),
        'name': 'New choice',
        'included': [9, 2],
      },
      id: 1,
      revision: 1,
    );
    await acknowledged.future;
    // The old reader is still blocked; acknowledged saves must already return.
    await saving.timeout(const Duration(seconds: 2));
    f.pausePage!.complete();
    await oldRead;
    await saving;
    expect(f.store.pages[1]!['result_version'], 'v2');
    expect(
      (f.store.pages[1]!['items'] as List).map((v) => (v as Map)['entity_id']),
      [9, 2],
    );
  });

  test(
    'mixed result versions are rejected instead of silently playing a partial list',
    () async {
      final f = await CollectionFixture.create();
      addTearDown(f.close);
      await f.store.load(1, count: 6);
      f.breakPage = true;
      await expectLater(f.store.load(1, count: 240), throwsStateError);
      expect((f.store.pages[1]!['items'] as List).length, 6);
    },
  );
  test(
    'a response from the previous Core epoch cannot populate the new catalog',
    () async {
      final f = await CollectionFixture.create();
      addTearDown(f.close);
      f.pausePage = Completer();
      f.pageStarted = Completer();
      final read = f.store.load(1);
      final rejected = expectLater(read, throwsStateError);
      await f.pageStarted!.future;
      f.epoch = 'replacement';
      f.store.configure(f.api, {
        'server_id': 'server',
        'catalog_epoch': f.epoch,
        'capabilities': ['collections_v1'],
      });
      f.pausePage!.complete();
      await rejected;
      expect(f.store.pages[1], null);
    },
  );
}
