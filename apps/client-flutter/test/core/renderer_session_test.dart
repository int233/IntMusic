import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/core/playback/renderer_session.dart';

class FakeEngine implements AudioEngine {
  final completedEvents = StreamController<bool>.broadcast(sync: true);
  final playingEvents = StreamController<bool>.broadcast(sync: true);
  final bufferingEvents = StreamController<bool>.broadcast(sync: true);
  final positionEvents = StreamController<Duration>.broadcast(sync: true);
  final errorEvents = StreamController<String>.broadcast(sync: true);
  Future<void> Function()? onOpen;
  bool disposed = false;
  int stops = 0;
  @override
  Stream<bool> get completed => completedEvents.stream;
  @override
  Stream<bool> get playing => playingEvents.stream;
  @override
  Stream<bool> get buffering => bufferingEvents.stream;
  @override
  Stream<Duration> get position => positionEvents.stream;
  @override
  Stream<String> get errors => errorEvents.stream;
  @override
  Future<void> open(String uri, {bool localFile = false}) async {
    playingEvents.add(true);
    if (onOpen != null) {
      await onOpen!();
    } else {
      advance(100);
    }
  }

  void advance(int ms) => positionEvents.add(Duration(milliseconds: ms));
  @override
  Future<void> play() async {
    playingEvents.add(true);
  }

  @override
  Future<void> pause() async {
    playingEvents.add(false);
  }

  @override
  Future<void> stop() async {
    stops++;
    playingEvents.add(false);
  }

  @override
  Future<void> seek(Duration position) async {
    positionEvents.add(position);
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<int?> currentPositionMs() async => 0;
  @override
  Future<int?> durationMs() async => 315360;
  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

void main() {
  late List<FakeEngine> engines;
  late RendererSession session;
  setUp(() {
    engines = [];
    session = RendererSession(
      createEngine: () async {
        final engine = FakeEngine();
        engines.add(engine);
        return engine;
      },
    );
  });
  tearDown(() async {
    await session.dispose();
  });

  test('open confirms decoded position, not a successful open call', () async {
    await session.open('core/track');
    expect(session.snapshot.phase, RendererPhase.playing);
    expect(session.snapshot.positionMs, 100);
  });
  test('playing flag without decoded progress times out and stops', () async {
    final engine = FakeEngine()..onOpen = () async {};
    final pending = RendererSession(
      createEngine: () async => engine,
      startTimeout: const Duration(milliseconds: 20),
    );
    await expectLater(
      pending.open('http-500'),
      throwsA(isA<TimeoutException>()),
    );
    expect(pending.snapshot.phase, RendererPhase.failed);
    expect(pending.snapshot.positionMs, 0);
    expect(engine.stops, 1);
    await pending.dispose();
  });
  test(
    'asynchronous decoder error fails startup instead of fake playing',
    () async {
      final engine = FakeEngine();
      engine.onOpen = () async {
        engine.errorEvents.add('HTTP 500');
      };
      final failing = RendererSession(createEngine: () async => engine);
      await expectLater(failing.open('bad-source'), throwsStateError);
      expect(failing.snapshot.phase, RendererPhase.failed);
      expect(failing.snapshot.error, contains('HTTP 500'));
      await failing.dispose();
    },
  );
  test(
    'EOF before any audio is a failure and never advances the queue',
    () async {
      final engine = FakeEngine();
      engine.onOpen = () async {
        engine.completedEvents.add(true);
      };
      final failing = RendererSession(createEngine: () async => engine);
      await expectLater(failing.open('empty-file'), throwsStateError);
      expect(failing.snapshot.phase, RendererPhase.failed);
      await failing.dispose();
    },
  );
  test('inactive audio is not EOF; actual EOF is delivered once', () async {
    final phases = <RendererPhase>[];
    final sub = session.states.listen((state) => phases.add(state.phase));
    await session.open('track');
    engines.single.playingEvents.add(false);
    expect(session.snapshot.phase, RendererPhase.buffering);
    expect(phases.where((p) => p == RendererPhase.completed), isEmpty);
    engines.single.completedEvents.add(true);
    engines.single.completedEvents.add(true);
    expect(phases.where((p) => p == RendererPhase.completed), hasLength(1));
    await sub.cancel();
  });
  test('replaced decoder cannot complete or fail the new track', () async {
    await session.open('first');
    final old = engines.single;
    await session.open('second');
    expect(old.disposed, isTrue);
    old.completedEvents.add(true);
    old.errorEvents.add('late failure');
    old.advance(999999);
    expect(session.snapshot.phase, RendererPhase.playing);
    expect(session.snapshot.positionMs, 100);
  });
  test('pause and seek do not emit completion or resume playback', () async {
    await session.open('track');
    await session.pause();
    engines.single.completedEvents.add(true);
    await session.seek(const Duration(seconds: 50));
    expect(session.snapshot.phase, RendererPhase.paused);
    expect(session.snapshot.positionMs, 50000);
    await session.play();
    expect(session.snapshot.phase, RendererPhase.loading);
    engines.single.advance(50100);
    expect(session.snapshot.phase, RendererPhase.playing);
  });
  test('seek backwards uses actual decoder position', () async {
    await session.open('track');
    engines.single.advance(20000);
    await session.seek(const Duration(seconds: 2));
    engines.single.advance(2100);
    expect(await session.currentPositionMs(), 2100);
  });
  test('manual stop isolates queued EOF and resets transport', () async {
    await session.open('track');
    await session.stop();
    engines.single.completedEvents.add(true);
    expect(session.snapshot.phase, RendererPhase.stopped);
    expect(session.snapshot.positionMs, 0);
  });
  test('lost progress is detected even when playing remains true', () async {
    final engine = FakeEngine();
    final stalled = RendererSession(
      createEngine: () async => engine,
      stallTimeout: Duration.zero,
    );
    await stalled.open('stalled');
    final failure = stalled.states.firstWhere(
      (s) => s.phase == RendererPhase.failed,
    );
    expect(
      (await failure.timeout(const Duration(seconds: 2))).error,
      contains('stopped advancing'),
    );
    await stalled.dispose();
  });
}
