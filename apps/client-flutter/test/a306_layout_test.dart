import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/intmusic_client.dart';
import 'package:intmusic_client/src/app_theme.dart';

void main() {
  testWidgets('240dp and 360dp shells leave room for multiple readable songs', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final tracks = List.generate(
      30,
      (id) => <String, dynamic>{
        'id': id,
        'title': 'Song $id',
        'artist_display': 'Taylor Swift',
        'album_title': 'Lover',
        'duration_ms': 180000,
      },
    );
    for (final width in [240.0, 360.0]) {
      tester.view.physicalSize = Size(width, width * 1280 / 720);
      tester.view.devicePixelRatio = 1;
      for (final scale in [1.0, 1.3]) {
        var dismissed = false;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildIntMusicTheme(platform: TargetPlatform.android),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: compactLibraryShellForTesting(tracks),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$width / $scale');
        final visible = find.textContaining('Song ').hitTestable();
        expect(visible.evaluate().length, greaterThanOrEqualTo(3));
        expect(tester.getSize(visible.first).width, greaterThan(60));
        await tester.pumpWidget(
          MaterialApp(
            theme: buildIntMusicTheme(platform: TargetPlatform.android),
            home: Scaffold(
              body: compactLibraryShellForTesting(
                tracks,
                onDismiss: () => dismissed = true,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.close).first);
        expect(dismissed, isTrue);
        expect(tester.takeException(), isNull);
      }
    }
  });
  testWidgets('errors automatically release the occupied screen space', (
    tester,
  ) async {
    var dismissed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: compactLibraryShellForTesting(
            [],
            onDismiss: () => dismissed = true,
          ),
        ),
      ),
    );
    expect(find.textContaining('Playback command failed'), findsOneWidget);
    await tester.pump(const Duration(seconds: 8));
    expect(dismissed, isTrue);
    expect(find.textContaining('Playback command failed'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('small Android surfaces avoid blur but desktop keeps it', (
    tester,
  ) async {
    for (final platform in [TargetPlatform.android, TargetPlatform.macOS]) {
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 2;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildIntMusicTheme(platform: platform),
          home: const Scaffold(body: IntMusicGlass(child: Text('Music'))),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byType(BackdropFilter),
        platform == TargetPlatform.android ? findsNothing : findsOneWidget,
      );
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  testWidgets('player and lyrics fit narrow displays and large text', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final size in [
      const Size(320, 568),
      const Size(360, 560),
      const Size(640, 280),
    ]) {
      for (final scale in [1.0, 1.3]) {
        tester.view.physicalSize = size * 2;
        tester.view.devicePixelRatio = 2;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildIntMusicTheme(platform: TargetPlatform.android),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(body: compactPlaybackForTesting()),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: '$size scale=$scale player',
        );
        if (size.height >= 560 && scale == 1) {
          expect(find.byIcon(Icons.skip_next).hitTestable(), findsOneWidget);
        }
        await tester.drag(find.byType(PageView), Offset(-size.width, 0));
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: '$size scale=$scale lyrics',
        );
        await tester.pumpWidget(const SizedBox());
      }
    }
  });
  test(
    'lyrics are parsed once for repeated ticks and invalidated on edits',
    () {
      const text = '[00:00.00]First line\n[00:10.00]Second line';
      final initial = parsedLyricsForTesting(text);
      for (var tick = 0; tick < 100; tick++) {
        expect(identical(initial, parsedLyricsForTesting(text)), isTrue);
      }
      expect(
        identical(initial, parsedLyricsForTesting(text, offset: 200)),
        isFalse,
      );
      expect(
        identical(initial, parsedLyricsForTesting('$text\n[00:20.00]New')),
        isFalse,
      );
    },
  );
}
