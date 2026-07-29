import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/intmusic_client.dart';

void main() {
  testWidgets('file detail supports files without embedded metadata', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: libraryFileDetailDialogForTesting(<String, dynamic>{
            'file': <String, dynamic>{
              'extension': 'flac',
              'presence_state': 'offline',
              'relative_path': 'Music/Track.flac',
              'device_name': 'Offline client',
              'root_name': 'Music',
              'size_bytes': 1024,
            },
            'embedded_metadata': null,
            'issues': const <dynamic>[],
          }),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Music/Track.flac'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Embedded metadata'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Embedded metadata'), findsOneWidget);
  });
}
