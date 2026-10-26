import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Display names can change; only a system identifier establishes identity.
/// Keep the v1 digest namespace and normalization stable across app releases.
class ClientDeviceIdentity {
  const ClientDeviceIdentity({
    required this.id,
    required this.displayName,
    required this.systemBacked,
  });

  final String id;
  final String displayName;
  final bool systemBacked;

  static String newFallbackId(String platform) {
    final random = Random.secure();
    final bytes = List.generate(24, (_) => random.nextInt(256));
    return 'flutter-$platform-${sha256.convert(bytes)}';
  }

  factory ClientDeviceIdentity.resolve({
    required String platform,
    required Map<dynamic, dynamic> native,
    required String fallbackId,
    String hostname = '',
  }) {
    final rawId = native['stableId']?.toString().trim().toLowerCase() ?? '';
    final compact = rawId.replaceAll('-', '');
    final validId =
        RegExp(r'^[a-f0-9]{16,64}$').hasMatch(compact) &&
        !RegExp(r'^0+$|^f+$').hasMatch(compact);
    final name = native['displayName']?.toString().trim() ?? '';
    final host = hostname.trim();
    return ClientDeviceIdentity(
      id: validId
          ? 'flutter-$platform-${sha256.convert(utf8.encode('dev.intmusic.device.v1:$platform:$compact'))}'
          : fallbackId,
      displayName: name.isNotEmpty
          ? name
          : host.isNotEmpty && host.toLowerCase() != 'localhost'
          ? host
          : switch (platform) {
              'android' => 'Android device',
              'macos' => 'Mac',
              'windows' => 'Windows PC',
              'linux' => 'Linux device',
              _ => 'IntMusic device',
            },
      systemBacked: validId,
    );
  }
}
