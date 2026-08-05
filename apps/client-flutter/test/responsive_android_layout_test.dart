import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/intmusic_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const resolutions = <(Size, double)>[
    (Size(720, 1280), 2),
    (Size(1080, 1920), 2.5),
  ];

  Future<void> configureResolution(
    WidgetTester tester,
    Size physicalSize,
    double devicePixelRatio,
  ) async {
    tester.view.physicalSize = physicalSize;
    tester.view.devicePixelRatio = devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget surface(Widget child) => MaterialApp(
    theme: ThemeData.dark(useMaterial3: true),
    home: Scaffold(body: child),
  );

  Map<String, dynamic> track(int id, String title) => <String, dynamic>{
    'id': id,
    'title': title,
    'artist_display': 'A very long artist name for a narrow Android screen',
    'album_title': 'A very long album title that must remain readable',
    'duration_ms': 255000,
    'year': 2004,
    'is_favorite': id.isEven,
    '_availability': <String, dynamic>{
      'state': 'available',
      'sources': const <String>['__this_device__'],
      'all_sources': const <String>['__this_device__'],
      'copy_count': 1,
    },
  };

  testWidgets('dashboard shell fits 720p and 1080p Android viewports', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    const platformChannel = MethodChannel('dev.intmusic/platform');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      platformChannel,
      (call) async => call.method == 'initialize'
          ? <String, dynamic>{'titlebarSafeInset': 0.0}
          : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        platformChannel,
        null,
      ),
    );

    for (final resolution in resolutions) {
      await configureResolution(tester, resolution.$1, resolution.$2);
      await tester.pumpWidget(
        const IntMusicClientApp(enableAudioRenderer: false),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('mobile-search-button')), findsOneWidget);
    }
  });

  testWidgets('track and playlist details use scrollable compact layouts', (
    tester,
  ) async {
    final tracks = List<Map<String, dynamic>>.generate(
      8,
      (index) => track(
        index + 1,
        'A complete song title that should not disappear ${index + 1}',
      ),
    );
    final detail = <String, dynamic>{
      'track': track(1, '2002年的第一场雪（完整标题）'),
      'genres': const <String>['Pop'],
      'composers': const <String>[],
      'lyricists': const <String>[],
      'lyrics': null,
      'media': null,
    };
    final playlist = <String, dynamic>{
      'playlist': <String, dynamic>{
        'id': 7,
        'name': 'Phone favorites with a complete title',
        'kind': 'smart',
        'track_count': tracks.length,
      },
      'tracks': tracks,
      'rules': <String, dynamic>{
        'match': 'any',
        'rules': const <Map<String, dynamic>>[
          <String, dynamic>{
            'field': 'library_source',
            'op': 'in_any',
            'value': <int>[10],
          },
        ],
      },
    };

    for (final resolution in resolutions) {
      await configureResolution(tester, resolution.$1, resolution.$2);
      await tester.pumpWidget(surface(responsiveTrackDetailForTesting(detail)));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const PageStorageKey('track-detail-mobile-scroll')),
        findsOneWidget,
      );

      await tester.pumpWidget(
        surface(responsivePlaylistDetailForTesting(playlist)),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(CustomScrollView), findsOneWidget);
      expect(find.textContaining('complete song title'), findsWidgets);
    }
  });

  testWidgets('playback queue preserves title space on narrow screens', (
    tester,
  ) async {
    final items = List<Map<String, dynamic>>.generate(
      6,
      (index) => <String, dynamic>{
        'id': index + 1,
        'track': track(
          index + 1,
          'Long queued song title that remains visible ${index + 1}',
        ),
      },
    );

    for (final resolution in resolutions) {
      await configureResolution(tester, resolution.$1, resolution.$2);
      await tester.pumpWidget(surface(responsiveQueueForTesting(items)));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Long queued song title'), findsWidgets);
      expect(find.byIcon(Icons.drag_handle_rounded), findsWidgets);
    }
  });
}
