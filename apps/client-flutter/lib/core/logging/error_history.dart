import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Small, persistent error journal, independent of verbose diagnostics logging.
class ErrorHistory {
  static const maxEntries = 200;
  final entries = ValueNotifier<List<Map<String, Object?>>>(const []);
  final List<Map<String, Object?>> _items = [];
  File? _file;
  Timer? _saveTimer;
  bool _notificationPending = false;
  Future<void> _writes = Future.value();

  Future<void> initialize(Directory directory) async {
    if (_file != null) return;
    final file = File('${directory.path}${Platform.pathSeparator}errors.json');
    try {
      if (await file.exists() && await file.length() <= 2 * 1024 * 1024) {
        final stored = jsonDecode(await file.readAsString());
        if (stored is List) {
          _items.insertAll(
            0,
            stored.whereType<Map>().map(
              (value) => Map<String, Object?>.from(value),
            ),
          );
        }
      } else if (!await file.exists()) {
        await _importRecentErrors(directory);
      }
    } catch (_) {
      // A damaged journal must not prevent playback or recording new errors.
    }
    _file = file;
    _trim();
    _notify();
    if (_items.isNotEmpty) await flush();
  }

  void record(Map<String, Object?> event) {
    if (utf8.encode(jsonEncode(event)).length > 8000) {
      event = {
        ...event,
        'data': {'details': 'See exported diagnostics for full details.'},
      };
    }
    final now = DateTime.tryParse('${event['timestamp']}');
    final index = _items.lastIndexWhere((item) {
      final timestamp = DateTime.tryParse('${item['timestamp']}');
      return item['event'] == event['event'] &&
          item['message'] == event['message'] &&
          now != null &&
          timestamp != null &&
          now.difference(timestamp).abs() < const Duration(minutes: 1);
    });
    final previous = index < 0 ? null : _items.removeAt(index);
    _items.add({
      ...event,
      if (previous != null)
        'first_timestamp': previous['first_timestamp'] ?? previous['timestamp'],
      'count': ((previous?['count'] as num?)?.toInt() ?? 0) + 1,
    });
    _trim();
    _notify();
    if (_file != null) {
      _saveTimer ??= Timer(const Duration(milliseconds: 300), () {
        _saveTimer = null;
        unawaited(flush());
      });
    }
  }

  Future<void> _importRecentErrors(Directory directory) async {
    final log = File(
      '${directory.path}${Platform.pathSeparator}client-playback.jsonl',
    );
    if (!await log.exists()) return;
    final handle = await log.open();
    try {
      final length = await handle.length();
      await handle.setPosition(length > 512 * 1024 ? length - 512 * 1024 : 0);
      final tail = utf8.decode(
        await handle.read(512 * 1024),
        allowMalformed: true,
      );
      final imported = <Map<String, Object?>>[];
      for (final line in const LineSplitter().convert(tail)) {
        try {
          final value = jsonDecode(line);
          if (value is Map && value['level'] == 'error') {
            imported.add({...Map<String, Object?>.from(value), 'count': 1});
          }
        } catch (_) {
          // The bounded tail can start partway through a JSON line.
        }
      }
      _items.insertAll(0, imported);
    } finally {
      await handle.close();
    }
  }

  void _trim() {
    if (_items.length > maxEntries) {
      _items.removeRange(0, _items.length - maxEntries);
    }
  }

  void _notify() {
    if (_notificationPending) return;
    _notificationPending = true;
    scheduleMicrotask(() {
      _notificationPending = false;
      entries.value = List.unmodifiable(
        _items.reversed.map(
          (entry) => Map<String, Object?>.unmodifiable(entry),
        ),
      );
    });
  }

  Future<void> flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    final file = _file;
    if (file == null) return Future.value();
    final json = jsonEncode(_items);
    _writes = _writes
        .then((_) async {
          final temporary = File('${file.path}.tmp');
          await temporary.writeAsString(json, flush: true);
          await temporary.rename(file.path);
        })
        .catchError((Object _) {
          // Keep the in-memory history available when storage cannot be written.
        });
    return _writes;
  }
}
