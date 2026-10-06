import 'dart:async';
import 'dart:collection';
import 'dart:convert';

/// Bounded, best-effort delivery. Failed batches stay queued; playback never waits.
class LogUploader {
  LogUploader(this.send, {this.interval = const Duration(seconds: 10)});
  final Future<void> Function(List<Map<String, Object?>>) send;
  final Duration interval;
  final _pending = Queue<Map<String, Object?>>();
  Timer? _timer;
  bool _enabled = false, _busy = false;
  int _generation = 0;
  int get pendingCount => _pending.length;

  void setEnabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    _generation++;
    _timer?.cancel();
    _pending.clear();
    if (value) _timer = Timer.periodic(interval, (_) => unawaited(flush()));
  }

  void add(Map<String, Object?> event) {
    if (!_enabled) return;
    final data = event['data'];
    if (data is Map &&
        data['path'].toString().contains('/diagnostics/clients')) {
      return;
    }
    if (utf8.encode(jsonEncode(event)).length > 3500) {
      event = {
        'event': event['event'],
        'timestamp': event['timestamp'],
        'level': event['level'],
        'sequence': event['sequence'],
        'message': 'Large diagnostic event omitted from remote upload',
      };
    }
    if (_pending.length == 256) _pending.removeFirst();
    _pending.add(Map<String, Object?>.unmodifiable(event));
  }

  Future<void> flush() async {
    if (!_enabled || _busy || _pending.isEmpty) return;
    _busy = true;
    final generation = _generation;
    final batch = _pending.take(32).toList();
    try {
      await send(batch).timeout(const Duration(seconds: 5));
      if (generation == _generation) {
        // New events can evict old ones while a batch is in flight.
        final acknowledged = batch.toSet();
        _pending.removeWhere(acknowledged.contains);
      }
    } catch (_) {
      // Never feed upload failures back into the log upload queue.
    } finally {
      _busy = false;
    }
  }

  void dispose() {
    setEnabled(false);
    _timer?.cancel();
  }
}
