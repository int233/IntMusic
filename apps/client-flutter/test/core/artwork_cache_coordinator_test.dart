import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/core/artwork_cache_coordinator.dart';

void main() {
  test('uses a stable artwork key across addresses for the same Core', () {
    final coordinator = ArtworkCacheCoordinator()
      ..registerServer('core-server-id');

    expect(
      coordinator.cacheKey('http://127.0.0.1:49330/api/v1/artwork/tracks/42'),
      coordinator.cacheKey(
        'http://192.168.50.10:49330/api/v1/artwork/tracks/42',
      ),
    );
  });

  test('keeps artwork revisions distinct and exposes a retry signal', () {
    final coordinator = ArtworkCacheCoordinator()
      ..registerServer('core-server-id');
    final before = coordinator.retryRevision.value;

    expect(
      coordinator.cacheKey(
        'http://core/api/v1/artwork/artists/7/avatar?revision=1',
      ),
      isNot(
        coordinator.cacheKey(
          'http://core/api/v1/artwork/artists/7/avatar?revision=2',
        ),
      ),
    );

    coordinator.retryFailedImages();
    expect(coordinator.retryRevision.value, before + 1);
  });
}
