import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/core/song_display.dart';
import 'package:intmusic_client/intmusic_client.dart';
import 'core/song_display_test.dart' show song;
import 'core/release_media_test.dart' show releaseFixture;

Map<String, dynamic> detail(int id) => {
  'track': song(id),
  'genres': ['国语', '流行'],
  'lyrics': {
    'kind': 'lrc',
    'text': '[ti:Song]\n[00:01.00]First line\n[00:02.00]Second line',
  },
  'media': releaseFixture(),
};

void main() {
  testWidgets(
    'all editions survive global filtering; modes belong to edition menus',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final tracks = [song(1), song(2)];
      final state = SongDisplayState()..updateCatalog(tracks, cursor: 0);
      addTearDown(state.dispose);
      int? opened, played;
      String? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: responsiveTrackDetailForTesting(
              detail(1),
              catalog: tracks,
              displayState: state,
              settings: {
                'merge_same_name': false,
                'attribute_filter': 'independent',
              },
              onOpen: (id) async => opened = id,
              onPlay: (id) async => played = id,
              onMode: (id, mode) => state.setMode(
                tracks.firstWhere((t) => t['id'] == id),
                mode,
                () async {
                  saved = mode;
                  return {'cursor': 1};
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2 个专辑收录 · 同一艺术家的同名歌曲'), findsOneWidget);
      expect(find.text('跟随设置'), findsNothing);
      expect(find.text('The Eras Tour'), findsOneWidget);
      await tester.tap(find.text('The Eras Tour'));
      expect(opened, 2);
      await tester.tap(find.byTooltip('播放此收录').last);
      expect(played, 2);
      await tester.tap(find.byTooltip('收录选项').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckedPopupMenuItem<String>));
      await tester.pumpAndSettle();
      expect(saved, 'independent');
      expect(find.text('列表中独立展示'), findsOneWidget);
      expect(find.text('The Eras Tour'), findsOneWidget);
      expect(find.text('2 个文件来源 · 0 个可用'), findsOneWidget);
      final lyric = tester.widget<SelectableText>(
        find.byKey(const Key('song-lyrics-text')),
      );
      expect(lyric.data, 'First line\nSecond line');
      await tester.tap(find.text('原始文本'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SelectableText>(find.byKey(const Key('song-lyrics-text')))
            .data,
        contains('[00:01.00]'),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a known edition never borrows another edition file list', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: responsiveTrackDetailForTesting(
            detail(2),
            catalog: [song(1), song(2)],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('LabPC'), findsNothing);
    expect(find.text('Mate80PM'), findsNothing);
    expect(find.text('尚未关联文件来源'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('late media response cannot replace the newly selected edition', (
    tester,
  ) async {
    final first = Completer<Map<String, dynamic>>();
    final second = Completer<Map<String, dynamic>>();
    var selected = 1;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return responsiveTrackDetailForTesting(
                {...detail(selected), 'media': null},
                catalog: [song(1), song(2)],
                loadMedia: (id) => id == 1 ? first.future : second.future,
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    update(() => selected = 2);
    await tester.pump();
    second.complete({
      'related_release_tracks': [
        {
          'release_identity_id': 2,
          'release_track_id': 2,
          'is_current': true,
          'release': {'title': 'The Eras Tour'},
        },
      ],
      'variants': [
        {
          'id': 2,
          'release_track_ids': [2],
          'replicas': [
            {
              'file_id': 22,
              'device_name': 'New source',
              'source_kind': 'core',
              'presence_state': 'available',
              'availability_state': 'ready',
            },
          ],
        },
      ],
    });
    await tester.pumpAndSettle();
    first.complete(releaseFixture());
    await tester.pumpAndSettle();
    expect(find.text('New source'), findsOneWidget);
    expect(find.text('LabPC'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('detail remains readable at A306 widths and large text', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final width in [240.0, 360.0, 900.0]) {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: Scaffold(
            body: responsiveTrackDetailForTesting(
              detail(1),
              catalog: [song(1), song(2)],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'width $width');
      await tester.drag(find.byType(ListView).first, const Offset(0, -700));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'scrolled width $width');
      await tester.pumpWidget(const SizedBox());
    }
  });
}
