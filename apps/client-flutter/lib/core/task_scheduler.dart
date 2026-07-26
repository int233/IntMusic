import 'dart:async';

typedef ScheduledTaskCallback = FutureOr<void> Function();
typedef ScheduledTaskErrorHandler =
    void Function(Object error, StackTrace stackTrace);

/// Owns periodic application work and guarantees that a task never overlaps
/// with an earlier invocation of the same task.
///
/// Keeping timers here makes lifecycle behavior explicit and prevents feature
/// controllers from each growing their own timer, busy flag, and disposal
/// logic.
class PeriodicTaskScheduler {
  final Map<String, _PeriodicTask> _tasks = <String, _PeriodicTask>{};
  bool _backgrounded = false;
  bool _disposed = false;

  Iterable<String> get taskNames => _tasks.keys;

  void schedule(
    String name, {
    required Duration interval,
    required ScheduledTaskCallback callback,
    bool runImmediately = false,
    bool runInBackground = false,
    ScheduledTaskErrorHandler? onError,
  }) {
    if (_disposed) {
      throw StateError('PeriodicTaskScheduler has been disposed.');
    }
    cancel(name);
    final task = _PeriodicTask(
      interval: interval,
      callback: callback,
      runInBackground: runInBackground,
      isBackgrounded: () => _backgrounded,
      onError: onError,
    );
    _tasks[name] = task;
    task.start(runImmediately: runImmediately);
  }

  void cancel(String name) {
    _tasks.remove(name)?.dispose();
  }

  void setBackgrounded(bool value) {
    if (_disposed || value == _backgrounded) return;
    _backgrounded = value;
    if (!value) {
      for (final task in _tasks.values) {
        task.triggerAfterResume();
      }
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final task in _tasks.values) {
      task.dispose();
    }
    _tasks.clear();
  }
}

class _PeriodicTask {
  _PeriodicTask({
    required this.interval,
    required this.callback,
    required this.runInBackground,
    required this.isBackgrounded,
    this.onError,
  });

  final Duration interval;
  final ScheduledTaskCallback callback;
  final bool runInBackground;
  final bool Function() isBackgrounded;
  final ScheduledTaskErrorHandler? onError;

  Timer? _timer;
  bool _running = false;
  bool _disposed = false;

  void start({required bool runImmediately}) {
    _timer = Timer.periodic(interval, (_) => _trigger());
    if (runImmediately) {
      _trigger();
    }
  }

  void triggerAfterResume() {
    if (!_running) {
      _trigger();
    }
  }

  void _trigger() {
    if (_disposed || _running || (!runInBackground && isBackgrounded())) {
      return;
    }
    _running = true;
    Future<void>.sync(callback)
        .catchError((Object error, StackTrace stackTrace) {
          onError?.call(error, stackTrace);
        })
        .whenComplete(() => _running = false);
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
