/// Distinguishes an unresponsive peer from a suspended or busy UI isolate.
class ConnectionWatchdog {
  ConnectionWatchdog(Duration now) : _lastTick = now, _lastPong = now;
  Duration _lastTick;
  Duration _lastPong;
  static const timeout = Duration(seconds: 18);
  static const schedulingGap = Duration(seconds: 9);

  void pong(Duration now) => _lastPong = now;

  /// After an Android scheduling pause, send a fresh probe before reconnecting.
  bool shouldReconnect(Duration now) {
    final gap = now - _lastTick;
    _lastTick = now;
    if (gap > schedulingGap) {
      _lastPong = now;
      return false;
    }
    return now - _lastPong > timeout;
  }
}
