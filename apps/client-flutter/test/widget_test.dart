import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<void> pumpDesktop(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const IntMusicClientApp());
  }

  testWidgets('renders core dashboard shell', (tester) async {
    await pumpDesktop(tester);
    expect(find.text('Home'), findsWidgets);
    expect(find.byIcon(Icons.search), findsWidgets);
    expect(find.text('Core URL'), findsNothing);
  });

  testWidgets('shows core url setting in settings page', (tester) async {
    await pumpDesktop(tester);
    await tester.tap(find.byIcon(Icons.tune_outlined).first);
    await tester.pump();

    expect(find.text('Core URL'), findsOneWidget);
  });
}
