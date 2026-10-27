import 'network/core_api_client.dart';
import 'playback_agent.dart';

/// Transfers an independently running queue to Core without opening the decoder.
/// The caller keeps local authority until the entire transfer is acknowledged.
Future<({PlaybackAgent agent, Map<String, dynamic> snapshot})?>
adoptLocalPlayback({
  required CoreApiClient api,
  required String outputId,
  required String deviceId,
  required Map<String, dynamic> queue,
  required int positionMs,
  required bool paused,
  required String Function() newCommandId,
}) async {
  final local = PlaybackAgent(outputId)..restore(queue);
  final index = local.currentIndex;
  if (index == null ||
      local.items.isEmpty ||
      local.items.any((item) => item.trackId <= 0)) {
    return null;
  }
  final selected = local.items[index];
  final prefix = '/playback-v3/zones/${Uri.encodeComponent(outputId)}';
  final remote = PlaybackAgent(outputId)
    ..restoreSession(
      Map<String, dynamic>.from(
        await api.getCriticalJson('$prefix/session') as Map,
      ),
    );
  Map<String, dynamic>? latest;
  Future<void> send(Map<String, dynamic> action) async {
    final command = remote.command(
      commandId: newCommandId(),
      originDeviceId: deviceId,
      action: action,
    );
    final ack = Map<String, dynamic>.from(
      await api.postControlJson('$prefix/commands', command) as Map,
    );
    final status = remote.applyAck(ack);
    if (status != 'applied' && status != 'duplicate') {
      throw StateError(
        'Local playback transfer was not acknowledged: ${ack['error_code']}',
      );
    }
    latest = Map<String, dynamic>.from(ack['snapshot'] as Map);
  }

  await send({
    'type': 'replace_queue_and_play',
    'items': [
      for (final item in local.items)
        {
          'item_id': item.itemId,
          'track_id': item.trackId,
          'added_by_device_id': deviceId,
          'added_at': DateTime.now().toUtc().toIso8601String(),
        },
    ],
    'start_item_id': selected.itemId,
    'position_ms': positionMs,
  });
  await send({
    'type': 'set_mode',
    'mode': {
      'repeat': local.repeatMode,
      'shuffle': local.shuffle,
      'stop_after_current': local.stopAfterCurrent,
    },
  });
  if (paused) await send({'type': 'pause'});
  return (agent: remote, snapshot: latest!);
}
