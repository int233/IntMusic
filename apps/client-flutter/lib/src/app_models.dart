part of '../intmusic_client.dart';

class _Destination {
  const _Destination(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

class _TrackActionScope extends InheritedWidget {
  const _TrackActionScope({
    required this.onPlayNext,
    required this.onAddToQueue,
    required this.onPlayCollection,
    required this.onQueueCollection,
    required this.onDistributeCollection,
    required super.child,
  });

  final Future<void> Function(int trackId) onPlayNext;
  final Future<void> Function(int trackId) onAddToQueue;
  final Future<void> Function(List<int> trackIds, bool shuffle)
  onPlayCollection;
  final Future<void> Function(List<int> trackIds, bool playNext)
  onQueueCollection;
  final Future<void> Function(List<int> trackIds) onDistributeCollection;

  static _TrackActionScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<_TrackActionScope>();
  }

  @override
  bool updateShouldNotify(_TrackActionScope oldWidget) {
    return onPlayNext != oldWidget.onPlayNext ||
        onAddToQueue != oldWidget.onAddToQueue ||
        onPlayCollection != oldWidget.onPlayCollection ||
        onQueueCollection != oldWidget.onQueueCollection ||
        onDistributeCollection != oldWidget.onDistributeCollection;
  }
}

enum _AppRouteKind {
  home,
  albums,
  artists,
  tracks,
  playlists,
  playback,
  history,
  libraryManagement,
  settings,
  search,
  track,
  album,
  artist,
  playlist,
}

@immutable
class _AppRoute {
  const _AppRoute._(this.kind, {this.entityId, this.query});

  const _AppRoute.home() : this._(_AppRouteKind.home);
  const _AppRoute.search(String query)
    : this._(_AppRouteKind.search, query: query);
  const _AppRoute.track(int id) : this._(_AppRouteKind.track, entityId: id);
  const _AppRoute.album(int id) : this._(_AppRouteKind.album, entityId: id);
  const _AppRoute.artist(int id) : this._(_AppRouteKind.artist, entityId: id);
  const _AppRoute.playlist(int id)
    : this._(_AppRouteKind.playlist, entityId: id);

  final _AppRouteKind kind;
  final int? entityId;
  final String? query;

  static _AppRoute destination(int index) {
    return _AppRoute._(switch (index) {
      0 => _AppRouteKind.home,
      1 => _AppRouteKind.albums,
      2 => _AppRouteKind.artists,
      3 => _AppRouteKind.tracks,
      4 => _AppRouteKind.playlists,
      5 => _AppRouteKind.playback,
      6 => _AppRouteKind.history,
      7 => _AppRouteKind.libraryManagement,
      8 => _AppRouteKind.settings,
      _ => _AppRouteKind.home,
    });
  }

  int? get destinationIndex => switch (kind) {
    _AppRouteKind.home => 0,
    _AppRouteKind.albums => 1,
    _AppRouteKind.artists => 2,
    _AppRouteKind.tracks => 3,
    _AppRouteKind.playlists => 4,
    _AppRouteKind.playback => 5,
    _AppRouteKind.history => 6,
    _AppRouteKind.libraryManagement => 7,
    _AppRouteKind.settings => 8,
    _ => null,
  };

  int get animationOrder => switch (kind) {
    _AppRouteKind.home => 0,
    _AppRouteKind.albums => 1,
    _AppRouteKind.artists => 2,
    _AppRouteKind.tracks => 3,
    _AppRouteKind.playlists => 4,
    _AppRouteKind.playback => 5,
    _AppRouteKind.history => 6,
    _AppRouteKind.libraryManagement => 7,
    _AppRouteKind.settings => 8,
    _AppRouteKind.search => 9,
    _AppRouteKind.track => 10,
    _AppRouteKind.album => 11,
    _AppRouteKind.artist => 12,
    _AppRouteKind.playlist => 13,
  };

  String get animationKey => switch (kind) {
    _AppRouteKind.search => 'search:${query ?? ''}',
    _AppRouteKind.track => 'track-detail:${entityId ?? 0}',
    _AppRouteKind.album => 'album-detail:${entityId ?? 0}',
    _AppRouteKind.artist => 'artist-detail:${entityId ?? 0}',
    _AppRouteKind.playlist => 'playlist-detail:${entityId ?? 0}',
    _ => 'page:${destinationIndex ?? kind.name}',
  };

  String get title => switch (kind) {
    _AppRouteKind.home => 'Home',
    _AppRouteKind.albums => 'Albums',
    _AppRouteKind.artists => 'Artists',
    _AppRouteKind.tracks => 'Tracks',
    _AppRouteKind.playlists => 'Playlists',
    _AppRouteKind.playback => 'Playback',
    _AppRouteKind.history => 'History',
    _AppRouteKind.libraryManagement => 'Library management',
    _AppRouteKind.settings => 'Settings',
    _AppRouteKind.search => 'Search results',
    _AppRouteKind.track => 'Track detail',
    _AppRouteKind.album => 'Album detail',
    _AppRouteKind.artist => 'Artist detail',
    _AppRouteKind.playlist => 'Playlist detail',
  };

  @override
  bool operator ==(Object other) {
    return other is _AppRoute &&
        other.kind == kind &&
        other.entityId == entityId &&
        other.query == query;
  }

  @override
  int get hashCode => Object.hash(kind, entityId, query);
}

enum _PlaybackMode {
  single,
  repeatOne,
  shuffle,
  repeatAll,
  sequential;

  String get nameForApi => switch (this) {
    _PlaybackMode.single => 'single',
    _PlaybackMode.repeatOne => 'repeat_one',
    _PlaybackMode.shuffle => 'shuffle',
    _PlaybackMode.repeatAll => 'repeat_all',
    _PlaybackMode.sequential => 'sequential',
  };

  static _PlaybackMode fromApi(String? value) => switch (value) {
    'single' => _PlaybackMode.single,
    'repeat_one' => _PlaybackMode.repeatOne,
    'shuffle' => _PlaybackMode.shuffle,
    'repeat_all' => _PlaybackMode.repeatAll,
    _ => _PlaybackMode.sequential,
  };
}

enum _SearchScope { all, tracks, albums, artists, playlists }

enum _LibraryViewMode { grid, list }

enum _ZoneRegionSort { playingFirst, name }

enum _SearchSort {
  relevance,
  titleAz,
  albumAz,
  artistAz,
  fileSize,
  addedAt,
  playCount,
  favorite,
}

const _appMinWidth = 520.0;
const _appMinHeight = 720.0;
const _appMinAspectRatio = 0.62;
const _appMaxAspectRatio = 2.2;
const _compactWidth = 900.0;
const _compactHeight = 680.0;
const _sidebarWidth = 236.0;
// Keep shell expansion independent from pages' ideal-width breakpoint. At
// narrower widths the track table already hides its album column, so 600
// logical pixels remains a usable content pane beside the desktop sidebar.
// This lets common 13-inch Mac windows enter the two-column layout without
// having to grow almost to full screen.
const _minimumExpandedContentWidth = 600.0;
const _desktopShellWidth = _minimumExpandedContentWidth + _sidebarWidth + 1.0;
