import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/core/collections.dart';
import 'package:intmusic_client/intmusic_client.dart';
import 'core/collections_test.dart' show collectionSong;

class _WidgetStore extends CollectionStore {
  _WidgetStore() : super(persist: false) {
    online = true;
    items = [
      {
        'id': 1,
        'name': '通勤',
        'entity_type': 'track',
        'revision': 1,
        'result_version': 'batch',
        'result_total': total,
        'can_edit': true,
      },
    ];
    schema = {
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
            ],
          },
      ],
    };
    layout = {
      'revision': 1,
      'sections': [
        {
          'id': 'first',
          'collection_id': 1,
          'title': null,
          'layout': 'list',
          'preview_count': 6,
          'width': 'wide',
          'hidden': false,
          'track_columns': ['artist', 'album', 'duration'],
        },
      ],
    };
    pages[1] = {
      'collection': items.first,
      'definition': emptyCollection(),
      'result_version': 'batch',
      'result_total': total,
      'next_offset': 6,
      'items': [
        for (var i = 1; i <= 6; i++)
          {'entity_id': i, 'entity_type': 'track', 'data': collectionSong(i)},
      ],
    };
  }
  void renameHomeSection(String title) {
    (layout['sections'] as List).first['title'] = title;
    notifyListeners();
  }

  final int total = 240;
  @override
  Future<JsonMap> load(int id, {int count = 50, bool fresh = false}) async =>
      pages[id]!;
  @override
  Future<JsonMap> preview(JsonMap definition) async => {
    'result_total': 0,
    'matched_total': 0,
    'missing_members': [],
    'items': [],
  };
  @override
  Future<JsonMap> playPlan(
    int id,
    String version, {
    List<int>? entityIds,
  }) async => {
    'source': {'plan_id': 'plan'},
    'tracks': [for (var i = 1; i <= total; i++) collectionSong(i)],
  };
}

void main() {
  testWidgets('home sections update in place on phone and desktop', (
    tester,
  ) async {
    final store = _WidgetStore();
    addTearDown(store.dispose);
    for (final width in [390.0, 1200.0]) {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: collectionHomeForTesting(store))),
      );
      await tester.pumpAndSettle();
      expect(find.text('编辑首页'), findsOneWidget);
      expect(find.text('Song 6'), findsOneWidget);
      expect(find.text('Song 7'), findsNothing);
      store.renameHomeSection('我的首页');
      await tester.pumpAndSettle();
      expect(find.text('我的首页'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  testWidgets('collection editor and home layout fit phone and desktop', (
    tester,
  ) async {
    final store = _WidgetStore();
    addTearDown(store.dispose);
    for (final width in [390.0, 1200.0]) {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: collectionEditorForTesting(store))),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      expect(find.text('新建集合'), findsOneWidget);
      expect(find.text('指定内容 · 0'), findsOneWidget);
      expect(find.text('自动筛选'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '通勤歌单');
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      expect(find.text('通勤歌单'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: homeLayoutEditorForTesting(store))),
      );
      await tester.pumpAndSettle();
      expect(find.text('编辑首页'), findsOneWidget);
      expect(find.text('关联已有集合'), findsOneWidget);
      expect(find.text('创建集合并展示'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  testWidgets(
    'direct collection list plays the whole plan with only six preview rows cached',
    (tester) async {
      final store = _WidgetStore();
      addTearDown(store.dispose);
      List<dynamic>? played;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: collectionPageForTesting(
              store,
              onPlay: (_, tracks, source) async {
                played = tracks;
                expect(source?['plan_id'], 'plan');
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('播放全部'));
      await tester.pumpAndSettle();
      expect(played?.length, 240);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
