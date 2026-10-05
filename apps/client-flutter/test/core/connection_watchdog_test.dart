import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/core/connection_watchdog.dart';

void main() {
  test('a responsive event channel never reconnects', () {
    final watchdog = ConnectionWatchdog(Duration.zero);
    for (var second = 3; second <= 120; second += 3) {
      expect(watchdog.shouldReconnect(Duration(seconds: second)), isFalse);
      watchdog.pong(Duration(seconds: second));
    }
  });
  test('a silent peer times out while the UI is responsive', () {
    final watchdog = ConnectionWatchdog(Duration.zero);
    for (var second = 3; second <= 18; second += 3) {
      expect(watchdog.shouldReconnect(Duration(seconds: second)), isFalse);
    }
    expect(watchdog.shouldReconnect(const Duration(seconds: 21)), isTrue);
  });
  test(
    'a scheduling pause gets a fresh probe, not an immediate disconnect',
    () {
      final watchdog = ConnectionWatchdog(Duration.zero);
      expect(watchdog.shouldReconnect(const Duration(seconds: 90)), isFalse);
      watchdog.pong(const Duration(seconds: 91));
      expect(watchdog.shouldReconnect(const Duration(seconds: 93)), isFalse);
      for (var second = 96; second <= 108; second += 3) {
        expect(watchdog.shouldReconnect(Duration(seconds: second)), isFalse);
      }
      expect(watchdog.shouldReconnect(const Duration(seconds: 111)), isTrue);
    },
  );
}
