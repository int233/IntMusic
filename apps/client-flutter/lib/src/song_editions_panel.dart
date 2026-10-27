part of '../intmusic_client.dart';

class _SongEditionsPanel extends StatefulWidget {
  const _SongEditionsPanel({
    required this.coreBaseUrl,
    required this.detail,
    required this.editions,
    required this.onOpenTrack,
    required this.onPlayTrack,
    required this.onManage,
    this.loadMedia,
    this.coreOnline = false,
  });
  final bool coreOnline;
  final Future<Map<String, dynamic>> Function(int)? loadMedia;
  final String coreBaseUrl;
  final Map<String, dynamic> detail;
  final List<Map<String, dynamic>> editions;
  final Future<void> Function(int) onOpenTrack, onPlayTrack;
  final Future<void> Function() onManage;
  @override
  State<_SongEditionsPanel> createState() => _SongEditionsPanelState();
}

class _SongEditionsPanelState extends State<_SongEditionsPanel> {
  Map<String, dynamic>? _media;
  bool _connected = false;
  bool _recordingOnly = false;
  bool _busy = false;
  bool _failed = false;
  int _generation = 0;
  int? get _id => _intValue(_asMap(widget.detail['track'])['id']);
  @override
  void initState() {
    super.initState();
    _media = widget.detail['media'] is Map
        ? _asMap(widget.detail['media'])
        : null;
    unawaited(_refresh());
  }

  @override
  void didUpdateWidget(covariant _SongEditionsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_asMap(oldWidget.detail['track'])['id'] != _id ||
        oldWidget.coreBaseUrl != widget.coreBaseUrl) {
      _generation++;
      _media = widget.detail['media'] is Map
          ? _asMap(widget.detail['media'])
          : null;
      _connected = false;
      _failed = false;
      _busy = false;
      unawaited(_refresh());
    } else if (oldWidget.detail['media'] != widget.detail['media'] &&
        widget.detail['media'] is Map) {
      _media = _asMap(widget.detail['media']);
    }
    _connected = widget.coreOnline;
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_busy ||
        _id == null ||
        (widget.coreBaseUrl.isEmpty && widget.loadMedia == null)) {
      return;
    }
    _busy = true;
    final generation = _generation;
    final id = _id;
    try {
      final media = widget.loadMedia != null
          ? await widget.loadMedia!(id!)
          : jsonObjectOrEmpty(widget.detail['media']);
      if (!mounted || generation != _generation) return;
      setState(() {
        _media = media;
        _connected = widget.coreOnline;
        _failed = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _connected = false;
        _failed = true;
      });
    } finally {
      if (generation == _generation) _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final scope = _TrackActionScope.maybeOf(context);
    final selected = _asMap(widget.detail['track']);
    final groups = groupReleaseMedia(
      _media ?? {},
      localCopy: widget.detail['_client_local_copy'] is Map
          ? _asMap(widget.detail['_client_local_copy'])
          : null,
    );
    final byIdentity = {for (final group in groups) group.identity: group};
    final editions = widget.editions
        .where(
          (track) =>
              !_recordingOnly ||
              byIdentity.containsKey(track['release_identity_id']),
        )
        .toList();
    return _SongDetailPanel(
      title: '同名收录',
      trailing: TextButton.icon(
        onPressed: () async {
          await widget.onManage();
          await _refresh();
        },
        icon: const Icon(Icons.tune, size: 18),
        label: const Text('管理录音关联'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${widget.editions.length} 个专辑收录 · 同一艺术家的同名歌曲',
            style: TextStyle(color: tokens.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: const Text('全部收录'),
                selected: !_recordingOnly,
                onSelected: (_) => setState(() => _recordingOnly = false),
              ),
              ChoiceChip(
                label: const Text('当前录音'),
                selected: _recordingOnly,
                onSelected: _media == null
                    ? null
                    : (_) => setState(() => _recordingOnly = true),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (_failed)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                '来源状态暂时无法更新，已保留缓存信息。',
                style: TextStyle(color: tokens.textSecondary),
              ),
            ),
          if (editions.isEmpty) const Text('当前录音没有已关联的收录'),
          for (final entry in editions) ...[
            Builder(
              builder: (context) {
                final track = scope?.displayState?.project(entry) ?? entry;
                final id = _intValue(track['id']);
                final current = track['release_identity_id'] != null
                    ? track['release_identity_id'] ==
                          selected['release_identity_id']
                    : id == _id;
                final group =
                    byIdentity[track['release_identity_id']] ??
                    (current && track['release_identity_id'] == null
                        ? groups.where((g) => g.isCurrent).firstOrNull
                        : null);
                return _SongEditionCard(
                  key: ValueKey(
                    'edition-${track['release_identity_id'] ?? id}',
                  ),
                  coreBaseUrl: widget.coreBaseUrl,
                  track: track,
                  current: current,
                  group: group,
                  connected: _connected,
                  mediaLoaded: _media != null,
                  onSelect: id == null ? null : () => widget.onOpenTrack(id),
                  onPlay: id == null ? null : () => widget.onPlayTrack(id),
                  onIndependent: id == null || scope?.onSetDisplayMode == null
                      ? null
                      : () => scope!.onSetDisplayMode!(
                          id,
                          track['display_mode'] == 'independent'
                              ? 'inherit'
                              : 'independent',
                        ),
                );
              },
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class _SongEditionCard extends StatelessWidget {
  const _SongEditionCard({
    super.key,
    required this.coreBaseUrl,
    required this.track,
    required this.current,
    required this.group,
    required this.connected,
    required this.mediaLoaded,
    this.onSelect,
    this.onPlay,
    this.onIndependent,
  });
  final String coreBaseUrl;
  final Map<String, dynamic> track;
  final bool current, connected, mediaLoaded;
  final ReleaseMediaGroup? group;
  final Future<void> Function()? onSelect, onPlay, onIndependent;
  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final copies = group?.copies ?? const <Map<String, dynamic>>[];
    final available = copies
        .where(
          (c) => replicaPresence(c, coreConnected: connected) == 'available',
        )
        .length;
    final independent = track['display_mode'] == 'independent';
    return Container(
      decoration: BoxDecoration(
        color: current
            ? tokens.accent.withValues(alpha: 0.035)
            : tokens.surfaceRaised,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: current ? tokens.accent.withValues(alpha: 0.3) : tokens.stroke,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 420;
              final actions = Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    onPressed: onPlay,
                    tooltip: '播放此收录',
                    icon: Icon(Icons.play_circle_outline, color: tokens.accent),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '收录选项',
                    onSelected: (_) => unawaited(onIndependent?.call()),
                    itemBuilder: (_) => [
                      CheckedPopupMenuItem(
                        value: 'independent',
                        checked: independent,
                        enabled: onIndependent != null,
                        child: Text(
                          independent ? '取消独立展示（使用全局设置）' : '在列表中独立展示',
                        ),
                      ),
                    ],
                  ),
                ],
              );
              final heading = InkWell(
                onTap: current ? null : onSelect,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _ArtworkTile(
                        title: track['album_title']?.toString() ?? '',
                        subtitle: '',
                        size: compact ? 40 : 56,
                        icon: Icons.album_outlined,
                        imageUrl: _trackArtworkUrl(coreBaseUrl, track['id']),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              track['album_title']?.toString() ?? '未知专辑',
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _joinParts([
                                track['year'],
                                if (track['disc_number'] != null)
                                  '光盘 ${track['disc_number']}',
                                if (track['track_number'] != null)
                                  '第 ${track['track_number']} 首',
                              ]),
                              style: TextStyle(
                                color: tokens.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              current ? '当前收录' : '查看此收录与文件来源',
                              style: TextStyle(
                                color: current
                                    ? tokens.accent
                                    : tokens.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                            if (independent)
                              const Text(
                                '列表中独立展示',
                                style: TextStyle(fontSize: 12),
                              ),
                          ],
                        ),
                      ),
                      if (!compact) actions,
                      if (!current)
                        const Padding(
                          padding: EdgeInsets.only(top: 10),
                          child: Icon(Icons.chevron_right, size: 18),
                        ),
                    ],
                  ),
                ),
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [heading, if (compact) actions],
              );
            },
          ),
          if (current)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Divider(height: 16),
                  Text(
                    group == null
                        ? (mediaLoaded ? '尚未关联文件来源' : '文件来源尚未加载')
                        : '${copies.length} 个文件来源 · $available 个可用',
                    style: TextStyle(color: tokens.textSecondary, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  for (final copy in copies)
                    _SongSourceRow(copy: copy, connected: connected),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _SongSourceRow extends StatelessWidget {
  const _SongSourceRow({required this.copy, required this.connected});
  final Map<String, dynamic> copy;
  final bool connected;
  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final presence = replicaPresence(copy, coreConnected: connected);
    final color = presence == 'available'
        ? tokens.playing
        : tokens.textSecondary;
    final format =
        (copy['extension'] ?? copy['container'] ?? copy['codec'] ?? '')
            .toString()
            .toUpperCase();
    final properties = _joinParts([
      format,
      _audioResolutionLabel(copy),
      _formatBytes(copy['size_bytes']),
    ]);
    final status = Text(
      presence == 'available'
          ? '可用'
          : presence == 'offline'
          ? '离线'
          : '缺失',
      style: TextStyle(color: color, fontSize: 12),
    );
    final device = Text(
      copy['device_name']?.toString() ?? '未知设备',
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 12),
    );
    return Tooltip(
      message: _joinParts([
        copy['relative_path'] ?? copy['file_path'],
        _audioBitrateLabel(copy),
      ]),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: tokens.stroke)),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              Icon(
                presence == 'available'
                    ? Icons.check_circle_outline
                    : Icons.cloud_off_outlined,
                color: color,
                size: 15,
              ),
              const SizedBox(width: 8),
              if (constraints.maxWidth >= 450) ...[
                Expanded(child: device),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    properties,
                    style: TextStyle(fontSize: 12, color: tokens.textSecondary),
                  ),
                ),
              ] else
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      device,
                      const SizedBox(height: 3),
                      Text(
                        properties,
                        style: TextStyle(
                          fontSize: 11,
                          color: tokens.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(width: 10),
              status,
            ],
          ),
        ),
      ),
    );
  }
}
