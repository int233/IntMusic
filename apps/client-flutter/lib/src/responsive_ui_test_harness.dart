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
  final store = CollectionStore(persist: false);
  final tracks = ((detail['tracks'] as List?) ?? [])
      .map(
        (t) => {
          ..._asMap(t),
          'release_identity_id': (t as Map)['release_identity_id'] ?? t['id'],
        },
      )
      .toList();
  final summary = {
    'id': 1,
    'name': _asMap(detail['playlist'])['name'] ?? '歌曲集合',
    'entity_type': 'track',
    'result_total': tracks.length,
    'result_version': 'test',
    'revision': 1,
    'can_edit': false,
  };
  store.items = [summary];
  store.pages[1] = {
    'collection': summary,
    'definition': emptyCollection(),
    'result_version': 'test',
    'result_total': tracks.length,
    'next_offset': null,
    'items': [
      for (final t in tracks)
        {
          'entity_id': t['release_identity_id'],
          'entity_type': 'track',
          'data': t,
        },
    ],
  };
  return Builder(
    builder: (context) => _CollectionBlock(
      store: store,
      id: 1,
      coreBaseUrl: '',
      fullPage: true,
      onOpenEntity: (_, _) async {},
      onPlay: (_, tracks, _) async {
        await _TrackActionScope.maybeOf(context)?.onPlayCollection.call(
          tracks.map((t) => (t as Map)['id'] as int).toList(),
          false,
        );
      },
      onToggleFavorite: (_) async {},
      onEdit: (_) async {},
    ),
  );
}

@visibleForTesting
Widget responsiveQueueForTesting(
  List<Map<String, dynamic>> items, {
  int currentIndex = 0,
  bool mergeSameName = false,
  Future<Map<String, dynamic>?> Function(String)? onRemove,
  Future<void> Function(String, int)? onPlay,
}) {
  return _QueueSheet(
    coreBaseUrl: '',
    mergeSameName: mergeSameName,
    items: items,
    currentIndex: currentIndex,
    onPlayTrack: onPlay ?? (_, _) async {},
    onMove: (_, _) async => null,
    onRemove: onRemove ?? (_) async => null,
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

@visibleForTesting
Widget releaseCardsForTesting(Map<String, dynamic> media) => ListView(
  padding: const EdgeInsets.all(16),
  children: [
    for (final group in groupReleaseMedia(media))
      _ReleaseMediaCard(group: group, coreConnected: true),
  ],
);

@visibleForTesting
Widget songDisplayPlaylistForTesting(
  List<Map<String, dynamic>> tracks, {
  required Future<void> Function(List<int>, bool) onPlay,
  required Future<void> Function(int, String) onMode,
  required SongDisplayState displayState,
  Map<String, dynamic> settings = const {'merge_same_name': true},
}) => _TrackActionScope(
  onPlayNext: (_) async {},
  onAddToQueue: (_) async {},
  onPlayCollection: onPlay,
  onQueueCollection: (_, _) async {},
  onDistributeCollection: (_) async {},
  songDisplaySettings: settings,
  displayState: displayState,
  onSetDisplayMode: (id, mode) => displayState.setMode(
    tracks.firstWhere((t) => t['id'] == id),
    mode,
    () async {
      await onMode(id, mode);
      return {'cursor': 1};
    },
  ),
  child: responsivePlaylistDetailForTesting({
    'playlist': {
      'id': 1,
      'name': 'Phone',
      'kind': 'manual',
      'track_count': tracks.length,
    },
    'tracks': tracks,
  }),
);

@visibleForTesting
Widget songDisplaySettingsForTesting({
  required Map<String, dynamic> settings,
  required Future<void> Function(Map<String, dynamic>) onChanged,
}) => _TrackActionScope(
  onPlayNext: (_) async {},
  onAddToQueue: (_) async {},
  onPlayCollection: (_, _) async {},
  onQueueCollection: (_, _) async {},
  onDistributeCollection: (_) async {},
  songDisplaySettings: settings,
  onSetSongDisplaySettings: onChanged,
  child: const SingleChildScrollView(child: _SongDisplaySettings()),
);

@visibleForTesting
Widget tagRulesForTesting({
  required Map<String, dynamic> settings,
  required Future<bool> Function(Map<String, dynamic>) onSave,
  required Future<void> Function() onApply,
}) => _TrackActionScope(
  onPlayNext: (_) async {},
  onAddToQueue: (_) async {},
  onPlayCollection: (_, _) async {},
  onQueueCollection: (_, _) async {},
  onDistributeCollection: (_) async {},
  onApplyTagMappings: onApply,
  child: SingleChildScrollView(
    child: _MetadataTagRulesPanel(settings: settings, onUpdate: onSave),
  ),
);

@visibleForTesting
Widget collectionPageForTesting(
  CollectionStore store, {
  int id = 1,
  Future<void> Function(int, List<dynamic>, JsonMap?)? onPlay,
}) => _CollectionBlock(
  store: store,
  id: id,
  fullPage: true,
  coreBaseUrl: '',
  onOpenEntity: (_, _) async {},
  onPlay: onPlay ?? (_, _, _) async {},
  onToggleFavorite: (_) async {},
  onEdit: (_) async {},
);
@visibleForTesting
Widget collectionEditorForTesting(CollectionStore store, {JsonMap? initial}) =>
    _CollectionEditor(
      store: store,
      coreBaseUrl: '',
      initial: initial,
      loadSources: () async => [],
    );
@visibleForTesting
Widget homeLayoutEditorForTesting(CollectionStore store) =>
    _HomeLayoutEditor(store: store, onEditCollection: (_) async {});

@visibleForTesting
Widget collectionHomeForTesting(CollectionStore store) => _HomePage(
  store: store,
  onEditCollection: (_) async {},
  onOpenCollection: (_) {},
  onOpenEntity: (_, _) async {},
  onPlayCollection: (_, _, _) async {},
  onToggleFavorite: (_) async {},
  coreBaseUrl: '',
  status: null,
  playback: null,
  trackDetail: null,
  zones: const [],
  stats: null,
  history: const [],
  onNavigate: (_) {},
  onOpenTrack: (_) async {},
  onPlayTrack: (_) async {},
);

@visibleForTesting
Widget compactPlaybackForTesting({Map<String, dynamic>? playback}) =>
    _PlaybackPage(
      coreBaseUrl: '',
      playback:
          playback ?? {'state': 'paused', 'track_id': 1, 'position_ms': 0},
      trackDetail: {
        'track': {
          'id': 1,
          'title': '只想一生跟你走（现场特别版本）',
          'artist_display': '张学友',
          'album_title': '完整专辑名称',
          'duration_ms': 180000,
        },
        'lyrics': {'text': '[00:00.00]第一行歌词\n[00:10.00]第二行歌词'},
      },
      activeZoneId: 'test',
      playbackMode: _PlaybackMode.sequential,
      volumeState: const _DualVolumeState(
        playerVolume: 1,
        playerMuted: false,
        systemVolume: 1,
        systemMuted: false,
        systemVolumeSupported: true,
      ),
      onResume: (_) async {},
      onPause: (_) async {},
      onPrevious: () async {},
      onNext: () async {},
      onSeek: (_) async {},
      onCycleMode: () {},
      onShowModeMenu: (_) {},
      onShowQueue: (_) {},
      onShowDevices: (_) {},
      onVolumeChanged: (_, _) {},
      onToggleMute: (_) {},
      onToggleFavorite: (_) async {},
      onOpenTrack: (_) async {},
    );

@visibleForTesting
Object parsedLyricsForTesting(String text, {int offset = 0}) =>
    _parseLyricLines(text, offsetMs: offset);

@visibleForTesting
Widget compactLibraryShellForTesting(
  List<Map<String, dynamic>> tracks, {
  VoidCallback? onDismiss,
}) => Column(
  children: [
    const SizedBox(height: 56, child: Center(child: Text('歌曲'))),
    if (onDismiss != null)
      _ErrorBanner(
        message: 'Playback command failed: TimeoutException after 0:00:04',
        onDismiss: onDismiss,
      ),
    Expanded(child: responsiveTracksLibraryForTesting(tracks)),
    _PlaybackBar(
      coreBaseUrl: '',
      state: const {'state': 'stopped'},
      trackDetail: null,
      targetLabel: 'This device',
      playbackMode: _PlaybackMode.sequential,
      volumeState: const _DualVolumeState(
        playerVolume: 1,
        playerMuted: false,
        systemVolume: 1,
        systemMuted: false,
        systemVolumeSupported: true,
      ),
      onResume: () {},
      onPause: () {},
      onPrevious: () {},
      onNext: () {},
      onSeek: (_) async {},
      onVolumeChanged: (_, _) {},
      onToggleMute: (_) {},
      onCycleMode: () {},
      onShowModeMenu: (_) {},
      onShowQueue: (_) {},
      onShowDevices: (_) {},
      onOpenPlayback: () {},
    ),
  ],
);
