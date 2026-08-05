import 'package:flutter/foundation.dart';

/// Keeps artwork cache identities stable when the same Core is reached through
/// localhost, a LAN address, or a tunnel address. The revision is only a UI
/// retry signal; it is deliberately excluded from the disk-cache key.
class ArtworkCacheCoordinator {
  final ValueNotifier<int> retryRevision = ValueNotifier<int>(0);

  String? _serverId;

  void registerServer(String? serverId) {
    final normalized = serverId?.trim();
    if (normalized == null || normalized.isEmpty || normalized == _serverId) {
      return;
    }
    _serverId = normalized;
    retryRevision.value += 1;
  }

  void retryFailedImages() {
    retryRevision.value += 1;
  }

  String cacheKey(String imageUrl) {
    final uri = Uri.tryParse(imageUrl);
    if (uri == null) return imageUrl;
    final namespace = _serverId ?? '${uri.scheme}://${uri.authority}';
    final queryEntries = uri.queryParametersAll.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    final query = <String>[];
    for (final entry in queryEntries) {
      final values = [...entry.value]..sort();
      for (final value in values) {
        query.add(
          '${Uri.encodeQueryComponent(entry.key)}='
          '${Uri.encodeQueryComponent(value)}',
        );
      }
    }
    return 'intmusic-artwork:$namespace:${uri.path}'
        '${query.isEmpty ? '' : '?${query.join('&')}'}';
  }
}

final ArtworkCacheCoordinator artworkCacheCoordinator =
    ArtworkCacheCoordinator();
