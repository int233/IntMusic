part of '../intmusic_client.dart';

extension _DashboardSongDisplay on _CoreDashboardState {
  Future<void> _setSongDisplaySettings(Map<String, dynamic> changes) async {
    await _songDisplaySettingsQueue.run(() async {
      final result = await _run<Map<String, dynamic>>(
        () async => _asMap(
          await _api.postJson('/settings/song-display', {
            ..._songDisplaySettings,
            ...changes,
          }),
        ),
      );
      if (result != null && mounted) {
        _mutate(() => _songDisplaySettings = result);
        unawaited(_refreshSettingsCache());
      }
    });
  }

  Future<void> _setSongDisplayMode(int id, String mode) async {
    final track = _tracks
        .whereType<Map>()
        .where((t) => t['id'] == id)
        .firstOrNull;
    final summary = track == null
        ? _asMap(_trackDetailCache[id]?['track'])
        : Map<String, dynamic>.from(track);
    final api = _api;
    await _run<void>(
      () => _songDisplayState.setMode(
        {...summary, 'id': id},
        mode,
        () async =>
            _asMap(await api.postJson('/tracks/$id/display', {'mode': mode})),
      ),
    );
    if (mounted) unawaited(_backgroundLibrarySync(force: true));
  }

  Future<void> _applyTagMappings() async {
    final result = await _run<Map<String, dynamic>>(
      () async => _asMap(
        await _api.postJson(
          '/library/tag-mappings/apply',
          {},
          requestTimeout: const Duration(minutes: 5),
        ),
      ),
    );
    if (result != null && mounted) {
      await _refreshAll();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已整理 ${result['updated_tracks']} 首歌曲的标签')),
        );
      }
    }
  }
}

List<Map<String, dynamic>> _displayTracks(
  BuildContext context,
  List<dynamic> tracks,
) {
  final scope = _TrackActionScope.maybeOf(context);
  return projectSongList(
    tracks.map((value) {
      final track = _asMap(value);
      return scope?.displayState?.project(track) ?? track;
    }),
    mergeSameName: scope?.mergeSameName ?? false,
    filter: scope?.songDisplaySettings['attribute_filter']?.toString() ?? 'all',
    sortByMode: scope?.songDisplaySettings['sort_by_mode'] == true,
  );
}

class _SongDisplaySettings extends StatelessWidget {
  const _SongDisplaySettings();
  @override
  Widget build(BuildContext context) {
    final actions = _TrackActionScope.maybeOf(context);
    final settings = actions?.songDisplaySettings ?? const <String, dynamic>{};
    void update(Map<String, dynamic> changes) =>
        unawaited(actions?.onSetSongDisplaySettings?.call(changes));
    return _HomePanel(
      title: '歌曲展示',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SettingsSwitchRow(
            key: const Key('merge-same-name-setting'),
            value: actions?.mergeSameName ?? false,
            title: '合并同名歌曲',
            subtitle: '同一艺术家的同名歌曲合并为一行。单曲可设为合并或独立展示；每个专辑版本仍单独保留。此设置在设备间同步。',
            onChanged: (value) => update({'merge_same_name': value}),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            key: ValueKey(
              'display-filter-${settings['attribute_filter'] ?? 'all'}',
            ),
            initialValue: settings['attribute_filter']?.toString() ?? 'all',
            decoration: const InputDecoration(
              labelText: '按展示属性筛选',
              helperText: '应用于歌曲列表、歌单、搜索和历史；播放队列保留全部项目。',
              helperMaxLines: 3,
            ),
            items: [
              const DropdownMenuItem(value: 'all', child: Text('所有展示属性')),
              for (final mode in ['inherit', 'merged', 'independent'])
                DropdownMenuItem(
                  value: mode,
                  child: Text(songDisplayModeLabel(mode)),
                ),
            ],
            onChanged: (value) {
              if (value != null) update({'attribute_filter': value});
            },
          ),
          const SizedBox(height: 16),
          _SettingsSwitchRow(
            key: const Key('sort-display-mode-setting'),
            value: settings['sort_by_mode'] == true,
            title: '按展示属性排序',
            subtitle: '统一调整歌曲列表的展示顺序；播放队列仍按实际播放顺序排列。',
            onChanged: (value) => update({'sort_by_mode': value}),
          ),
        ],
      ),
    );
  }
}

class _SongGroupButton extends StatelessWidget {
  const _SongGroupButton({required this.track});
  final Map<String, dynamic> track;
  @override
  Widget build(BuildContext context) => TextButton(
    style: TextButton.styleFrom(
      minimumSize: const Size(48, 40),
      padding: const EdgeInsets.symmetric(horizontal: 4),
    ),
    onPressed: () => unawaited(_showSongDisplay(context, track)),
    child: Text('${(track['_display_members'] as List).length}版'),
  );
}

Future<void> _showSongDisplay(
  BuildContext context,
  Map<String, dynamic> track,
) async {
  final actions = _TrackActionScope.maybeOf(context);
  if (actions == null) return;
  final members = ((track['_display_members'] as List?) ?? [track])
      .map(_asMap)
      .toList();
  late PersistentBottomSheetController sheet;
  sheet = Scaffold.of(context).showBottomSheet(
    (sheetContext) => ListenableBuilder(
      listenable: Listenable.merge([actions.displayState]),
      builder: (context, _) => SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 680,
            maxHeight: MediaQuery.sizeOf(context).height * 0.65,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${track['title'] ?? ''} · 展示方式',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    TextButton(
                      onPressed: () => sheet.close(),
                      child: const Text('关闭'),
                    ),
                  ],
                ),
                const Text('选择后立即生效。专辑、收藏、流派和播放文件仍属于各自版本。'),
                const SizedBox(height: 12),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final member in members.map(
                          (track) =>
                              actions.displayState?.project(track) ?? track,
                        ))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(
                                    member['album_title']?.toString() ?? '未知专辑',
                                  ),
                                  subtitle: Text(
                                    _joinParts([
                                      member['artist_display'],
                                      member['year'],
                                      _formatDuration(member['duration_ms']),
                                      (member['genres'] as List?)?.join(' · '),
                                    ]),
                                  ),
                                  onTap: () async {
                                    sheet.close();
                                    await sheet.closed;
                                    await actions.onOpenTrack?.call(
                                      _intValue(member['id'])!,
                                    );
                                  },
                                  trailing: IconButton(
                                    icon: const Icon(Icons.play_arrow),
                                    tooltip: '播放此版本',
                                    onPressed: () => unawaited(
                                      actions.onPlayTrack?.call(
                                        _intValue(member['id'])!,
                                      ),
                                    ),
                                  ),
                                ),
                                Wrap(
                                  key: ValueKey('display-mode-${member['id']}'),
                                  spacing: 8,
                                  runSpacing: 4,
                                  children: [
                                    for (final mode in [
                                      'inherit',
                                      'merged',
                                      'independent',
                                    ])
                                      ChoiceChip(
                                        label: Text(songDisplayModeLabel(mode)),
                                        selected:
                                            (member['display_mode'] ??
                                                'inherit') ==
                                            mode,
                                        onSelected: (selected) {
                                          if (selected) {
                                            unawaited(
                                              actions.onSetDisplayMode?.call(
                                                _intValue(member['id'])!,
                                                mode,
                                              ),
                                            );
                                          }
                                        },
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
    showDragHandle: true,
    backgroundColor: IntMusicTheme.of(context).surface.withValues(alpha: 1),
    clipBehavior: Clip.antiAlias,
  );
  await sheet.closed;
}

Future<void> _playDisplayedSong(
  BuildContext context,
  int id,
  List<dynamic> tracks,
  Future<void> Function(int) fallback,
) async {
  final action = _TrackActionScope.maybeOf(context)?.onPlayListSong;
  if (action == null) {
    await fallback(id);
    return;
  }
  await action(id, tracks);
}

List<Map<String, dynamic>> _displayTrackStats(
  BuildContext context,
  List<dynamic> stats,
) {
  final catalog = {
    for (final value
        in _TrackActionScope.maybeOf(context)?.catalogTracks ?? const [])
      if (value is Map) value['id']: value,
  };
  final groups = _displayTracks(context, [
    for (final value in stats)
      {
        ...?catalog[(value as Map)['track_id']],
        ...value,
        'id': value['track_id'],
      },
  ]);
  return [
    for (final group in groups)
      if (group['_display_members'] is List)
        {
          ...group,
          'play_count': (group['_display_members'] as List).fold<int>(
            0,
            (sum, t) => sum + (_intValue(t['play_count']) ?? 0),
          ),
          'total_played_ms': (group['_display_members'] as List).fold<int>(
            0,
            (sum, t) => sum + (_intValue(t['total_played_ms']) ?? 0),
          ),
        }
      else
        group,
  ];
}

List<Map<String, dynamic>> _displayHistoryEvents(
  BuildContext context,
  List<dynamic> events,
) {
  final catalog = {
    for (final value
        in _TrackActionScope.maybeOf(context)?.catalogTracks ?? const [])
      if (value is Map) value['id']: value,
  };
  return _displayTracks(context, [
    for (final value in events)
      {
        ...?catalog[(value as Map)['track_id']],
        ...value,
        'id': value['track_id'],
      },
  ]);
}
