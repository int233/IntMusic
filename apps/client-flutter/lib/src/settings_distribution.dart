part of '../intmusic_client.dart';

class _TranscodingPanel extends StatelessWidget {
  const _TranscodingPanel({required this.status});

  final Map<String, dynamic>? status;

  @override
  Widget build(BuildContext context) {
    final available = status?['available'] == true;
    final enabled = status?['enabled'] != false;
    final profiles =
        (status?['profiles'] as List?)
            ?.whereType<Map>()
            .map((value) => value.cast<String, dynamic>())
            .where((value) => value['available'] == true)
            .toList() ??
        const <Map<String, dynamic>>[];
    final version = status?['version']?.toString();
    final cacheBytes = _intValue(status?['cache_bytes']) ?? 0;
    final maxCacheBytes = _intValue(status?['max_cache_bytes']) ?? 0;
    return _HomePanel(
      title: _tr(context, 'Transcoding engine'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color:
                      (available
                              ? IntMusicTheme.of(context).accent
                              : IntMusicTheme.of(context).textSecondary)
                          .withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  available
                      ? Icons.graphic_eq
                      : Icons.do_not_disturb_alt_outlined,
                  color: available
                      ? IntMusicTheme.of(context).accent
                      : IntMusicTheme.of(context).textSecondary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      !enabled
                          ? _tr(context, 'Disabled')
                          : available
                          ? version ?? 'FFmpeg'
                          : _tr(context, 'FFmpeg unavailable'),
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      available
                          ? '${_tr(context, 'Concurrent jobs')}: '
                                '${status?['max_concurrent_jobs'] ?? 1} · '
                                '${_tr(context, 'Cache')} '
                                '${_formatBytes(cacheBytes)} / '
                                '${_formatBytes(maxCacheBytes)}'
                          : status?['error']?.toString() ??
                                _tr(
                                  context,
                                  'Only original-quality distribution is available',
                                ),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: IntMusicTheme.of(context).textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (profiles.isNotEmpty) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final profile in profiles)
                  Chip(
                    avatar: Icon(
                      profile['lossless'] == true
                          ? Icons.hd_outlined
                          : profile['id'] == 'original'
                          ? Icons.file_present_outlined
                          : Icons.compress_outlined,
                      size: 17,
                    ),
                    label: Text(
                      _tr(
                        context,
                        profile['label']?.toString() ??
                            profile['id']?.toString() ??
                            '',
                      ),
                    ),
                  ),
              ],
            ),
          ],
          if (available) ...[
            const SizedBox(height: 12),
            Text(
              _tr(
                context,
                'Bundled FFmpeg uses LGPL v2.1 or later. License, build configuration, and corresponding source are included with Core.',
              ),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: IntMusicTheme.of(context).textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _DistributionJobsPanel extends StatelessWidget {
  const _DistributionJobsPanel({
    required this.jobs,
    required this.onRefresh,
    required this.onCancel,
  });

  final List<dynamic> jobs;
  final VoidCallback onRefresh;
  final ValueChanged<String> onCancel;

  @override
  Widget build(BuildContext context) {
    final values = jobs
        .whereType<Map>()
        .map((value) => value.cast<String, dynamic>())
        .take(20)
        .toList(growable: false);
    return _HomePanel(
      title: _tr(context, 'Library distribution'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _tr(
                    context,
                    'Core prepares and sends selected music to Client library folders.',
                  ),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: IntMusicTheme.of(context).textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: _tr(context, 'Refresh'),
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (values.isEmpty)
            Text(
              _tr(context, 'No distribution jobs'),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: IntMusicTheme.of(context).textSecondary,
              ),
            )
          else
            for (final job in values)
              _DistributionJobRow(job: job, onCancel: onCancel),
        ],
      ),
    );
  }
}

class _DistributionJobRow extends StatelessWidget {
  const _DistributionJobRow({required this.job, required this.onCancel});

  final Map<String, dynamic> job;
  final ValueChanged<String> onCancel;

  @override
  Widget build(BuildContext context) {
    final state = job['state']?.toString() ?? 'queued';
    final totalItems = _intValue(job['total_items']) ?? 0;
    final completedItems = _intValue(job['completed_items']) ?? 0;
    final failedItems = _intValue(job['failed_items']) ?? 0;
    final totalBytes = _intValue(job['total_bytes']) ?? 0;
    final transferredBytes = _intValue(job['transferred_bytes']) ?? 0;
    final terminal = const {
      'completed',
      'completed_with_errors',
      'cancelled',
    }.contains(state);
    final progress = totalBytes > 0
        ? (transferredBytes / totalBytes).clamp(0.0, 1.0)
        : totalItems > 0
        ? (completedItems / totalItems).clamp(0.0, 1.0)
        : null;
    final canCancel = !terminal;
    final error = job['error']?.toString();
    final color = switch (state) {
      'completed' => Colors.green,
      'completed_with_errors' ||
      'failed' => Theme.of(context).colorScheme.error,
      'cancelled' => IntMusicTheme.of(context).textSecondary,
      _ => IntMusicTheme.of(context).accent,
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: IntMusicTheme.of(context).surfaceRaised,
        border: Border.all(color: IntMusicTheme.of(context).stroke),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              terminal && state == 'completed'
                  ? Icons.check_circle_outline
                  : state == 'awaiting_source'
                  ? Icons.cloud_upload_outlined
                  : state == 'preparing' || state == 'transcoding'
                  ? Icons.auto_awesome_motion_outlined
                  : Icons.send_to_mobile_outlined,
              color: color,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _joinParts([
                    job['target_device_name'],
                    job['target_root_name'],
                  ]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 3),
                Text(
                  '${_distributionStateLabel(context, state)} · '
                  '${_tr(context, job['quality']?.toString() ?? 'original')} · '
                  '$completedItems/$totalItems'
                  '${failedItems > 0 ? ' · $failedItems ${_tr(context, 'failed')}' : ''}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: IntMusicTheme.of(context).textSecondary,
                  ),
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value:
                      state == 'awaiting_source' ||
                          state == 'preparing' ||
                          state == 'transcoding'
                      ? null
                      : progress,
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(99),
                ),
                if (error != null && error.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    error,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (canCancel)
            IconButton(
              tooltip: _tr(context, 'Cancel distribution'),
              onPressed: () => onCancel(job['id']?.toString() ?? ''),
              icon: const Icon(Icons.close),
            ),
        ],
      ),
    );
  }
}

String _distributionStateLabel(BuildContext context, String state) {
  return _tr(context, switch (state) {
    'awaiting_source' => 'Waiting for source Client',
    'preparing' || 'transcoding' => 'Preparing',
    'queued' => 'Waiting for Client',
    'transferring' => 'Transferring',
    'completed' => 'Completed',
    'completed_with_errors' => 'Completed with errors',
    'cancelled' => 'Cancelled',
    _ => state,
  });
}
