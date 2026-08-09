part of '../intmusic_client.dart';

extension _DashboardDistribution on _CoreDashboardState {
  Future<void> _distributeTracks(List<int> trackIds) async {
    final uniqueTrackIds = trackIds.where((id) => id > 0).toSet().toList()
      ..sort();
    if (uniqueTrackIds.isEmpty || !mounted) {
      return;
    }
    if (_localPlaybackFallbackActive) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _tr(context, 'Connect to Core before distributing music'),
          ),
        ),
      );
      return;
    }
    final targets = _clientLibraryStatuses
        .whereType<Map>()
        .map((value) => value.cast<String, dynamic>())
        .where(
          (value) =>
              value['enabled'] != false &&
              value['device_id'] != null &&
              value['external_id'] != null,
        )
        .toList(growable: false);
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _tr(
              context,
              'Add and sync a Client music folder before distributing music',
            ),
          ),
        ),
      );
      return;
    }
    String targetKey(Map<String, dynamic> target) =>
        '${target['device_id']}\u0000${target['external_id']}';
    final currentTarget = targets
        .where((target) => target['device_id']?.toString() == _clientId)
        .firstOrNull;
    var selectedTarget = targetKey(currentTarget ?? targets.first);
    final rawProfiles =
        (_transcodingStatus?['profiles'] as List?)?.whereType<Map>().toList() ??
        const <Map>[];
    final profiles = rawProfiles
        .map((value) => value.cast<String, dynamic>())
        .where((profile) => profile['available'] == true)
        .toList();
    if (!profiles.any((profile) => profile['id'] == 'original')) {
      profiles.insert(0, <String, dynamic>{
        'id': 'original',
        'label': 'Original',
        'codec': 'source',
        'container': 'source',
        'lossless': false,
        'available': true,
      });
    }
    var selectedQuality = profiles.first['id']?.toString() ?? 'original';
    final selection = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final selectedProfile = profiles
              .where((profile) => profile['id']?.toString() == selectedQuality)
              .firstOrNull;
          return AlertDialog(
            title: Text(_tr(context, 'Distribute music')),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    uniqueTrackIds.length == 1
                        ? _tr(context, 'Send one track to a Client library')
                        : '${_tr(context, 'Send')} '
                              '${uniqueTrackIds.length} '
                              '${_tr(context, 'tracks to a Client library')}',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: IntMusicTheme.of(context).textSecondary,
                    ),
                  ),
                  const SizedBox(height: 18),
                  DropdownButtonFormField<String>(
                    initialValue: selectedTarget,
                    decoration: InputDecoration(
                      labelText: _tr(context, 'Destination'),
                      prefixIcon: const Icon(Icons.devices_outlined),
                    ),
                    items: [
                      for (final target in targets)
                        DropdownMenuItem(
                          value: targetKey(target),
                          child: Text(
                            _joinParts([
                              target['device_name'],
                              target['display_name'],
                              target['platform'],
                            ]),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => selectedTarget = value);
                      }
                    },
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    initialValue: selectedQuality,
                    decoration: InputDecoration(
                      labelText: _tr(context, 'Quality'),
                      prefixIcon: const Icon(Icons.high_quality_outlined),
                    ),
                    items: [
                      for (final profile in profiles)
                        DropdownMenuItem(
                          value: profile['id']?.toString(),
                          child: Text(
                            _tr(
                              context,
                              profile['label']?.toString() ??
                                  profile['id']?.toString() ??
                                  'Original',
                            ),
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => selectedQuality = value);
                      }
                    },
                  ),
                  if (selectedProfile != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _distributionProfileDescription(selectedProfile),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: IntMusicTheme.of(context).textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(_tr(context, 'Cancel')),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(dialogContext, {
                  'target': selectedTarget,
                  'quality': selectedQuality,
                }),
                icon: const Icon(Icons.send_outlined),
                label: Text(_tr(context, 'Send')),
              ),
            ],
          );
        },
      ),
    );
    if (selection == null || !mounted) {
      return;
    }
    final selected = targets
        .where((target) => targetKey(target) == selection['target'])
        .firstOrNull;
    if (selected == null) {
      return;
    }
    try {
      await _api.postJson('/distributions', <String, dynamic>{
        'target_device_id': selected['device_id']?.toString(),
        'target_root_external_id': selected['external_id']?.toString(),
        'quality': selection['quality'] ?? 'original',
        'track_ids': uniqueTrackIds,
        'album_ids': const <int>[],
        'playlist_ids': const <int>[],
      });
      await _refreshDistributionJobs();
      unawaited(_pollDistributionTasks());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${_tr(context, 'Distribution created')} · '
            '${selected['device_name']} / ${selected['display_name']}',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${_tr(context, 'Distribution failed')}: $error'),
        ),
      );
    }
  }

  String _distributionProfileDescription(Map<String, dynamic> profile) {
    if (profile['id'] == 'original') {
      return _tr(
        context,
        'Copies the existing file without changing its codec or quality.',
      );
    }
    final bitrate = _intValue(profile['bitrate_kbps']);
    return _joinParts([
      profile['codec']?.toString().toUpperCase(),
      profile['container']?.toString().toUpperCase(),
      bitrate == null ? null : '$bitrate kbps',
      profile['lossless'] == true ? _tr(context, 'Lossless') : null,
    ]);
  }

  Future<void> _cancelDistributionJob(String jobId) async {
    try {
      await _api.postJson(
        '/distributions/${Uri.encodeComponent(jobId)}/cancel',
        const <String, dynamic>{},
      );
      await _refreshDistributionJobs();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${_tr(context, 'Cancel failed')}: $error')),
      );
    }
  }

  Future<void> _pollDistributionTasks() async {
    if (_distributionWorkerBusy ||
        _localPlaybackFallbackActive ||
        _clientLibrarySyncingRootIds.isNotEmpty) {
      return;
    }
    _distributionWorkerBusy = true;
    var runAgain = false;
    try {
      final sourceValue = await _api.getJson(
        '/distributions/source-tasks/next'
        '?device_id=${Uri.encodeQueryComponent(_clientId)}',
      );
      if (sourceValue is Map) {
        await _executeDistributionSourceTask(
          sourceValue.cast<String, dynamic>(),
        );
        runAgain = true;
        return;
      }
      final value = await _api.getJson(
        '/distributions/tasks/next'
        '?device_id=${Uri.encodeQueryComponent(_clientId)}',
      );
      if (value is Map) {
        await _executeDistributionTask(value.cast<String, dynamic>());
        runAgain = true;
      } else if (_distributionDirtyRootIds.isNotEmpty) {
        final dirtyRoots = _distributionDirtyRootIds.toList(growable: false);
        _distributionDirtyRootIds.clear();
        for (final rootId in dirtyRoots) {
          await _syncClientLibraryRoot(rootId, refreshAfter: false);
        }
        await _refreshDistributionJobs();
      }
    } catch (_) {
      // A transient Core failure is retried by the next worker tick.
    } finally {
      _distributionWorkerBusy = false;
      if (runAgain) {
        unawaited(_pollDistributionTasks());
      }
    }
  }

  Future<void> _executeDistributionSourceTask(Map<String, dynamic> task) async {
    final taskId = task['id']?.toString();
    final rootId = task['source_root_external_id']?.toString();
    final relativePath = task['source_relative_path']?.toString();
    final uploadPath = task['upload_path']?.toString();
    final expectedSize = _intValue(task['expected_size_bytes']);
    if (taskId == null ||
        rootId == null ||
        relativePath == null ||
        uploadPath == null ||
        expectedSize == null ||
        expectedSize < 0) {
      return;
    }
    final root = _clientLibraryRoots
        .where((candidate) => candidate.externalId == rootId)
        .firstOrNull;
    final sourcePath = root == null
        ? null
        : _distributionTargetPath(root, relativePath);
    if (root == null || sourcePath == null) {
      await _reportDistributionSourceFailure(
        taskId,
        'The source folder is no longer configured on this Client.',
        retryable: false,
      );
      return;
    }

    try {
      if (mounted) {
        _mutate(
          () => _rendererStatus =
              'Sending ${task['title']?.toString() ?? relativePath}',
        );
      }
      final uploadUrl = _api.apiUrl(
        '$uploadPath?device_id=${Uri.encodeQueryComponent(_clientId)}',
      );
      final uploaded = Platform.isAndroid
          ? await _IntMusicPlatform.instance.uploadDistributionSource(
              apiUrl: uploadUrl,
              taskId: taskId,
              rootToken: root.accessToken,
              relativePath: relativePath,
              expectedSize: expectedSize,
            )
          : await _uploadDistributionSourceFile(
              uploadUrl: uploadUrl,
              sourcePath: sourcePath,
              expectedSize: expectedSize,
            );
      if (uploaded != expectedSize) {
        throw FileSystemException(
          'Uploaded source size does not match the catalog.',
          sourcePath,
        );
      }
      if (mounted) {
        _mutate(() => _rendererStatus = 'Source item sent');
      }
      await _refreshDistributionJobs();
    } catch (error) {
      await _reportDistributionSourceFailure(
        taskId,
        error.toString(),
        retryable: true,
      );
    }
  }

  Future<int> _uploadDistributionSourceFile({
    required String uploadUrl,
    required String sourcePath,
    required int expectedSize,
  }) async {
    final source = File(sourcePath);
    final actualSize = await source.length();
    if (actualSize != expectedSize) {
      throw FileSystemException(
        'The local source changed after its last library sync.',
        sourcePath,
      );
    }
    final client = HttpClient();
    try {
      final request = await client.putUrl(Uri.parse(uploadUrl));
      request.contentLength = expectedSize;
      request.headers.contentType = ContentType.binary;
      await request.addStream(source.openRead());
      final response = await request.close();
      final responseText = await utf8.decoder.bind(response).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          responseText.isEmpty
              ? 'Core rejected the source upload (${response.statusCode}).'
              : responseText,
          uri: Uri.parse(uploadUrl),
        );
      }
      return actualSize;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _reportDistributionSourceFailure(
    String taskId,
    String error, {
    required bool retryable,
  }) async {
    try {
      await _api.postJson(
        '/distributions/source-tasks/${Uri.encodeComponent(taskId)}/progress',
        <String, dynamic>{
          'device_id': _clientId,
          'state': 'failed',
          'transferred_bytes': 0,
          'retryable': retryable,
          'error': error,
        },
      );
    } catch (_) {
      // The source lease recovers the task if the failure report is lost.
    }
    if (mounted) {
      _mutate(() => _rendererStatus = 'Source distribution failed: $error');
    }
    await _refreshDistributionJobs();
  }

  Future<void> _executeDistributionTask(Map<String, dynamic> task) async {
    final taskId = task['id']?.toString();
    final rootId = task['target_root_external_id']?.toString();
    final relativePath = task['relative_path']?.toString();
    final contentPath = task['content_path']?.toString();
    final expectedSize = _intValue(task['expected_size_bytes']);
    if (taskId == null ||
        rootId == null ||
        relativePath == null ||
        contentPath == null ||
        expectedSize == null ||
        expectedSize < 0) {
      return;
    }
    final root = _clientLibraryRoots
        .where((candidate) => candidate.externalId == rootId)
        .firstOrNull;
    if (root == null) {
      await _reportDistributionFailure(
        taskId,
        0,
        'The target folder is no longer configured on this Client.',
        retryable: false,
      );
      return;
    }
    final targetPath = _distributionTargetPath(root, relativePath);
    if (targetPath == null) {
      await _reportDistributionFailure(
        taskId,
        0,
        'Core returned an unsafe distribution path.',
        retryable: false,
      );
      return;
    }

    var transferred = 0;
    try {
      if (mounted) {
        _mutate(
          () => _rendererStatus =
              'Receiving ${task['title']?.toString() ?? relativePath}',
        );
      }
      Future<void> reportProgress(int bytes) async {
        transferred = bytes;
        try {
          await _api.postJson(
            '/distributions/tasks/${Uri.encodeComponent(taskId)}/progress',
            <String, dynamic>{
              'device_id': _clientId,
              'state': 'progress',
              'transferred_bytes': bytes,
              'retryable': true,
              'error': null,
            },
          );
        } catch (_) {
          // Completion or the durable lease will reconcile missed heartbeats.
        }
      }

      final result = Platform.isAndroid
          ? await _IntMusicPlatform.instance.downloadDistributionTask(
              apiUrl: _api.apiUrl(
                '$contentPath?device_id=${Uri.encodeQueryComponent(_clientId)}',
              ),
              taskId: taskId,
              rootToken: root.accessToken,
              relativePath: relativePath,
              expectedSize: expectedSize,
              expectedQuickHash: task['expected_quick_hash']?.toString(),
            )
          : await _downloadDistributionFile(
              api: _api,
              contentPath: contentPath,
              deviceId: _clientId,
              taskId: taskId,
              targetPath: targetPath,
              expectedSize: expectedSize,
              expectedQuickHash: task['expected_quick_hash']?.toString(),
              onProgress: reportProgress,
            );
      transferred = result.bytes;
      await _api.postJson(
        '/distributions/tasks/${Uri.encodeComponent(taskId)}/progress',
        <String, dynamic>{
          'device_id': _clientId,
          'state': 'completed',
          'transferred_bytes': result.bytes,
          'retryable': false,
          'error': null,
        },
      );
      _distributionDirtyRootIds.add(rootId);
      if (mounted) {
        _mutate(() => _rendererStatus = 'Distribution item completed');
      }
      await _refreshDistributionJobs();
    } catch (error) {
      await _reportDistributionFailure(
        taskId,
        transferred,
        error.toString(),
        retryable: true,
      );
    }
  }

  Future<void> _reportDistributionFailure(
    String taskId,
    int transferred,
    String error, {
    required bool retryable,
  }) async {
    try {
      await _api.postJson(
        '/distributions/tasks/${Uri.encodeComponent(taskId)}/progress',
        <String, dynamic>{
          'device_id': _clientId,
          'state': 'failed',
          'transferred_bytes': transferred,
          'retryable': retryable,
          'error': error,
        },
      );
    } catch (_) {
      // The Core lease recovers tasks when an error report cannot be delivered.
    }
    if (mounted) {
      _mutate(() => _rendererStatus = 'Distribution failed: $error');
    }
    await _refreshDistributionJobs();
  }
}
