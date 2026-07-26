part of '../intmusic_client.dart';

extension _DashboardNavigation on _CoreDashboardState {
  Future<void> _reportRendererShutdown() async {
    final outputIds = <String>{
      ..._rendererAudioDevicesByOutput.keys,
      ..._rendererPlaybackByOutput.keys,
    };
    final api = CoreApiClient(_coreUrlController.text);
    for (final outputId in outputIds) {
      try {
        await api.postJson(
          '/renderers/${Uri.encodeComponent(_clientId)}/state',
          <String, dynamic>{
            'output_id': outputId,
            'state': 'stopped',
            'track_id': null,
            'track_title': null,
            'position_ms': 0,
          },
        );
      } catch (_) {
        // Process shutdown is best-effort; the core TTL handles hard kills.
      }
    }
  }

  _AppRoute get _currentRoute => _navigation.current;
  int get _selectedDestinationIndex => _currentRoute.destinationIndex ?? -1;
  bool get _canNavigateBack => _navigation.canGoBack;
  bool get _canNavigateForward => _navigation.canGoForward;

  void _navigateToInState(
    _AppRoute route, {
    bool addToHistory = true,
    int? transitionDirection,
  }) {
    final previous = _currentRoute;
    if (previous == route) {
      return;
    }
    _pageTransitionDirection =
        transitionDirection ??
        (route.animationOrder >= previous.animationOrder ? 1 : -1);
    if (addToHistory) {
      _navigation.navigateTo(route);
    } else {
      _navigation.replace(route);
    }
  }

  void _setSelectedIndex(int index) {
    _navigateTo(_AppRoute.destination(index));
  }

  void _navigateTo(_AppRoute route) {
    _mutate(() => _navigateToInState(route));
  }

  void _navigateBack() {
    if (!_canNavigateBack) return;
    _mutate(() {
      _navigation.goBack();
      _pageTransitionDirection = -1;
    });
  }

  void _navigateForward() {
    if (!_canNavigateForward) return;
    _mutate(() {
      _navigation.goForward();
      _pageTransitionDirection = 1;
    });
  }

  void _closeDetailPage() {
    if (_canNavigateBack) {
      _navigateBack();
    } else {
      _navigateTo(const _AppRoute.home());
    }
  }
}
