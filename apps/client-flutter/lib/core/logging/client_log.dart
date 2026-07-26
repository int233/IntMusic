import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Lightweight, local-only JSON Lines diagnostics for the client.
///
/// Writes are serialized away from the playback path and the active log is
/// rotated before it grows beyond 5 MiB. No audio, artwork, credentials, or
/// request bodies are recorded.
class ClientLog {
  static const int _maxBytes = 5 * 1024 * 1024;
  static const int _retainedFiles = 3;
  static const int _maxPendingLines = 1024;
  static const int _writeBatchSize = 128;

  static bool _enabled = true;
  static File? _file;
  static int _estimatedBytes = 0;
  static int _sequence = 0;
  static final Queue<String> _pendingLines = ListQueue<String>();
  static int _droppedLines = 0;
  static bool _draining = false;
  static Future<void> _drainFuture = Future<void>.value();

  static String get path => _file?.path ?? '';

  static Future<void> initialize({required bool enabled}) async {
    _enabled = enabled;
    final support = await getApplicationSupportDirectory();
    final directory = Directory('${support.path}${Platform.pathSeparator}logs');
    await directory.create(recursive: true);
    _file = File(
      '${directory.path}${Platform.pathSeparator}client-playback.jsonl',
    );
    _estimatedBytes = await _file!.exists() ? await _file!.length() : 0;
    if (enabled) {
      event(
        'client.log.started',
        data: <String, Object?>{
          'platform': Platform.operatingSystem,
          'pid': pid,
        },
      );
    }
  }

  static void setEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    if (value) {
      event('client.log.enabled');
    }
  }

  static void event(
    String name, {
    String level = 'info',
    String? message,
    Map<String, Object?> data = const <String, Object?>{},
  }) {
    if (!_enabled || _file == null) return;
    final sanitized = <String, Object?>{
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'sequence': ++_sequence,
      'level': level,
      'event': name,
      if (message != null && message.isNotEmpty) 'message': message,
      if (data.isNotEmpty) 'data': _sanitize(data),
    };
    final line = '${jsonEncode(sanitized)}\n';
    if (_pendingLines.length >= _maxPendingLines) {
      _droppedLines += 1;
      if (level != 'error') {
        return;
      }
      _pendingLines.removeFirst();
    }
    _pendingLines.addLast(line);
    _startDrain();
  }

  static void error(
    String name,
    Object error, {
    StackTrace? stackTrace,
    Map<String, Object?> data = const <String, Object?>{},
  }) {
    event(
      name,
      level: 'error',
      message: error.toString(),
      data: <String, Object?>{
        ...data,
        if (stackTrace != null)
          'stack': stackTrace.toString().split('\n').take(12).join('\n'),
      },
    );
  }

  static Future<void> exportTo(String destinationPath) async {
    await _drainFuture.catchError((_) {});
    final source = _file;
    if (source == null || !await source.exists()) {
      await File(destinationPath).writeAsString(
        '${jsonEncode(<String, Object?>{'timestamp': DateTime.now().toUtc().toIso8601String(), 'event': 'client.log.empty'})}\n',
      );
      return;
    }
    await source.copy(destinationPath);
  }

  static void _startDrain() {
    if (_draining) return;
    _draining = true;
    _drainFuture = _drain()
        .catchError((_) {
          _droppedLines += _pendingLines.length;
          _pendingLines.clear();
        })
        .whenComplete(() {
          _draining = false;
          if (_pendingLines.isNotEmpty) {
            _startDrain();
          }
        });
  }

  static Future<void> _drain() async {
    while (_pendingLines.isNotEmpty || _droppedLines > 0) {
      final batch = <String>[];
      if (_droppedLines > 0) {
        final dropped = _droppedLines;
        _droppedLines = 0;
        batch.add(
          '${jsonEncode(<String, Object?>{
            'timestamp': DateTime.now().toUtc().toIso8601String(),
            'sequence': ++_sequence,
            'level': 'warning',
            'event': 'client.log.backpressure',
            'data': <String, Object?>{'dropped_events': dropped},
          })}\n',
        );
      }
      while (batch.length < _writeBatchSize && _pendingLines.isNotEmpty) {
        batch.add(_pendingLines.removeFirst());
      }
      final payload = batch.join();
      final bytes = utf8.encode(payload).length;
      await _rotateIfNeeded(bytes);
      await _file!.writeAsString(payload, mode: FileMode.append, flush: false);
      _estimatedBytes += bytes;
    }
  }

  static Future<void> _rotateIfNeeded(int incomingBytes) async {
    if (_estimatedBytes + incomingBytes <= _maxBytes) return;
    final file = _file!;
    for (var index = _retainedFiles - 1; index >= 1; index -= 1) {
      final current = File('${file.path}.$index');
      if (!await current.exists()) continue;
      if (index == _retainedFiles - 1) {
        await current.delete();
      } else {
        await current.rename('${file.path}.${index + 1}');
      }
    }
    if (await file.exists()) {
      await file.rename('${file.path}.1');
    }
    _estimatedBytes = 0;
  }

  static Object? _sanitize(Object? value) {
    if (value is Map) {
      return <String, Object?>{
        for (final entry in value.entries)
          entry.key.toString(): _sanitizeValue(
            entry.key.toString(),
            entry.value,
          ),
      };
    }
    if (value is Iterable) {
      return value.take(40).map(_sanitize).toList(growable: false);
    }
    return value;
  }

  static Object? _sanitizeValue(String key, Object? value) {
    final normalized = key.toLowerCase();
    if (normalized.contains('token') ||
        normalized.contains('password') ||
        normalized.contains('authorization')) {
      return '<redacted>';
    }
    if (value is String && value.length > 1200) {
      return '${value.substring(0, 1200)}…';
    }
    return _sanitize(value);
  }
}
