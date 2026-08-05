part of '../intmusic_client.dart';

extension _DashboardTrackAvailability on _CoreDashboardState {
  void _refreshTrackAvailabilityProjection() {
    final ids = <int>{..._trackDetailCache.keys};
    for (final value in _tracks.whereType<Map>()) {
      final id = _intValue(value['id']);
      if (id != null) ids.add(id);
    }
    final projections = <int, Map<String, dynamic>>{
      for (final id in ids) id: _availabilityForTrack(id),
    };
    _trackAvailabilityById
      ..clear()
      ..addAll(projections);
    _trackAvailabilityPresenceSignature = _availabilityPresenceSignature();

    List<dynamic> decorateTracks(Object? value) =>
        ((value as List?) ?? const <dynamic>[])
            .map(_decorateTrackAvailability)
            .toList(growable: false);

    _tracks = decorateTracks(_tracks);
    for (final entry in _trackDetailCache.entries.toList(growable: false)) {
      _trackDetailCache[entry.key] = <String, dynamic>{
        ...entry.value,
        'track': _decorateTrackAvailability(entry.value['track']),
      };
    }
    for (final cache in <Map<int, Map<String, dynamic>>>[
      _albumDetailCache,
      _artistDetailCache,
      _playlistDetailCache,
    ]) {
      for (final entry in cache.entries.toList(growable: false)) {
        cache[entry.key] = <String, dynamic>{
          ...entry.value,
          'tracks': decorateTracks(entry.value['tracks']),
        };
      }
    }
    for (final entry in _searchResultCache.entries.toList(growable: false)) {
      _searchResultCache[entry.key] = <String, dynamic>{
        ...entry.value,
        'tracks': decorateTracks(entry.value['tracks']),
      };
    }
    final activeDetail = _activeTrackDetail;
    if (activeDetail != null) {
      _activeTrackDetail = <String, dynamic>{
        ...activeDetail,
        'track': _decorateTrackAvailability(activeDetail['track']),
      };
    }
    final queue = _playbackQueue;
    if (queue != null) {
      _playbackQueue = <String, dynamic>{
        ...queue,
        'items': ((queue['items'] as List?) ?? const <dynamic>[])
            .map((value) {
              if (value is! Map) return value;
              final item = value.cast<String, dynamic>();
              return <String, dynamic>{
                ...item,
                'track': _decorateTrackAvailability(item['track']),
              };
            })
            .toList(growable: false),
      };
    }
  }

  void _refreshTrackAvailabilityForTrack(int trackId) {
    _trackAvailabilityById[trackId] = _availabilityForTrack(trackId);
    _tracks = _replaceTrackAvailability(_tracks, trackId);
    final detail = _trackDetailCache[trackId];
    if (detail != null) {
      _trackDetailCache[trackId] = <String, dynamic>{
        ...detail,
        'track': _decorateTrackAvailability(detail['track']),
      };
    }
    for (final cache in <Map<int, Map<String, dynamic>>>[
      _albumDetailCache,
      _artistDetailCache,
      _playlistDetailCache,
    ]) {
      for (final entry in cache.entries.toList(growable: false)) {
        final tracks = (entry.value['tracks'] as List?) ?? const <dynamic>[];
        final updated = _replaceTrackAvailability(tracks, trackId);
        if (identical(tracks, updated)) continue;
        cache[entry.key] = <String, dynamic>{...entry.value, 'tracks': updated};
      }
    }
    for (final entry in _searchResultCache.entries.toList(growable: false)) {
      final tracks = (entry.value['tracks'] as List?) ?? const <dynamic>[];
      final updated = _replaceTrackAvailability(tracks, trackId);
      if (identical(tracks, updated)) continue;
      _searchResultCache[entry.key] = <String, dynamic>{
        ...entry.value,
        'tracks': updated,
      };
    }
    if (_activeTrackDetailId == trackId && _activeTrackDetail != null) {
      _activeTrackDetail = <String, dynamic>{
        ..._activeTrackDetail!,
        'track': _decorateTrackAvailability(_activeTrackDetail!['track']),
      };
    }
    _decoratePlaybackQueueAvailability();
  }

  void _decorateDetailTrackAvailability(
    Map<int, Map<String, dynamic>> cache,
    int detailId,
  ) {
    final detail = cache[detailId];
    if (detail == null) return;
    cache[detailId] = <String, dynamic>{
      ...detail,
      'tracks': ((detail['tracks'] as List?) ?? const <dynamic>[])
          .map(_decorateTrackAvailability)
          .toList(growable: false),
    };
  }

  void _decorateSearchTrackAvailability(String query) {
    final result = _searchResultCache[query];
    if (result == null) return;
    _searchResultCache[query] = <String, dynamic>{
      ...result,
      'tracks': ((result['tracks'] as List?) ?? const <dynamic>[])
          .map(_decorateTrackAvailability)
          .toList(growable: false),
    };
  }

  Map<String, dynamic> _decorateTrackAvailability(Object? value) {
    if (value is! Map) return <String, dynamic>{};
    final track = value.cast<String, dynamic>();
    final availability = _trackAvailabilityById[_intValue(track['id'])];
    return availability == null
        ? track
        : <String, dynamic>{...track, '_availability': availability};
  }

  List<dynamic> _replaceTrackAvailability(List<dynamic> tracks, int trackId) {
    var changed = false;
    final updated = tracks
        .map((value) {
          if (value is! Map || _intValue(value['id']) != trackId) return value;
          changed = true;
          return _decorateTrackAvailability(value);
        })
        .toList(growable: false);
    return changed ? updated : tracks;
  }

  void _refreshTrackAvailabilityIfPresenceChanged() {
    final signature = _availabilityPresenceSignature();
    if (signature == _trackAvailabilityPresenceSignature) return;
    _refreshTrackAvailabilityProjection();
  }

  void _decoratePlaybackQueueAvailability() {
    final queue = _playbackQueue;
    if (queue == null) return;
    _playbackQueue = <String, dynamic>{
      ...queue,
      'items': ((queue['items'] as List?) ?? const <dynamic>[])
          .map((value) {
            if (value is! Map) return value;
            final item = value.cast<String, dynamic>();
            final rawTrack = item['track'];
            if (rawTrack is! Map) return item;
            final track = rawTrack.cast<String, dynamic>();
            final availability = _trackAvailabilityById[_intValue(track['id'])];
            return <String, dynamic>{
              ...item,
              'track': availability == null
                  ? track
                  : <String, dynamic>{...track, '_availability': availability},
            };
          })
          .toList(growable: false),
    };
  }

  String _availabilityPresenceSignature() {
    final values = <String>[
      _offlineMode ? 'offline' : 'online',
      for (final zone in _zones.whereType<Map>())
        if (zone['is_online'] != false) 'z:${zone['id']}',
      for (final output in _outputs.whereType<Map>())
        if (output['is_online'] != false) 'o:${output['id']}',
      for (final status in _clientLibraryStatuses.whereType<Map>())
        'd:${status['device_id']}:${_statusIsRecentlyOnline(status)}',
    ]..sort();
    return values.join('|');
  }

  bool _statusIsRecentlyOnline(Map status) {
    final lastSeen = DateTime.tryParse(
      status['last_seen_at']?.toString() ?? '',
    )?.toUtc();
    return status['enabled'] == true &&
        lastSeen != null &&
        !lastSeen.isBefore(
          DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
        );
  }

  Map<String, dynamic> _availabilityForTrack(int trackId) {
    final detail = _trackDetailCache[trackId];
    Map<String, dynamic>? summary;
    for (final value in _tracks.whereType<Map>()) {
      if (_intValue(value['id']) == trackId) {
        summary = value.cast<String, dynamic>();
        break;
      }
    }
    final localCopyKnown = _offlineLibrary.track(trackId) != null;
    final localAvailable = _offlineMode
        ? summary != null && summary['_local_available'] == true
        : localCopyKnown;
    final replicas = <Map<String, dynamic>>[];
    final media = detail?['media'];
    if (media is Map) {
      for (final variant in (media['variants'] as List?) ?? const <dynamic>[]) {
        if (variant is! Map) continue;
        for (final replica
            in (variant['replicas'] as List?) ?? const <dynamic>[]) {
          if (replica is Map) {
            replicas.add(replica.cast<String, dynamic>());
          }
        }
      }
    }
    if (detail?['_client_local_copy'] case final Map localCopy) {
      replicas.add(localCopy.cast<String, dynamic>());
    }
    if (replicas.isEmpty &&
        (detail?['file_path']?.toString().trim() ?? '').isNotEmpty) {
      replicas.add(<String, dynamic>{
        'source_kind': 'core',
        'device_name': 'Core local',
        'availability_state': detail?['scan_status'] == 'missing'
            ? 'missing'
            : 'ready',
      });
    }

    final allSources = <String>{};
    final availableSources = <String>{};
    var availableCopies = 0;
    for (final replica in replicas) {
      final sourceKind = replica['source_kind']?.toString() ?? '';
      final deviceId = replica['device_id']?.toString();
      final source = sourceKind == 'core' || deviceId == null
          ? '__core__'
          : deviceId == _clientId
          ? '__this_device__'
          : (replica['device_name']?.toString().trim().isNotEmpty == true
                ? replica['device_name'].toString().trim()
                : deviceId);
      allSources.add(source);
      if (replica['availability_state']?.toString() != 'ready') continue;
      final reachable = _offlineMode
          ? source == '__this_device__' && localAvailable
          : source == '__core__' ||
                source == '__this_device__' ||
                _libraryDeviceIsOnline(deviceId);
      if (!reachable) continue;
      availableCopies += 1;
      availableSources.add(source);
    }
    if (localAvailable && !allSources.contains('__this_device__')) {
      allSources.add('__this_device__');
      availableSources.add('__this_device__');
      availableCopies += 1;
    }

    final state = availableSources.isNotEmpty
        ? 'available'
        : replicas.isEmpty && !_offlineMode
        ? 'checking'
        : 'unavailable';
    return <String, dynamic>{
      'state': state,
      'copy_count': max(replicas.length, allSources.length),
      'available_copy_count': availableCopies,
      'sources': availableSources.toList(growable: false),
      'all_sources': allSources.toList(growable: false),
    };
  }

  bool _libraryDeviceIsOnline(String? deviceId) {
    if (deviceId == null || deviceId.isEmpty) return false;
    if (deviceId == _clientId) return true;
    final rendererPrefix = 'renderer:$deviceId:';
    if (_outputs.whereType<Map>().any((output) {
      final outputId = output['id']?.toString() ?? '';
      return output['device_id']?.toString() == deviceId ||
          outputId.startsWith(rendererPrefix);
    })) {
      return true;
    }
    if (_zones.whereType<Map>().any((zone) {
      final zoneId = zone['id']?.toString() ?? '';
      return zone['is_online'] != false && zoneId.startsWith(rendererPrefix);
    })) {
      return true;
    }
    for (final value in _clientLibraryStatuses.whereType<Map>()) {
      if (value['device_id']?.toString() != deviceId) continue;
      return _statusIsRecentlyOnline(value);
    }
    return false;
  }
}

class _TrackAvailabilityBadge extends StatelessWidget {
  const _TrackAvailabilityBadge({required this.track, this.compact = false});

  final Map<String, dynamic> track;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final availability = track['_availability'];
    if (availability is! Map) return const SizedBox.shrink();
    final state = availability['state']?.toString() ?? 'checking';
    final sourceValues = (availability['sources'] as List?) ?? const [];
    final allSourceValues = (availability['all_sources'] as List?) ?? const [];
    final sources = sourceValues
        .map((value) => _availabilitySourceLabel(context, value.toString()))
        .toList(growable: false);
    final allSources = allSourceValues
        .map((value) => _availabilitySourceLabel(context, value.toString()))
        .toList(growable: false);
    final available = state == 'available';
    final checking = state == 'checking';
    final color = available
        ? const Color(0xff2ea978)
        : checking
        ? IntMusicTheme.of(context).textSecondary
        : Theme.of(context).colorScheme.error;
    final label = available
        ? sources.isEmpty
              ? _tr(context, 'Available')
              : sources.length == 1
              ? sources.first
              : '${sources.first} +${sources.length - 1}'
        : checking
        ? _tr(context, 'Checking')
        : _tr(context, 'Unavailable');
    final copies = _intValue(availability['copy_count']) ?? 0;
    final tooltip = available
        ? '${_tr(context, 'Available from')}: ${sources.join(', ')}'
        : allSources.isEmpty
        ? label
        : '${_tr(context, 'Stored on')}: ${allSources.join(', ')} · '
              '$copies ${_tr(context, 'copies')}';
    return Tooltip(
      message: tooltip,
      child: Container(
        constraints: BoxConstraints(maxWidth: compact ? 108 : 132),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 7 : 9,
          vertical: compact ? 3 : 4,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.11),
          border: Border.all(color: color.withValues(alpha: 0.28)),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              available
                  ? Icons.check_circle_rounded
                  : checking
                  ? Icons.sync_rounded
                  : Icons.cloud_off_rounded,
              size: compact ? 12 : 14,
              color: color,
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _availabilitySourceLabel(BuildContext context, String source) =>
    switch (source) {
      '__this_device__' => _tr(context, 'This device'),
      '__core__' => _tr(context, 'Core local'),
      _ => source,
    };
