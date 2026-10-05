import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/intmusic_client.dart';
import 'core/release_media_test.dart' show releaseFixture;

void main() {
  testWidgets(
    'album cards retain edition titles and device format tags at phone and desktop widths',
    (tester) async {
      for (final width in [360.0, 1200.0]) {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: releaseCardsForTesting(releaseFixture())),
          ),
        );
        expect(find.text('Lover'), findsOneWidget);
        expect(find.text('The Eras Tour'), findsOneWidget);
        expect(find.textContaining('Mate80PM'), findsOneWidget);
        expect(find.text('M4A'), findsOneWidget);
        expect(find.text('FLAC'), findsNWidgets(2));
        expect(find.textContaining('Mate80PM · Offline'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    },
  );
}
