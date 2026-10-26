import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/intmusic_client.dart';
import 'package:intmusic_client/core/logging/client_log.dart';

void main() {
  testWidgets(
    'dismissed page errors stay hidden during repeated refreshes and remain in history',
    (tester) async {
      const message =
          'HttpException: Connection closed before full header was received';
      Widget page(String error) => MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              errorNoticeForTesting(error),
              Expanded(child: errorHistoryForTesting()),
            ],
          ),
        ),
      );
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(page(message));
      await tester.pump();
      expect(find.byKey(const Key('dismiss-error')), findsOneWidget);
      await tester.tap(find.byKey(const Key('dismiss-error')));
      await tester.pump();
      await tester.pumpWidget(page(message));
      expect(find.byKey(const Key('dismiss-error')), findsNothing);
      expect(
        ClientLog.errors.entries.value.any((e) => e['message'] == message),
        isTrue,
      );
      await tester.tap(find.byKey(const Key('view-error-history')));
      await tester.pumpAndSettle();
      expect(find.text(message), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a new distinct error can notify after the previous error is dismissed',
    (tester) async {
      Widget page(String message) =>
          MaterialApp(home: Scaffold(body: errorNoticeForTesting(message)));
      await tester.pumpWidget(page('First failure'));
      await tester.tap(find.byKey(const Key('dismiss-error')));
      await tester.pump();
      await tester.pumpWidget(page('Second failure'));
      expect(find.text('Second failure'), findsOneWidget);
      await tester.pump(const Duration(seconds: 8));
      expect(find.byKey(const Key('dismiss-error')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
