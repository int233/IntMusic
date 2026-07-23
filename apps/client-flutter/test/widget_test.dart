import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<void> pumpDesktop(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    const platformChannel = MethodChannel('dev.intmusic/platform');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      platformChannel,
      (call) async => call.method == 'initialize'
          ? <String, dynamic>{'titlebarSafeInset': 32.0}
          : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        platformChannel,
        null,
      ),
    );
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const IntMusicClientApp(enableAudioRenderer: false),
    );
    await tester.pump();
  }

  testWidgets('renders core dashboard shell', (tester) async {
    await pumpDesktop(tester);
    expect(find.text('Home'), findsWidgets);
    expect(find.byIcon(Icons.search), findsWidgets);
    expect(find.text('Core URL'), findsNothing);

    final sidebarGlass = find.byKey(const Key('app-sidebar-glass'));
    expect(tester.getTopLeft(sidebarGlass).dy, Platform.isMacOS ? 42 : 10);
  });

  testWidgets('shows core url setting in settings page', (tester) async {
    await pumpDesktop(tester);
    await tester.tap(find.byIcon(Icons.tune_outlined).first);
    await tester.pump();

    expect(find.text('Core URL'), findsOneWidget);
  });

  testWidgets('keeps browser-style back and forward navigation history', (
    tester,
  ) async {
    await pumpDesktop(tester);
    final back = find.byKey(const Key('navigation-back'));
    final forward = find.byKey(const Key('navigation-forward'));

    expect(tester.widget<IconButton>(back).onPressed, isNull);
    expect(tester.widget<IconButton>(forward).onPressed, isNull);

    await tester.tap(find.byIcon(Icons.tune_outlined).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 280));
    expect(find.text('Core URL'), findsOneWidget);
    expect(tester.widget<IconButton>(back).onPressed, isNotNull);

    tester.widget<IconButton>(back).onPressed!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 280));
    expect(find.text('Core URL'), findsNothing);
    expect(tester.widget<IconButton>(forward).onPressed, isNotNull);

    tester.widget<IconButton>(forward).onPressed!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 280));
    expect(find.text('Core URL'), findsOneWidget);
  });

  testWidgets('persists the selected library view mode', (tester) async {
    await pumpDesktop(tester);
    await tester.tap(find.byIcon(Icons.album_outlined).first);
    await tester.pump();

    await tester.tap(find.byIcon(Icons.view_list_rounded));
    await tester.pump();

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('intmusic.view.albums'), 'list');

    await tester.tap(find.byIcon(Icons.music_note_outlined).first);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.grid_view_rounded));
    await tester.pump();

    expect(preferences.getString('intmusic.view.tracks'), 'grid');
  });

  testWidgets('animates the desktop sidebar across its width threshold', (
    tester,
  ) async {
    await pumpDesktop(tester);
    final contentSurface = find.byKey(const Key('app-content-surface'));
    final expandedX = tester.getTopLeft(contentSurface).dx;
    expect(expandedX, greaterThan(200));

    tester.view.physicalSize = const Size(860, 800);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 280));
    expect(tester.getTopLeft(contentSurface).dx, closeTo(expandedX, 0.1));
    expect(find.byIcon(Icons.menu).hitTestable(), findsNothing);

    tester.view.physicalSize = const Size(820, 800);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final collapsingX = tester.getTopLeft(contentSurface).dx;
    expect(collapsingX, greaterThan(0));
    expect(collapsingX, lessThan(expandedX));

    await tester.pump(const Duration(milliseconds: 160));
    expect(tester.getTopLeft(contentSurface).dx, closeTo(0, 0.1));
    expect(find.byIcon(Icons.menu).hitTestable(), findsOneWidget);

    tester.view.physicalSize = const Size(1200, 800);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final expandingX = tester.getTopLeft(contentSurface).dx;
    expect(expandingX, greaterThan(0));
    expect(expandingX, lessThan(expandedX));

    await tester.pump(const Duration(milliseconds: 160));
    expect(tester.getTopLeft(contentSurface).dx, closeTo(expandedX, 0.1));
  });
}
