import 'dart:async';

abstract interface class AudioEngine {
  Stream<bool> get completed;
  Stream<bool> get playing;
  Stream<bool> get buffering;
  Stream<Duration> get position;
  Stream<String> get errors;
  Future<void> open(String uri, {bool localFile = false});
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<int?> currentPositionMs();
  Future<int?> durationMs();
  Future<void> dispose();
}

enum RendererPhase {
  stopped,
  loading,
  playing,
  paused,
  buffering,
  completed,
  failed,
}

class RendererSnapshot {
  const RendererSnapshot(
    this.generation,
    this.phase,
    this.positionMs, {
    this.error,
  });
  final int generation;
  final RendererPhase phase;
  final int positionMs;
  final String? error;
  String get transport => switch (phase) {
    RendererPhase.playing => 'playing',
    RendererPhase.paused => 'paused',
    RendererPhase.loading || RendererPhase.buffering => 'loading',
    _ => 'stopped',
  };
}

/// One output, one physical decoder, one observable lifecycle. Every source
/// creates a new decoder so late callbacks cannot affect a replacement track.
class RendererSession {
  RendererSession({
    required this.createEngine,
    this.startTimeout = const Duration(seconds: 12),
    this.stallTimeout = const Duration(seconds: 15),
  });
  final Future<AudioEngine> Function() createEngine;
  final Duration startTimeout;
  final Duration stallTimeout;
  final _states = StreamController<RendererSnapshot>.broadcast(sync: true);
  Stream<RendererSnapshot> get states => _states.stream;
  RendererSnapshot snapshot = const RendererSnapshot(
    0,
    RendererPhase.stopped,
    0,
  );
  AudioEngine? _engine;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  int _generation = 0;
  bool _disposed = false;
  bool _wantsPlay = false;
  bool _buffering = false;
  bool _advanced = false;
  double _volume = 1;
  DateTime _lastProgress = DateTime.now();
  Timer? _watchdog;
  Completer<void>? _started;

  bool _current(int generation) => !_disposed && generation == _generation;

  void _publish(RendererPhase phase, {int? positionMs, String? error}) {
    if (_disposed) return;
    if (snapshot.generation == _generation &&
        snapshot.phase == phase &&
        snapshot.positionMs == (positionMs ?? snapshot.positionMs) &&
        snapshot.error == error) {
      return;
    }
    snapshot = RendererSnapshot(
      _generation,
      phase,
      positionMs ?? snapshot.positionMs,
      error: error,
    );
    _states.add(snapshot);
  }

  Future<void> open(String uri, {bool localFile = false}) async {
    final generation = ++_generation;
    await _release();
    if (!_current(generation)) return;
    _wantsPlay = true;
    _buffering = false;
    _advanced = false;
    _lastProgress = DateTime.now();
    _publish(RendererPhase.loading, positionMs: 0);
    final started = Completer<void>();
    _started = started;
    // Install the error handler immediately, before the decoder can emit.
    final ready = started.future.timeout(startTimeout);
    unawaited(ready.catchError((Object _) {}));
    try {
      final engine = await createEngine();
      if (!_current(generation)) {
        await engine.dispose();
        return;
      }
      _engine = engine;
      _subscriptions.addAll([
        engine.errors.listen((error) {
          if (_current(generation)) _fail(error);
        }),
        engine.buffering.listen((value) {
          if (!_current(generation)) return;
          _buffering = value;
          if (_wantsPlay) {
            _publish(
              value
                  ? RendererPhase.buffering
                  : (_advanced ? RendererPhase.playing : RendererPhase.loading),
            );
          }
        }),
        engine.position.listen((position) {
          if (!_current(generation) || !_wantsPlay) return;
          final ms = position.inMilliseconds;
          if (ms > snapshot.positionMs) {
            _lastProgress = DateTime.now();
            _advanced = true;
            if (!started.isCompleted) started.complete();
          }
          _publish(
            _buffering
                ? RendererPhase.buffering
                : (_advanced ? RendererPhase.playing : RendererPhase.loading),
            positionMs: ms,
          );
        }),
        engine.completed.listen((completed) {
          if (!_current(generation) || !completed || !_wantsPlay) return;
          if (!_advanced) {
            _fail('Audio ended before decoding began');
            return;
          }
          _wantsPlay = false;
          _watchdog?.cancel();
          _publish(RendererPhase.completed);
        }),
        engine.playing.listen((playing) {
          if (!_current(generation) || playing || !_wantsPlay) return;
          // False may mean buffering or EOF. Never infer completion from it.
          _publish(RendererPhase.buffering);
        }),
      ]);
      _watchdog = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_current(generation) &&
            _wantsPlay &&
            DateTime.now().difference(_lastProgress) > stallTimeout) {
          _fail('Audio decoder stopped advancing');
        }
      });
      await engine.setVolume(_volume);
      await engine.open(uri, localFile: localFile).timeout(startTimeout);
      await ready;
    } catch (error) {
      if (_current(generation)) _fail(error.toString());
      rethrow;
    }
  }

  void _fail(String error) {
    if (!_wantsPlay) return;
    _wantsPlay = false;
    _watchdog?.cancel();
    final started = _started;
    if (started != null && !started.isCompleted) {
      started.completeError(StateError(error));
    }
    _publish(RendererPhase.failed, error: error);
    unawaited(
      _engine?.stop().catchError((Object _) {}) ?? Future<void>.value(),
    );
  }

  Future<void> play() async {
    if (_engine == null ||
        snapshot.phase == RendererPhase.failed ||
        snapshot.phase == RendererPhase.completed) {
      throw StateError('No playable audio source loaded');
    }
    _wantsPlay = true;
    _lastProgress = DateTime.now();
    _publish(RendererPhase.loading);
    await _engine!.play();
  }

  Future<void> pause() async {
    _wantsPlay = false;
    await _engine?.pause();
    _publish(RendererPhase.paused);
  }

  Future<void> stop() async {
    ++_generation;
    _wantsPlay = false;
    await _release();
    _publish(RendererPhase.stopped, positionMs: 0);
  }

  Future<void> seek(Duration position) async {
    _lastProgress = DateTime.now();
    await _engine?.seek(position);
    _publish(snapshot.phase, positionMs: position.inMilliseconds);
  }

  Future<void> setVolume(double value) async {
    _volume = value;
    await _engine?.setVolume(value);
  }

  Future<int?> currentPositionMs() async => snapshot.positionMs;
  Future<int?> durationMs() async => _engine?.durationMs();

  Future<void> _release() async {
    _watchdog?.cancel();
    final started = _started;
    _started = null;
    if (started != null && !started.isCompleted) {
      started.completeError(StateError('Source replaced'));
    }
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    final engine = _engine;
    _engine = null;
    await engine?.dispose();
  }

  Future<void> dispose() async {
    _disposed = true;
    ++_generation;
    await _release();
    await _states.close();
  }
}
