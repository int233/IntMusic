import 'dart:async';
import 'package:intmusic_client/core/song_display.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/intmusic_client.dart';
import 'core/song_display_test.dart' show song;

void main() {
  testWidgets(
    'all global presentation controls live in settings on phone and desktop',
    (tester) async {
      for (final width in [390.0, 1200.0]) {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        final settings = <String, dynamic>{
          'merge_same_name': true,
          'attribute_filter': 'all',
          'sort_by_mode': false,
        };
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) => songDisplaySettingsForTesting(
                  settings: Map.of(settings),
                  onChanged: (changes) async =>
                      setState(() => settings.addAll(changes)),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('合并同名歌曲'), findsOneWidget);
        expect(find.text('所有展示属性'), findsOneWidget);
        expect(find.text('按展示属性排序'), findsOneWidget);
        await tester.tap(
          find.descendant(
            of: find.byKey(const Key('merge-same-name-setting')),
            matching: find.byType(Switch),
          ),
        );
        await tester.pumpAndSettle();
        expect(settings['merge_same_name'], false);
        await tester.tap(find.byType(DropdownButtonFormField<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('独立展示').last);
        await tester.pumpAndSettle();
        expect(settings['attribute_filter'], 'independent');
        await tester.tap(
          find.descendant(
            of: find.byKey(const Key('sort-display-mode-setting')),
            matching: find.byType(Switch),
          ),
        );
        await tester.pumpAndSettle();
        expect(settings['sort_by_mode'], true);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    },
  );

  testWidgets('grouped queue retains occurrence IDs for play and removal', (
    tester,
  ) async {
    String? removed;
    String? played;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: responsiveQueueForTesting(
            [
              {'id': 'first', 'track': song(1)},
              {'id': 'second', 'track': song(2)},
              {'id': 'repeat', 'track': song(1)},
            ],
            mergeSameName: true,
            currentIndex: 1,
            onRemove: (id) async {
              removed = id;
              return null;
            },
            onPlay: (id, _) async {
              played = id;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('移除此项').last);
    await tester.pump();
    expect(removed, 'repeat');
    await tester.tap(find.textContaining('The Eras Tour'));
    await tester.pump();
    expect(played, 'second');
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'playlist collapse, play-all and per-edition choice work on phone and desktop',
    (tester) async {
      for (final width in [390.0, 1200.0]) {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        final displayState = SongDisplayState();
        final saved = Completer<void>();
        List<int>? played;
        (int, String)? choice;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: songDisplayPlaylistForTesting(
                [song(1), song(2)],
                displayState: displayState,
                onPlay: (ids, _) async => played = ids,
                onMode: (id, mode) async {
                  choice = (id, mode);
                  await saved.future;
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Cruel Summer'), findsOneWidget);
        expect(find.text('2版'), findsOneWidget);
        expect(find.text('合并同名歌曲'), findsNothing);
        expect(find.text('所有展示属性'), findsNothing);
        expect(find.text('按展示属性排序'), findsNothing);
        await tester.tap(find.text('播放全部').first);
        await tester.pump();
        expect(played, [1]);
        await tester.tap(find.text('2版'));
        await tester.pumpAndSettle();
        expect(find.text('Lover'), findsOneWidget);
        expect(find.text('The Eras Tour'), findsOneWidget);
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('display-mode-1')),
            matching: find.text('独立展示'),
          ),
        );
        await tester.pumpAndSettle();
        expect(choice, (1, 'independent'));
        expect(find.text('Cruel Summer · 展示方式'), findsOneWidget);
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        // The save is still pending: the existing page must already have split.
        expect(saved.isCompleted, isFalse);
        expect(find.text('Cruel Summer'), findsNWidgets(2));
        expect(find.text('2版'), findsNothing);
        saved.complete();
        await tester.pumpAndSettle();
        expect(find.text('Cruel Summer'), findsNWidgets(2));
        displayState.updateCatalog([song(1), song(2)], cursor: 2);
        await tester.pumpAndSettle();
        expect(find.text('Cruel Summer'), findsOneWidget);
        expect(find.text('2版'), findsOneWidget);
        // Even a stale detail page now merges again without rebuilding its data.
        await displayState.setMode(
          song(1),
          'merged',
          () async => {'cursor': 3},
        );
        await tester.pumpAndSettle();
        expect(find.text('Cruel Summer'), findsOneWidget);
        expect(find.text('2版'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        displayState.dispose();
      }
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    },
  );
}
