part of '../intmusic_client.dart';

@visibleForTesting
Widget responsiveTrackDetailForTesting(Map<String, dynamic> detail) {
  return _TrackInfoPage(
    coreBaseUrl: '',
    detail: detail,
    onClose: () {},
    onPlayTrack: (_) async {},
    onOpenAlbum: (_) async {},
    onOpenArtist: (_) async {},
    onToggleFavorite: (_) async {},
    onAddToPlaylist: (_) async {},
    onEdit: () async {},
    onManageVersions: () async {},
  );
}

@visibleForTesting
Widget responsivePlaylistDetailForTesting(Map<String, dynamic> detail) {
  return _PlaylistDetailPage(
    coreBaseUrl: '',
    detail: detail,
    initialScrollOffset: 0,
    onScrollOffsetChanged: (_) {},
    onPlayTrack: (_) async {},
    onOpenTrack: (_) async {},
    onToggleFavorite: (_) async {},
    onEditSmart: () async {},
    onRemoveTrack: (_) async {},
  );
}

@visibleForTesting
Widget responsiveQueueForTesting(
  List<Map<String, dynamic>> items, {
  int currentIndex = 0,
}) {
  return _QueueSheet(
    coreBaseUrl: '',
    items: items,
    currentIndex: currentIndex,
    onPlayTrack: (_, _) async {},
    onMove: (_, _) async => null,
    onRemove: (_) async => null,
    onClearUpcoming: () async => null,
    onClearAll: () async => null,
  );
}

@visibleForTesting
Widget responsiveTracksLibraryForTesting(List<Map<String, dynamic>> tracks) {
  return _TracksPage(
    coreBaseUrl: '',
    tracks: tracks,
    onOpenTrack: (_) async {},
    onPlayTrack: (_) async {},
    onToggleFavorite: (_) async {},
    onAddToPlaylist: (_) async {},
    onDistributeTracks: (_) async {},
    viewMode: _LibraryViewMode.list,
    onViewModeChanged: (_) {},
  );
}
