import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/core/navigation_history.dart';

void main() {
  test('keeps browser-style back and forward stacks', () {
    final history = NavigationHistory<String>('home');

    expect(history.navigateTo('albums'), isTrue);
    expect(history.navigateTo('artist:1'), isTrue);
    expect(history.current, 'artist:1');

    expect(history.goBack(), 'albums');
    expect(history.goBack(), 'home');
    expect(history.canGoBack, isFalse);
    expect(history.goForward(), 'albums');

    history.navigateTo('settings');
    expect(history.canGoForward, isFalse);
  });

  test('ignores duplicate destinations and limits retained depth', () {
    final history = NavigationHistory<int>(0, maximumDepth: 2);

    expect(history.navigateTo(0), isFalse);
    history.navigateTo(1);
    history.navigateTo(2);
    history.navigateTo(3);

    expect(history.backDepth, 2);
    expect(history.goBack(), 2);
    expect(history.goBack(), 1);
    expect(history.goBack(), isNull);
  });
}
