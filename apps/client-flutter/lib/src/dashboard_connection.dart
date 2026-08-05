part of '../intmusic_client.dart';

extension _DashboardConnection on _CoreDashboardState {
  Future<void> _refreshZonesSilently() async {
    if (_zoneRefreshBusy) return;
    _zoneRefreshBusy = true;
    try {
      final zones = await _api.getCriticalJson('/zones') as List<dynamic>;
      _zoneRefreshFailures = 0;
      if (!mounted) {
        return;
      }
      _mutatePlayback(() {
        _zones = zones;
        _keepSelectedZoneValid();
        _syncPlaybackFromSelectedZone();
        _refreshTrackAvailabilityIfPresenceChanged();
      });
    } catch (_) {
      _zoneRefreshFailures += 1;
      if (!_offlineMode &&
          _zoneRefreshFailures >= 3 &&
          _offlineLibrary.copies.isNotEmpty) {
        await _activateOfflineMode();
      }
    } finally {
      _zoneRefreshBusy = false;
    }
  }

  Future<void> _connectEventStream({bool requestPlaybackSync = false}) async {
    final baseUrl = _coreUrlController.text.trim();
    if (_eventSocket != null && _eventSocketBaseUrl == baseUrl) {
      return;
    }
    if (_eventConnectBusy) return;
    _eventConnectBusy = true;

    try {
      await _eventSocket?.close();
      _eventReconnectTimer?.cancel();
      _eventSocket = null;
      _eventSocketBaseUrl = baseUrl;
      final socket = await WebSocket.connect(
        _api.wsUrl(
          '/ws/v1/events'
          '?renderer_id=${Uri.encodeQueryComponent(_clientId)}',
        ),
      ).timeout(const Duration(seconds: 8));
      final connectionGeneration = ++_eventConnectionGeneration;
      _rendererCommandSequences.clear();
      _latestRendererCommandIssuedAtByOutput.clear();
      _playbackStateSequenceByZone.clear();
      _eventSocket = socket;
      _eventLastPongAt = DateTime.now();
      ClientLog.event(
        'core.websocket.connected',
        data: <String, Object?>{
          'host': Uri.parse(baseUrl).host,
          'generation': connectionGeneration,
          'request_playback_sync': requestPlaybackSync,
        },
      );
      socket.listen(
        (message) => _handleCoreEvent(
          message,
          connectionGeneration: connectionGeneration,
        ),
        onDone: () {
          if (mounted && _eventSocket == socket) {
            _eventHealthTimer?.cancel();
            _mutate(() => _rendererStatus = 'Renderer disconnected');
            _eventSocket = null;
            ClientLog.event('core.websocket.closed', level: 'warning');
            unawaited(
              Future<void>.delayed(
                const Duration(milliseconds: 1200),
                () async {
                  if (mounted && _eventSocket == null) {
                    await _failoverActiveCoreStreams('core_websocket_closed');
                  }
                },
              ),
            );
            _scheduleEventReconnect(requestPlaybackSync: true);
          }
        },
        onError: (Object error) {
          if (mounted && _eventSocket == socket) {
            _eventHealthTimer?.cancel();
            _mutate(() => _rendererStatus = 'Renderer disconnected');
            _eventSocket = null;
            ClientLog.error('core.websocket.error', error);
            unawaited(
              Future<void>.delayed(
                const Duration(milliseconds: 1200),
                () async {
                  if (mounted && _eventSocket == null) {
                    await _failoverActiveCoreStreams('core_websocket_error');
                  }
                },
              ),
            );
            _scheduleEventReconnect(requestPlaybackSync: true);
          }
        },
      );
      _startEventHealthMonitor(socket, connectionGeneration);
      if (requestPlaybackSync) {
        unawaited(
          _sendRendererRegistration(requestPlaybackSync: true).catchError((
            Object error,
            StackTrace stackTrace,
          ) {
            ClientLog.error(
              'renderer.resync.failed',
              error,
              stackTrace: stackTrace,
            );
          }),
        );
      }
    } catch (error, stackTrace) {
      ClientLog.error(
        'core.websocket.connect_failed',
        error,
        stackTrace: stackTrace,
      );
      _eventSocket = null;
      _rendererStatus = 'Renderer offline';
      _scheduleEventReconnect(requestPlaybackSync: true);
    } finally {
      _eventConnectBusy = false;
    }
  }

  void _startEventHealthMonitor(WebSocket socket, int connectionGeneration) {
    _eventHealthTimer?.cancel();
    _eventHealthTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted ||
          _eventSocket != socket ||
          connectionGeneration != _eventConnectionGeneration) {
        _eventHealthTimer?.cancel();
        return;
      }
      final lastPongAt = _eventLastPongAt;
      if (lastPongAt != null &&
          DateTime.now().difference(lastPongAt) > const Duration(seconds: 9)) {
        unawaited(_restartEventStream('pong_timeout'));
        return;
      }
      try {
        final pingId = '$connectionGeneration-${++_eventPingSequence}';
        socket.add(
          jsonEncode(<String, Object?>{
            'type': 'client.ping',
            'ping_id': pingId,
            'client_time_ms': DateTime.now().millisecondsSinceEpoch,
          }),
        );
      } catch (error, stackTrace) {
        ClientLog.error(
          'core.websocket.ping_failed',
          error,
          stackTrace: stackTrace,
        );
        unawaited(_restartEventStream('ping_failed'));
      }
    });
  }

  Future<void> _restartEventStream(String reason) async {
    if (_eventRestartBusy || !mounted) return;
    _eventRestartBusy = true;
    final socket = _eventSocket;
    _eventSocket = null;
    _eventHealthTimer?.cancel();
    _eventConnectionGeneration += 1;
    ClientLog.event(
      'core.websocket.restarting',
      level: 'warning',
      data: <String, Object?>{'reason': reason},
    );
    try {
      await socket?.close(4000, reason).timeout(const Duration(seconds: 1));
    } catch (_) {
      // Closing a stalled socket is best effort.
    } finally {
      _eventRestartBusy = false;
      _scheduleEventReconnect(
        delay: const Duration(milliseconds: 250),
        requestPlaybackSync: true,
      );
    }
  }

  void _scheduleEventReconnect({
    Duration delay = const Duration(seconds: 3),
    bool requestPlaybackSync = true,
  }) {
    _eventReconnectTimer?.cancel();
    _eventReconnectTimer = Timer(delay, () {
      if (!_offlineMode && mounted) {
        unawaited(
          _connectEventStream(requestPlaybackSync: requestPlaybackSync),
        );
      }
    });
  }
}
