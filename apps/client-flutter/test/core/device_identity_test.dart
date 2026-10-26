import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/core/device_identity.dart';

void main() {
  ClientDeviceIdentity device(
    String id, {
    String name = 'Mate80PM',
    String fallback = 'fresh-install',
  }) => ClientDeviceIdentity.resolve(
    platform: 'android',
    native: {'stableId': id, 'displayName': name},
    fallbackId: fallback,
    hostname: 'localhost',
  );

  test('reinstall and device renaming preserve a system-derived identity', () {
    final before = device('1234567890abcdef');
    final after = device(
      '1234567890abcdef',
      name: 'Renamed phone',
      fallback: 'another-install',
    );
    expect(after.id, before.id);
    expect(after.displayName, 'Renamed phone');
    expect(after.systemBacked, isTrue);
    expect(after.id, isNot(contains('1234567890abcdef')));
  });

  test('Android devices sharing localhost remain distinct', () {
    expect(device('1234567890abcdef').id, isNot(device('abcdef1234567890').id));
  });

  test(
    'UUID formatting is canonical and platform namespaces stay separate',
    () {
      final first = ClientDeviceIdentity.resolve(
        platform: 'macos',
        native: {'stableId': 'ABCDEF12-3456-7890-ABCD-EF1234567890'},
        fallbackId: 'fallback',
      );
      final second = ClientDeviceIdentity.resolve(
        platform: 'macos',
        native: {'stableId': 'abcdef1234567890abcdef1234567890'},
        fallbackId: 'different',
      );
      expect(first.id, second.id);
      expect(first.id, isNot(device('abcdef1234567890abcdef1234567890').id));
    },
  );

  test('unavailable or placeholder identifiers use the saved fallback', () {
    for (final value in [
      '',
      'localhost',
      '0000000000000000',
      'ffffffffffffffff',
    ]) {
      final result = device(value, name: '', fallback: 'saved-id');
      expect(result.id, 'saved-id');
      expect(result.systemBacked, isFalse);
      expect(result.displayName, 'Android device');
    }
  });
}
