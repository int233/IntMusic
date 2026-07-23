import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart' as ap;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/app_theme.dart';

part 'src/app_shared.dart';
part 'src/app_shell.dart';
part 'src/home_page.dart';
part 'src/library_pages.dart';
part 'src/playback_page.dart';
part 'src/history_page.dart';
part 'src/playlist_pages.dart';
part 'src/settings_page.dart';
part 'src/search_page.dart';
part 'src/detail_sheets.dart';
part 'src/core_api_client.dart';
part 'src/core_discovery.dart';
part 'src/i18n.dart';
part 'src/platform_integration.dart';
part 'src/renderer_audio.dart';

const _prefsCoreUrlKey = 'intmusic.core_url';
const _prefsLanguageKey = 'intmusic.language';
const _prefsClientAliasKey = 'intmusic.client_alias';
const _prefsAlbumViewModeKey = 'intmusic.view.albums';
const _prefsArtistViewModeKey = 'intmusic.view.artists';
const _prefsTrackViewModeKey = 'intmusic.view.tracks';
const _prefsPlaylistViewModeKey = 'intmusic.view.playlists';
const _prefsRecentSearchesKey = 'intmusic.search.recent';
final CacheManager _artworkCacheManager = CacheManager(
  Config(
    'intmusicArtworkCache',
    stalePeriod: const Duration(days: 90),
    maxNrOfCacheObjects: 12000,
  ),
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (_usesDesktopRendererBackend) {
    MediaKit.ensureInitialized();
  }
  PaintingBinding.instance.imageCache.maximumSizeBytes = 128 * 1024 * 1024;
  PaintingBinding.instance.imageCache.maximumSize = 700;
  runApp(const IntMusicClientApp());
}

class IntMusicClientApp extends StatelessWidget {
  const IntMusicClientApp({super.key, this.enableAudioRenderer = true});

  final bool enableAudioRenderer;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'IntMusic',
      debugShowCheckedModeBanner: false,
      theme: buildIntMusicTheme(brightness: Brightness.light),
      darkTheme: buildIntMusicTheme(),
      themeMode: Platform.isMacOS ? ThemeMode.system : ThemeMode.dark,
      home: CoreDashboard(enableAudioRenderer: enableAudioRenderer),
      builder: (context, child) {
        if (child == null) {
          return const SizedBox.shrink();
        }
        return _WindowsA11yQuiet(child: child);
      },
    );
  }
}

class CoreDashboard extends StatefulWidget {
  const CoreDashboard({super.key, this.enableAudioRenderer = true});

  final bool enableAudioRenderer;

  @override
  State<CoreDashboard> createState() => _CoreDashboardState();
}

class _CoreDashboardState extends State<CoreDashboard>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final _coreUrlController = TextEditingController(
    text: 'http://127.0.0.1:49330',
  );
  final _searchController = TextEditingController();
  final _serverAliasController = TextEditingController();
  final _clientAliasController = TextEditingController();
  final _libraryRootController = TextEditingController();
  final Map<String, Future<_RendererAudioPlayer>> _audioPlayers = {};
  final Map<String, StreamSubscription<bool>> _audioCompleteSubscriptions = {};
  final Map<String, AudioDevice> _rendererAudioDevicesByOutput = {};
  final Map<String, Map<String, dynamic>> _rendererPlaybackByOutput = {};
  final Map<String, int> _rendererLoadedTrackByOutput = {};
  Player? _rendererDeviceProbe;
  StreamSubscription<List<AudioDevice>>? _rendererDeviceSubscription;
  Future<void>? _rendererAudioInitialization;
  Timer? _rendererHeartbeat;
  Timer? _rendererPositionReporter;
  Timer? _zoneRefreshTimer;
  Timer? _searchDebounce;
  WebSocket? _eventSocket;
  String? _eventSocketBaseUrl;
  String? _rendererRegisteredCoreUrl;
  SharedPreferences? _preferences;
  _AppRoute _currentRoute = const _AppRoute.home();
  final List<_AppRoute> _backStack = [];
  final List<_AppRoute> _forwardStack = [];
  bool _loading = false;
  String? _error;
  String? _rendererStatus;
  _AppLanguage _language = _AppLanguage.en;
  _PlaybackMode _playbackMode = _PlaybackMode.sequential;
  String _selectedZoneId = 'local';
  String _selectedZoneLabel = 'Core local';
  Map<String, dynamic>? _status;
  Map<String, dynamic>? _diagnostics;
  Map<String, dynamic>? _serverSettings;
  Map<String, dynamic>? _playback;
  Map<String, dynamic>? _playbackQueue;
  Map<String, dynamic>? _activeTrackDetail;
  final Map<int, Map<String, dynamic>> _trackDetailCache = {};
  final Map<int, Map<String, dynamic>> _albumDetailCache = {};
  final Map<int, Map<String, dynamic>> _artistDetailCache = {};
  final Map<int, Map<String, dynamic>> _playlistDetailCache = {};
  final Map<String, Map<String, dynamic>> _searchResultCache = {};
  Map<String, dynamic>? _playbackStats;
  int? _activeTrackDetailId;
  List<dynamic> _albums = const [];
  List<dynamic> _artists = const [];
  List<dynamic> _tracks = const [];
  List<dynamic> _outputs = const [];
  List<dynamic> _zones = const [];
  List<dynamic> _playlists = const [];
  List<dynamic> _libraryRoots = const [];
  List<dynamic> _playbackHistory = const [];
  Map<String, dynamic>? _favoriteSettings;
  Map<String, dynamic>? _metadataSettings;
  String _searchQuery = '';
  final Map<String, _SearchScope> _searchScopeByQuery = {};
  final Map<String, _SearchSort> _searchSortByQuery = {};
  _LibraryViewMode _albumViewMode = _LibraryViewMode.grid;
  _LibraryViewMode _artistViewMode = _LibraryViewMode.grid;
  _LibraryViewMode _trackViewMode = _LibraryViewMode.list;
  _LibraryViewMode _playlistViewMode = _LibraryViewMode.grid;
  List<_SearchSuggestion> _searchSuggestions = const [];
  List<String> _recentSearches = const [];
  late final AnimationController _playbackRevealController;
  int _pageTransitionDirection = 1;

  CoreApiClient get _api => CoreApiClient(_coreUrlController.text);
  String get _clientId => _sanitizeRendererId(
    'flutter-${Platform.operatingSystem}-${Platform.localHostname}',
  );
  String get _clientOutputId => 'renderer:$_clientId:default';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _playbackRevealController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      reverseDuration: const Duration(milliseconds: 190),
    );
    _rendererAudioInitialization = widget.enableAudioRenderer
        ? _initializeRendererAudio()
        : Future<void>.sync(() {
            _rendererAudioDevicesByOutput[_clientOutputId] = AudioDevice.auto();
          });
    _selectedZoneId = _clientOutputId;
    _selectedZoneLabel = 'This device';
    _clientAliasController.text = _defaultClientAlias();
    unawaited(_initializeAndRefresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _rendererHeartbeat?.cancel();
    _rendererPositionReporter?.cancel();
    _zoneRefreshTimer?.cancel();
    _searchDebounce?.cancel();
    unawaited(_reportRendererShutdown());
    unawaited(_eventSocket?.close() ?? Future<void>.value());
    for (final subscription in _audioCompleteSubscriptions.values) {
      unawaited(subscription.cancel());
    }
    unawaited(_rendererDeviceSubscription?.cancel() ?? Future<void>.value());
    final rendererDeviceProbe = _rendererDeviceProbe;
    if (rendererDeviceProbe != null) {
      unawaited(rendererDeviceProbe.dispose().catchError((_) {}));
    }
    for (final playerFuture in _audioPlayers.values) {
      unawaited(
        playerFuture
            .then((player) => player.dispose())
            .catchError((Object _) {}),
      );
    }
    _coreUrlController.dispose();
    _searchController.dispose();
    _serverAliasController.dispose();
    _clientAliasController.dispose();
    _libraryRootController.dispose();
    _playbackRevealController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      unawaited(_reportRendererShutdown());
    }
  }

  Future<void> _refreshAll() async {
    await _run<void>(() => _refreshAllInner(allowDiscovery: true));
  }

  Future<void> _initializeAndRefresh() async {
    await _rendererAudioInitialization;
    await _IntMusicPlatform.instance.initialize(
      onCommand: _handlePlatformCommand,
      onSeek: _seekPlayback,
    );
    await _loadSavedCoreUrl();
    await _refreshAll();
  }

  Future<void> _handlePlatformCommand(_PlatformCommand command) async {
    switch (command) {
      case _PlatformCommand.play:
        await _resumePlayback();
      case _PlatformCommand.pause:
        await _pausePlayback();
      case _PlatformCommand.togglePlayPause:
        if (_playback?['state']?.toString() == 'playing') {
          await _pausePlayback();
        } else {
          await _resumePlayback();
        }
      case _PlatformCommand.previous:
        await _playPreviousTrack();
      case _PlatformCommand.next:
        await _playNextTrack();
      case _PlatformCommand.stop:
        await _stopZone(_activeZoneId());
      case _PlatformCommand.showWindow:
        await _IntMusicPlatform.instance.showWindow();
      case _PlatformCommand.quit:
        await SystemNavigator.pop();
    }
  }

  Future<void> _loadSavedCoreUrl() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      _preferences = preferences;
      final savedUrl = preferences.getString(_prefsCoreUrlKey)?.trim();
      final savedLanguage = preferences.getString(_prefsLanguageKey)?.trim();
      final savedClientAlias = preferences
          .getString(_prefsClientAliasKey)
          ?.trim();
      final language = _languageFromPreference(savedLanguage);
      final albumViewMode = _viewModeFromPreference(
        preferences.getString(_prefsAlbumViewModeKey),
      );
      final artistViewMode = _viewModeFromPreference(
        preferences.getString(_prefsArtistViewModeKey),
      );
      final trackViewMode = _viewModeFromPreference(
        preferences.getString(_prefsTrackViewModeKey),
        fallback: _LibraryViewMode.list,
      );
      final playlistViewMode = _viewModeFromPreference(
        preferences.getString(_prefsPlaylistViewModeKey),
      );
      final recentSearches =
          preferences.getStringList(_prefsRecentSearchesKey) ?? const [];
      if (!mounted) {
        return;
      }
      setState(() {
        if (savedUrl != null && savedUrl.isNotEmpty) {
          _coreUrlController.text = savedUrl;
        }
        if (language != null) {
          _language = language;
        }
        _albumViewMode = albumViewMode;
        _artistViewMode = artistViewMode;
        _trackViewMode = trackViewMode;
        _playlistViewMode = playlistViewMode;
        _recentSearches = recentSearches.take(10).toList(growable: false);
        _clientAliasController.text = savedClientAlias?.isNotEmpty == true
            ? savedClientAlias!
            : _defaultClientAlias();
      });
    } catch (_) {
      // Preferences are optional; discovery can still find the core.
    }
  }

  Future<void> _saveCoreUrlPreference() async {
    try {
      final preferences = _preferences ?? await SharedPreferences.getInstance();
      _preferences = preferences;
      await preferences.setString(
        _prefsCoreUrlKey,
        _coreUrlController.text.trim(),
      );
    } catch (_) {
      // A failed preference write should not break playback control.
    }
  }

  _AppLanguage? _languageFromPreference(String? value) {
    return switch (value) {
      'zh' => _AppLanguage.zh,
      'en' => _AppLanguage.en,
      _ => null,
    };
  }

  _LibraryViewMode _viewModeFromPreference(
    String? value, {
    _LibraryViewMode fallback = _LibraryViewMode.grid,
  }) {
    return switch (value) {
      'list' => _LibraryViewMode.list,
      'grid' => _LibraryViewMode.grid,
      _ => fallback,
    };
  }

  void _setLibraryViewMode(
    String preferenceKey,
    _LibraryViewMode mode,
    void Function(_LibraryViewMode mode) apply,
  ) {
    setState(() => apply(mode));
    unawaited(_persistLibraryViewMode(preferenceKey, mode));
  }

  Future<void> _persistLibraryViewMode(
    String preferenceKey,
    _LibraryViewMode mode,
  ) async {
    try {
      final preferences = _preferences ?? await SharedPreferences.getInstance();
      _preferences = preferences;
      await preferences.setString(preferenceKey, mode.name);
    } catch (_) {
      // View preferences are non-critical and remain valid for this session.
    }
  }

  Future<void> _setLanguage(_AppLanguage language) async {
    setState(() => _language = language);
    try {
      final preferences = _preferences ?? await SharedPreferences.getInstance();
      _preferences = preferences;
      await preferences.setString(_prefsLanguageKey, language.name);
    } catch (_) {
      // Language can still change for the current session.
    }
  }

  String _defaultClientAlias() => '${Platform.localHostname} Client';

  String _clientAlias() {
    final alias = _clientAliasController.text.trim();
    return alias.isEmpty ? _defaultClientAlias() : alias;
  }

  Future<void> _saveClientAlias() async {
    final alias = _clientAliasController.text.trim();
    _clientAliasController.text = alias.isEmpty ? _defaultClientAlias() : alias;
    try {
      final preferences = _preferences ?? await SharedPreferences.getInstance();
      _preferences = preferences;
      await preferences.setString(_prefsClientAliasKey, _clientAlias());
    } catch (_) {
      // The renderer can still advertise the alias for the current session.
    }
    await _sendRendererRegistration();
    await _refreshZonesSilently();
  }

  Future<void> _saveServerAlias() async {
    final alias = _serverAliasController.text.trim();
    final serverSettings = await _run<Map<String, dynamic>>(
      () async => _asMap(
        await _api.postJson('/settings/server', <String, dynamic>{
          'alias': alias,
        }),
      ),
    );
    if (!mounted || serverSettings == null) {
      return;
    }
    final status = await _run<Map<String, dynamic>>(
      () async => _asMap(await _api.getJson('/status')),
    );
    final zones = await _run<List<dynamic>>(
      () async => await _api.getJson('/zones') as List<dynamic>,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _serverSettings = serverSettings;
      _serverAliasController.text =
          serverSettings['alias']?.toString() ??
          status?['display_name']?.toString() ??
          'Core local';
      if (status != null) {
        _status = status;
      }
      if (zones != null) {
        _zones = zones;
        _keepSelectedZoneValid();
        _syncPlaybackFromSelectedZone();
      }
    });
  }

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

  int get _selectedDestinationIndex => _currentRoute.destinationIndex ?? -1;
  bool get _canNavigateBack => _backStack.isNotEmpty;
  bool get _canNavigateForward => _forwardStack.isNotEmpty;

  void _navigateToInState(
    _AppRoute route, {
    bool addToHistory = true,
    int? transitionDirection,
  }) {
    if (_currentRoute == route) {
      return;
    }
    _pageTransitionDirection =
        transitionDirection ??
        (route.animationOrder >= _currentRoute.animationOrder ? 1 : -1);
    if (addToHistory) {
      _backStack.add(_currentRoute);
      if (_backStack.length > 100) {
        _backStack.removeAt(0);
      }
      _forwardStack.clear();
    }
    _currentRoute = route;
  }

  void _setSelectedIndex(int index) {
    _navigateTo(_AppRoute.destination(index));
  }

  void _navigateTo(_AppRoute route) {
    setState(() => _navigateToInState(route));
  }

  void _navigateBack() {
    if (_backStack.isEmpty) {
      return;
    }
    setState(() {
      final route = _backStack.removeLast();
      _forwardStack.add(_currentRoute);
      _navigateToInState(route, addToHistory: false, transitionDirection: -1);
    });
  }

  void _navigateForward() {
    if (_forwardStack.isEmpty) {
      return;
    }
    setState(() {
      final route = _forwardStack.removeLast();
      _backStack.add(_currentRoute);
      _navigateToInState(route, addToHistory: false, transitionDirection: 1);
    });
  }

  void _closeDetailPage() {
    if (_canNavigateBack) {
      _navigateBack();
    } else {
      _navigateTo(const _AppRoute.home());
    }
  }

  Future<void> _discoverAndRefresh() async {
    await _run<void>(() => _refreshAllInner(forceDiscovery: true));
  }

  Future<void> _refreshAllInner({
    bool allowDiscovery = false,
    bool forceDiscovery = false,
  }) async {
    if (forceDiscovery) {
      final discovered = await _applyDiscoveredCoreUrl();
      if (!discovered) {
        throw StateError('No IntMusic core found on the local network');
      }
    }

    try {
      await _refreshFromCurrentCore();
    } catch (error) {
      if (!allowDiscovery || forceDiscovery) {
        rethrow;
      }
      final discovered = await _applyDiscoveredCoreUrl();
      if (!discovered) {
        rethrow;
      }
      await _refreshFromCurrentCore();
    }
  }

  Future<bool> _applyDiscoveredCoreUrl() async {
    _rendererStatus = 'Discovering core';
    final cores = await _discoverIntMusicCores(
      hintBaseUrl: _coreUrlController.text,
    );
    if (cores.isEmpty) {
      return false;
    }
    final selected = cores.first;
    _coreUrlController.text = selected.baseUrl;
    _rendererStatus = 'Discovered ${selected.source}';
    return true;
  }

  Future<void> _refreshFromCurrentCore() async {
    final status = _asMap(await _api.getJson('/status'));
    if (!_isIntMusicCoreStatus(status)) {
      throw StateError('Not an IntMusic core: ${_coreUrlController.text}');
    }
    await _saveCoreUrlPreference();
    final coreUrl = _coreUrlController.text.trim();
    await _sendRendererRegistration(
      resetPlayback: _rendererRegisteredCoreUrl != coreUrl,
    );
    _rendererRegisteredCoreUrl = coreUrl;
    await _connectEventStream();
    _startRendererHeartbeat();
    _startRendererPositionReporter();
    _startZoneRefresh();
    final results = await Future.wait([
      _loadPagedList('/albums'),
      _loadPagedList('/artists'),
      _loadPagedList('/tracks'),
      _api.getJson('/outputs'),
      _api.getJson('/zones'),
      _api.getJson('/diagnostics'),
      _api.getJson('/settings/server'),
      _api.getJson('/playback/stats?top_limit=20'),
      _api.getJson('/playback/history?limit=100'),
      _api.getJson('/playlists'),
      _api.getJson('/settings/favorites'),
      _api.getJson('/settings/metadata'),
      _api.getJson('/library/roots'),
    ]);
    _status = status;
    _albums = results[0] as List<dynamic>;
    _artists = results[1] as List<dynamic>;
    _tracks = results[2] as List<dynamic>;
    _outputs = results[3] as List<dynamic>;
    _zones = results[4] as List<dynamic>;
    _diagnostics = _asMap(results[5]);
    _serverSettings = _asMap(results[6]);
    _serverAliasController.text =
        _serverSettings?['alias']?.toString() ??
        status['display_name']?.toString() ??
        'Core local';
    _playbackStats = _asMap(results[7]);
    _playbackHistory = results[8] as List<dynamic>;
    _playlists = results[9] as List<dynamic>;
    _favoriteSettings = _asMap(results[10]);
    _metadataSettings = _asMap(results[11]);
    _libraryRoots = results[12] as List<dynamic>;
    _keepSelectedZoneValid();
    _syncPlaybackFromSelectedZone();
    await _refreshPlaybackQueue();
    _scheduleActiveTrackDetailLoad(_playback);
  }

  Future<List<dynamic>> _loadPagedList(
    String path, {
    int pageSize = 500,
  }) async {
    final items = <dynamic>[];
    for (var offset = 0; ; offset += pageSize) {
      final separator = path.contains('?') ? '&' : '?';
      final page =
          await _api.getJson('$path${separator}limit=$pageSize&offset=$offset')
              as List<dynamic>;
      items.addAll(page);
      if (page.length < pageSize) {
        break;
      }
    }
    return items;
  }

  Future<void> _sendRendererRegistration({bool resetPlayback = false}) async {
    await _rendererAudioInitialization;
    final outputPrefix = 'renderer:$_clientId:';
    final rendererOutputs = _rendererAudioDevicesByOutput.entries
        .map((entry) {
          final device = entry.value;
          final localOutputId = entry.key.startsWith(outputPrefix)
              ? entry.key.substring(outputPrefix.length)
              : entry.key;
          return <String, dynamic>{
            'id': localOutputId,
            'name': _rendererAudioDeviceLabel(device),
            'backend': _usesDesktopRendererBackend
                ? 'media-kit-libmpv'
                : 'flutter-audioplayers',
            'is_default': localOutputId == 'default',
            'sample_rates': <int>[],
            'channels': <int>[],
          };
        })
        .toList(growable: false);
    await _api.postJson('/renderers/register', <String, dynamic>{
      'client_id': _clientId,
      'name': _clientAlias(),
      'platform': Platform.operatingSystem,
      'reset_playback': resetPlayback,
      'outputs': rendererOutputs,
    });
    _rendererStatus = 'Renderer online';
  }

  bool get _supportsIndependentAudioOutputs => _usesDesktopRendererBackend;

  Future<void> _initializeRendererAudio() async {
    _rendererAudioDevicesByOutput[_clientOutputId] = AudioDevice.auto();
    if (!_supportsIndependentAudioOutputs) {
      return;
    }

    final ready = Completer<void>();
    final probe = Player(
      configuration: PlayerConfiguration(
        title: 'IntMusic audio device discovery',
        ready: () {
          if (!ready.isCompleted) {
            ready.complete();
          }
        },
      ),
    );
    _rendererDeviceProbe = probe;
    _rendererDeviceSubscription = probe.stream.audioDevices.listen(
      _updateRendererAudioDevices,
      onError: (_) {
        // The default output remains available if native discovery fails.
      },
    );

    try {
      await ready.future.timeout(const Duration(seconds: 4));
    } on TimeoutException {
      // Some libmpv builds publish the device list without invoking ready.
    }
    _updateRendererAudioDevices(probe.state.audioDevices);
  }

  void _updateRendererAudioDevices(List<AudioDevice> devices) {
    final next = <String, AudioDevice>{_clientOutputId: AudioDevice.auto()};
    final seenNativeNames = <String>{};
    for (final device in devices) {
      final nativeName = device.name.trim();
      final normalizedName = nativeName.toLowerCase();
      if (nativeName.isEmpty ||
          normalizedName == 'auto' ||
          normalizedName == 'no' ||
          !_isNativeRendererAudioDevice(normalizedName) ||
          !seenNativeNames.add(nativeName)) {
        continue;
      }
      next[_rendererOutputIdForDevice(device)] = device;
    }

    final previousSignature = _rendererDeviceSignature(
      _rendererAudioDevicesByOutput,
    );
    final nextSignature = _rendererDeviceSignature(next);
    if (previousSignature == nextSignature) {
      return;
    }

    final removedOutputIds = _rendererAudioDevicesByOutput.keys
        .where((outputId) => !next.containsKey(outputId))
        .toList(growable: false);
    _rendererAudioDevicesByOutput
      ..clear()
      ..addAll(next);
    for (final outputId in removedOutputIds) {
      unawaited(_disposeRendererPlayer(outputId));
      _rendererPlaybackByOutput.remove(outputId);
      _rendererLoadedTrackByOutput.remove(outputId);
    }

    if (_rendererRegisteredCoreUrl != null) {
      unawaited(
        _sendRendererRegistration()
            .then((_) => _refreshZonesSilently())
            .catchError((Object _) {}),
      );
    }
  }

  bool _isNativeRendererAudioDevice(String normalizedName) {
    if (Platform.isWindows) {
      return normalizedName.startsWith('wasapi/');
    }
    if (Platform.isMacOS) {
      return normalizedName.startsWith('coreaudio/');
    }
    return true;
  }

  String _rendererDeviceSignature(Map<String, AudioDevice> devices) {
    final entries =
        devices.entries
            .map(
              (entry) =>
                  '${entry.key}\u0000${entry.value.name}\u0000'
                  '${entry.value.description}',
            )
            .toList()
          ..sort();
    return entries.join('\u0001');
  }

  String _rendererOutputIdForDevice(AudioDevice device) {
    final encodedName = base64Url
        .encode(utf8.encode(device.name))
        .replaceAll('=', '');
    return 'renderer:$_clientId:device-$encodedName';
  }

  String _rendererAudioDeviceLabel(AudioDevice device) {
    if (device.name == 'auto') {
      return 'System Default';
    }
    final description = device.description.trim();
    return description.isEmpty ? device.name : description;
  }

  void _startRendererHeartbeat() {
    _rendererHeartbeat?.cancel();
    _rendererHeartbeat = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(
        _sendRendererRegistration().catchError((Object error) {
          if (mounted) {
            setState(() => _rendererStatus = 'Renderer offline');
          }
        }),
      );
    });
  }

  void _startRendererPositionReporter() {
    _rendererPositionReporter?.cancel();
    _rendererPositionReporter = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_reportRendererPositions().catchError((_) {}));
    });
  }

  void _startZoneRefresh() {
    _zoneRefreshTimer?.cancel();
    _zoneRefreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      unawaited(_refreshZonesSilently());
    });
  }

  Future<void> _refreshZonesSilently() async {
    try {
      final zones = await _api.getJson('/zones') as List<dynamic>;
      if (!mounted) {
        return;
      }
      setState(() {
        _zones = zones;
        _keepSelectedZoneValid();
        _syncPlaybackFromSelectedZone();
      });
    } catch (_) {
      // The main refresh path owns visible connection errors.
    }
  }

  Future<void> _connectEventStream() async {
    final baseUrl = _coreUrlController.text.trim();
    if (_eventSocket != null && _eventSocketBaseUrl == baseUrl) {
      return;
    }

    await _eventSocket?.close();
    _eventSocket = null;
    _eventSocketBaseUrl = baseUrl;

    try {
      final socket = await WebSocket.connect(_api.wsUrl('/ws/v1/events'));
      _eventSocket = socket;
      socket.listen(
        _handleCoreEvent,
        onDone: () {
          if (mounted && _eventSocket == socket) {
            setState(() => _rendererStatus = 'Renderer disconnected');
            _eventSocket = null;
          }
        },
        onError: (Object error) {
          if (mounted && _eventSocket == socket) {
            setState(() => _rendererStatus = 'Renderer disconnected');
            _eventSocket = null;
          }
        },
      );
    } catch (_) {
      _eventSocket = null;
      _rendererStatus = 'Renderer offline';
    }
  }

  Future<_RendererAudioPlayer> _playerForOutput(String outputId) async {
    final existing = _audioPlayers[outputId];
    if (existing != null) {
      return existing;
    }
    final future = _createRendererPlayer(outputId);
    _audioPlayers[outputId] = future;
    try {
      return await future;
    } catch (_) {
      if (identical(_audioPlayers[outputId], future)) {
        _audioPlayers.remove(outputId);
      }
      rethrow;
    }
  }

  Future<_RendererAudioPlayer> _createRendererPlayer(String outputId) async {
    final device = _rendererAudioDevicesByOutput[outputId];
    if (device == null) {
      throw StateError('audio output is no longer available: $outputId');
    }
    _RendererAudioPlayer? player;
    try {
      if (_usesDesktopRendererBackend) {
        final mediaKitPlayer = Player(
          configuration: const PlayerConfiguration(title: 'IntMusic'),
        );
        player = _MediaKitRendererAudioPlayer(mediaKitPlayer);
        await mediaKitPlayer.setAudioDevice(device);
      } else {
        final mobilePlayer = ap.AudioPlayer();
        await mobilePlayer.setReleaseMode(ap.ReleaseMode.stop);
        player = _MobileRendererAudioPlayer(mobilePlayer);
      }
      _audioCompleteSubscriptions[outputId] = player.completed
          .where((completed) => completed)
          .listen((_) {
            unawaited(_handleOutputComplete(outputId).catchError((_) {}));
          });
      return player;
    } catch (_) {
      await _audioCompleteSubscriptions.remove(outputId)?.cancel();
      await player?.dispose();
      rethrow;
    }
  }

  Future<void> _disposeRendererPlayer(String outputId) async {
    final subscription = _audioCompleteSubscriptions.remove(outputId);
    await subscription?.cancel();
    final playerFuture = _audioPlayers.remove(outputId);
    if (playerFuture == null) {
      return;
    }
    try {
      final player = await playerFuture;
      await player.stop();
      await player.dispose();
    } catch (_) {
      // The renderer may already have failed because the device disappeared.
    }
  }

  Future<void> _handleOutputComplete(String outputId) async {
    await _reportRendererState('stopped', outputId: outputId);
  }

  bool _isClientOutputId(String? outputId) =>
      outputId != null && _rendererAudioDevicesByOutput.containsKey(outputId);

  Future<void> _startScan() async {
    await _run<void>(() async {
      await _api.postJson('/scan/start', <String, dynamic>{});
      await _refreshAll();
    });
  }

  Future<void> _addLibraryRoot() async {
    final path = _libraryRootController.text.trim();
    if (path.isEmpty) {
      setState(() => _error = 'Music folder path is empty');
      return;
    }
    final result = await _run<Map<String, dynamic>>(() async {
      await _api.postJson('/library/roots', <String, dynamic>{'path': path});
      return _refreshLibrarySettingsPayload();
    });
    if (!mounted || result == null) {
      return;
    }
    setState(() {
      _libraryRootController.clear();
      _applyLibrarySettingsPayload(result);
    });
  }

  Future<void> _removeLibraryRoot(int id) async {
    final result = await _run<Map<String, dynamic>>(() async {
      await _api.deleteJson('/library/roots/$id');
      return _refreshLibrarySettingsPayload();
    });
    if (!mounted || result == null) {
      return;
    }
    setState(() => _applyLibrarySettingsPayload(result));
  }

  Future<Map<String, dynamic>> _refreshLibrarySettingsPayload() async {
    final results = await Future.wait([
      _api.getJson('/library/roots'),
      _api.getJson('/status'),
      _api.getJson('/diagnostics'),
    ]);
    return <String, dynamic>{
      'roots': results[0],
      'status': results[1],
      'diagnostics': results[2],
    };
  }

  void _applyLibrarySettingsPayload(Map<String, dynamic> result) {
    _libraryRoots = (result['roots'] as List?) ?? const [];
    _status = _asMap(result['status']);
    _diagnostics = _asMap(result['diagnostics']);
  }

  Future<Map<String, dynamic>> _loadSearch(String query, {int limit = 25}) {
    return _api
        .getJson('/search?q=${Uri.encodeQueryComponent(query)}&limit=$limit')
        .then(_asMap);
  }

  void _onSearchChanged(String value) {
    final query = value.trim();
    _searchDebounce?.cancel();
    if (query.isEmpty) {
      setState(() => _searchSuggestions = const []);
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 260), () {
      unawaited(_loadSearchSuggestions(query));
    });
  }

  Future<void> _loadSearchSuggestions(String query) async {
    try {
      final result = await _loadSearch(query, limit: 6);
      if (!mounted || _searchController.text.trim() != query) {
        return;
      }
      setState(() => _searchSuggestions = _suggestionsFromSearch(result));
    } catch (_) {
      if (mounted) {
        setState(() => _searchSuggestions = const []);
      }
    }
  }

  List<_SearchSuggestion> _suggestionsFromSearch(Map<String, dynamic> result) {
    final suggestions = <_SearchSuggestion>[];
    void addItems(List<dynamic> items, _ResultKind kind) {
      for (final item in items) {
        final map = (item as Map).cast<String, dynamic>();
        final id = _intValue(map['id']);
        if (id == null) {
          continue;
        }
        final title = (map['title'] ?? map['name'] ?? 'Untitled').toString();
        suggestions.add(
          _SearchSuggestion(
            kind: kind,
            id: id,
            title: title,
            subtitle: _searchSubtitle(map, kind),
            icon: switch (kind) {
              _ResultKind.track => Icons.music_note_outlined,
              _ResultKind.album => Icons.album_outlined,
              _ResultKind.artist => Icons.person_outline,
              _ResultKind.playlist => Icons.queue_music_outlined,
            },
          ),
        );
      }
    }

    addItems((result['tracks'] as List?) ?? const [], _ResultKind.track);
    addItems((result['albums'] as List?) ?? const [], _ResultKind.album);
    addItems((result['artists'] as List?) ?? const [], _ResultKind.artist);
    addItems((result['playlists'] as List?) ?? const [], _ResultKind.playlist);
    return suggestions.take(10).toList(growable: false);
  }

  Future<void> _submitSearch(String rawQuery) async {
    final query = rawQuery.trim();
    if (query.isEmpty) {
      return;
    }
    _rememberSearch(query);
    await _run<void>(() async {
      _searchResultCache[query] = await _loadSearch(query, limit: 120);
      _searchQuery = query;
      _searchScopeByQuery.putIfAbsent(query, () => _SearchScope.all);
      _searchSortByQuery.putIfAbsent(query, () => _SearchSort.relevance);
      _navigateToInState(_AppRoute.search(query));
      _searchSuggestions = const [];
    });
  }

  void _rememberSearch(String query) {
    final updated = <String>[
      query,
      ..._recentSearches.where(
        (item) => item.toLowerCase() != query.toLowerCase(),
      ),
    ].take(10).toList(growable: false);
    setState(() => _recentSearches = updated);
    unawaited(_persistRecentSearches(updated));
  }

  Future<void> _persistRecentSearches(List<String> searches) async {
    try {
      final preferences = _preferences ?? await SharedPreferences.getInstance();
      _preferences = preferences;
      await preferences.setStringList(_prefsRecentSearchesKey, searches);
    } catch (_) {
      // Search history remains available for the current session.
    }
  }

  void _selectRecentSearch(String query) {
    _searchController.text = query;
    _searchController.selection = TextSelection.collapsed(offset: query.length);
    unawaited(_submitSearch(query));
  }

  void _selectSearchSuggestion(_SearchSuggestion suggestion) {
    _searchController.text = suggestion.title;
    _searchController.selection = TextSelection.collapsed(
      offset: suggestion.title.length,
    );
    switch (suggestion.kind) {
      case _ResultKind.track:
        unawaited(_openTrackDetail(suggestion.id));
      case _ResultKind.album:
        unawaited(_openAlbumDetail(suggestion.id));
      case _ResultKind.artist:
        unawaited(_openArtistDetail(suggestion.id));
      case _ResultKind.playlist:
        unawaited(_openPlaylistDetail(suggestion.id));
    }
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _searchQuery = '';
      _searchSuggestions = const [];
      if (_currentRoute.kind == _AppRouteKind.search) {
        _navigateToInState(const _AppRoute.home());
      }
    });
  }

  void _handleCoreEvent(dynamic message) {
    if (message is! String) {
      return;
    }

    try {
      final envelope = _asMap(jsonDecode(message));
      final eventType = envelope['type']?.toString();
      final payload = envelope['payload'];

      if (eventType == 'renderer.command') {
        final commandEnvelope = _asMap(payload);
        if (commandEnvelope['renderer_id']?.toString() != _clientId) {
          return;
        }
        final command = _asMap(commandEnvelope['command']);
        final targetOutputId = command['target_output_id']?.toString();
        if (!_isClientOutputId(targetOutputId)) {
          return;
        }
        unawaited(_handleRendererCommand(command));
        return;
      }

      if ((eventType == 'playback.state_changed' ||
              eventType == 'playback.position') &&
          payload is Map) {
        final playback = payload.cast<String, dynamic>();
        setState(() {
          _mergePlaybackEvent(playback);
        });
        return;
      }

      if (eventType == 'playback.queue_changed' && payload is Map) {
        final queue = payload.cast<String, dynamic>();
        if (queue['zone_id']?.toString() == _activeZoneId()) {
          setState(() => _applyPlaybackQueue(queue));
        }
        return;
      }

      if (eventType == 'zone.volume_changed' && payload is Map) {
        final volume = payload.cast<String, dynamic>();
        final zoneId = volume['zone_id']?.toString();
        if (zoneId == null) {
          return;
        }
        setState(() {
          _zones = _zones
              .map((item) {
                final zone = (item as Map).cast<String, dynamic>();
                if (zone['id']?.toString() != zoneId) {
                  return zone;
                }
                return <String, dynamic>{
                  ...zone,
                  'volume': volume['volume'],
                  'muted': volume['muted'],
                };
              })
              .toList(growable: false);
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _rendererStatus = 'Renderer event error');
      }
    }
  }

  Future<void> _handleRendererCommand(Map<String, dynamic> command) async {
    final action = command['action']?.toString();
    final outputId = command['target_output_id']?.toString() ?? _clientOutputId;
    try {
      final player = await _playerForOutput(outputId);
      switch (action) {
        case 'play':
          final streamPath = command['stream_path']?.toString();
          if (streamPath == null || streamPath.isEmpty) {
            throw StateError('missing stream path');
          }
          final positionMs = _intValue(command['position_ms']) ?? 0;
          final trackId = _intValue(command['track_id']);
          await player.stop();
          await player.open(_api.apiUrl(streamPath));
          if (trackId != null) {
            _rendererLoadedTrackByOutput[outputId] = trackId;
          }
          if (positionMs > 0) {
            await player.seek(Duration(milliseconds: positionMs));
          }
          await _reportRendererState(
            'playing',
            outputId: outputId,
            command: command,
            positionMs: positionMs,
          );
          break;
        case 'resume':
          final positionMs = _intValue(command['position_ms']) ?? 0;
          final loaded = await _ensureRendererSource(
            player,
            outputId,
            command,
            positionMs,
          );
          if (!loaded) {
            await player.play();
          }
          await _reportRendererState(
            'playing',
            outputId: outputId,
            command: command,
            positionMs: loaded ? positionMs : null,
          );
          break;
        case 'pause':
          await player.pause();
          await _reportRendererState(
            'paused',
            outputId: outputId,
            command: command,
          );
          break;
        case 'stop':
          await player.stop();
          _rendererLoadedTrackByOutput.remove(outputId);
          await _reportRendererState('stopped', outputId: outputId);
          break;
        case 'seek':
          final positionMs = _intValue(command['position_ms']) ?? 0;
          final loaded = await _ensureRendererSource(
            player,
            outputId,
            command,
            positionMs,
          );
          if (!loaded) {
            await player.seek(Duration(milliseconds: positionMs));
          }
          await _reportRendererState(
            'playing',
            outputId: outputId,
            command: command,
            positionMs: positionMs,
          );
          break;
        case 'volume':
          final volume =
              (command['volume'] as num?)?.toDouble().clamp(0.0, 1.0) ?? 1.0;
          final muted = command['muted'] == true;
          await player.setVolume(muted ? 0.0 : volume);
          break;
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Renderer playback failed: $error');
      }
      await _reportRendererState('stopped', outputId: outputId);
    }
  }

  Future<bool> _ensureRendererSource(
    _RendererAudioPlayer player,
    String outputId,
    Map<String, dynamic> command,
    int positionMs,
  ) async {
    final trackId = _intValue(command['track_id']);
    if (trackId == null || _rendererLoadedTrackByOutput[outputId] == trackId) {
      return false;
    }
    final streamPath = command['stream_path']?.toString();
    if (streamPath == null || streamPath.isEmpty) {
      throw StateError(
        'renderer has no loaded source and command has no stream path',
      );
    }
    await player.stop();
    await player.open(_api.apiUrl(streamPath));
    _rendererLoadedTrackByOutput[outputId] = trackId;
    if (positionMs > 0) {
      await player.seek(Duration(milliseconds: positionMs));
    }
    return true;
  }

  Future<void> _reportRendererState(
    String state, {
    String? outputId,
    Map<String, dynamic>? command,
    int? positionMs,
  }) async {
    final targetOutputId = outputId ?? _clientOutputId;
    final previous = _rendererPlaybackByOutput[targetOutputId];
    final playerFuture = _audioPlayers[targetOutputId];
    final reportedPosition = playerFuture == null
        ? null
        : await (await playerFuture).currentPositionMs();
    final playerPosition = _stableRendererPositionMs(
      state: state,
      explicitPositionMs: positionMs,
      reportedPositionMs: reportedPosition,
      previous: previous,
    );
    final body = <String, dynamic>{
      'output_id': targetOutputId,
      'state': state,
      'track_id': state == 'stopped'
          ? null
          : command?['track_id'] ??
                previous?['track_id'] ??
                _playback?['track_id'],
      'track_title': state == 'stopped'
          ? null
          : command?['track_title'] ??
                previous?['track_title'] ??
                _playback?['track_title'],
      'position_ms': playerPosition,
    };
    final playback = _asMap(
      await _api.postJson(
        '/renderers/${Uri.encodeComponent(_clientId)}/state',
        body,
      ),
    );
    final playbackSnapshot = _withPlaybackTimestamp(playback);
    if (state == 'stopped') {
      _rendererPlaybackByOutput.remove(targetOutputId);
      _rendererLoadedTrackByOutput.remove(targetOutputId);
    } else {
      _rendererPlaybackByOutput[targetOutputId] = playbackSnapshot;
    }
    if (mounted) {
      setState(() {
        _mergePlaybackEvent(playbackSnapshot);
      });
    }
  }

  int _stableRendererPositionMs({
    required String state,
    required int? explicitPositionMs,
    required int? reportedPositionMs,
    required Map<String, dynamic>? previous,
  }) {
    if (explicitPositionMs != null) {
      return explicitPositionMs;
    }
    if (state == 'stopped') {
      return 0;
    }

    final previousEstimate = previous == null
        ? null
        : _estimatedPlaybackPositionMs(previous);
    final reported = reportedPositionMs;
    if (reported == null) {
      return previousEstimate ?? 0;
    }
    if ((state == 'playing' || state == 'paused') &&
        previousEstimate != null &&
        previousEstimate > 1500 &&
        reported + 1500 < previousEstimate) {
      return previousEstimate;
    }
    return reported;
  }

  Future<void> _reportRendererPositions() async {
    for (final entry in _rendererPlaybackByOutput.entries.toList()) {
      final state = entry.value['state']?.toString();
      final trackId = _intValue(entry.value['track_id']);
      if (trackId == null || (state != 'playing' && state != 'paused')) {
        continue;
      }
      await _reportRendererState(state!, outputId: entry.key);
    }
  }

  Future<T?> _showPanelDialog<T>({
    required Widget child,
    required double maxWidth,
  }) {
    final language = _language;
    return showDialog<T>(
      context: context,
      builder: (context) => _LocaleScope(
        language: language,
        child: Dialog(
          insetPadding: const EdgeInsets.all(22),
          backgroundColor: IntMusicTheme.of(context).surface,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: IntMusicTheme.of(context).stroke),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: maxWidth,
              maxHeight: MediaQuery.sizeOf(context).height - 44,
            ),
            child: child,
          ),
        ),
      ),
    );
  }

  Future<void> _openAlbumDetail(int albumId) async {
    final detail = await _run<Map<String, dynamic>>(
      () async => _asMap(await _api.getJson('/albums/$albumId')),
    );
    if (!mounted || detail == null) {
      return;
    }

    setState(() {
      _albumDetailCache[albumId] = detail;
      _navigateToInState(_AppRoute.album(albumId));
    });
  }

  void _closeAlbumDetail() => _closeDetailPage();

  Future<void> _openArtistDetail(int artistId) async {
    final detail = await _run<Map<String, dynamic>>(
      () async => _asMap(await _api.getJson('/artists/$artistId')),
    );
    if (!mounted || detail == null) {
      return;
    }

    setState(() {
      _artistDetailCache[artistId] = detail;
      _navigateToInState(_AppRoute.artist(artistId));
    });
  }

  void _closeArtistDetail() => _closeDetailPage();

  Future<void> _openTrackDetail(int trackId) async {
    final detail = await _run<Map<String, dynamic>>(
      () async => _asMap(await _api.getJson('/tracks/$trackId')),
    );
    if (!mounted || detail == null) {
      return;
    }

    setState(() {
      _trackDetailCache[trackId] = detail;
      _navigateToInState(_AppRoute.track(trackId));
    });
  }

  void _closeTrackDetail() => _closeDetailPage();

  Future<void> _openPlaylistDetail(int playlistId) async {
    final detail = await _run<Map<String, dynamic>>(
      () async => _asMap(await _api.getJson('/playlists/$playlistId')),
    );
    if (!mounted || detail == null) {
      return;
    }

    setState(() {
      _playlistDetailCache[playlistId] = detail;
      _navigateToInState(_AppRoute.playlist(playlistId));
    });
  }

  Future<void> _createManualPlaylist() async {
    final payload = await _showPanelDialog<Map<String, dynamic>>(
      maxWidth: 640,
      child: const _ManualPlaylistSheet(),
    );
    if (payload == null) {
      return;
    }
    final detail = await _run<Map<String, dynamic>>(
      () async => _asMap(await _api.postJson('/playlists', payload)),
    );
    if (mounted && detail != null) {
      await _reloadPlaylists();
    }
  }

  Future<void> _createSmartPlaylist() async {
    final payload = await _showPanelDialog<Map<String, dynamic>>(
      maxWidth: 760,
      child: const _SmartPlaylistSheet(),
    );
    if (payload == null) {
      return;
    }
    final detail = await _run<Map<String, dynamic>>(
      () async => _asMap(await _api.postJson('/playlists', payload)),
    );
    if (mounted && detail != null) {
      await _reloadPlaylists();
    }
  }

  Future<void> _editSmartPlaylist(
    int playlistId,
    Map<String, dynamic> detail,
  ) async {
    final payload = await _showPanelDialog<Map<String, dynamic>>(
      maxWidth: 760,
      child: _SmartPlaylistSheet(detail: detail),
    );
    if (payload == null) {
      return;
    }
    final updated = await _run<Map<String, dynamic>>(
      () async =>
          _asMap(await _api.postJson('/playlists/$playlistId', payload)),
    );
    if (!mounted || updated == null) {
      return;
    }
    await _reloadPlaylists();
    if (mounted) {
      setState(() => _playlistDetailCache[playlistId] = updated);
    }
  }

  Future<void> _deletePlaylist(int playlistId) async {
    final result = await _run<Map<String, dynamic>>(
      () async => _asMap(await _api.deleteJson('/playlists/$playlistId')),
    );
    if (mounted && result != null) {
      await _reloadPlaylists();
    }
  }

  Future<void> _reloadPlaylists() async {
    final playlists = await _api.getJson('/playlists') as List<dynamic>;
    if (mounted) {
      setState(() => _playlists = playlists);
    }
  }

  Future<void> _addTrackToPlaylist(int trackId) async {
    final manualPlaylists = _playlists
        .where((item) => _asMap(item)['kind']?.toString() == 'manual')
        .toList(growable: false);
    if (manualPlaylists.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Create a manual playlist first')),
        );
      }
      return;
    }
    final playlistId = await _showPanelDialog<int>(
      maxWidth: 560,
      child: _AddToPlaylistSheet(playlists: manualPlaylists),
    );
    if (playlistId == null) {
      return;
    }
    final detail = await _run<Map<String, dynamic>>(
      () async => _asMap(
        await _api.postJson('/playlists/$playlistId/tracks', <String, dynamic>{
          'track_id': trackId,
        }),
      ),
    );
    if (mounted && detail != null) {
      await _reloadPlaylists();
    }
  }

  Future<void> _removeTrackFromPlaylist({
    required int playlistId,
    required int trackId,
  }) async {
    final detail = await _run<Map<String, dynamic>>(
      () async => _asMap(
        await _api.deleteJson('/playlists/$playlistId/tracks/$trackId'),
      ),
    );
    if (mounted && detail != null) {
      await _reloadPlaylists();
      if (!mounted) {
        return;
      }
      setState(() => _playlistDetailCache[playlistId] = detail);
    }
  }

  Future<void> _toggleFavorite(Map<String, dynamic> track) async {
    final trackId = _intValue(track['id']);
    if (trackId == null) {
      return;
    }
    final detail = await _run<Map<String, dynamic>>(
      () async => _asMap(
        await _api.postJson('/tracks/$trackId/favorite', <String, dynamic>{
          'is_favorite': track['is_favorite'] != true,
        }),
      ),
    );
    if (!mounted || detail == null) {
      return;
    }
    final updatedTrack = _asMap(detail['track']);
    setState(() {
      _replaceTrackInCollections(updatedTrack);
      if (_activeTrackDetailId == trackId) {
        _activeTrackDetail = detail;
      }
      _trackDetailCache[trackId] = detail;
      _replaceTrackInDetailCache(_albumDetailCache, updatedTrack);
      _replaceTrackInDetailCache(_artistDetailCache, updatedTrack);
      _replaceTrackInDetailCache(_playlistDetailCache, updatedTrack);
    });
  }

  void _replaceTrackInDetailCache(
    Map<int, Map<String, dynamic>> cache,
    Map<String, dynamic> updatedTrack,
  ) {
    final trackId = _intValue(updatedTrack['id']);
    if (trackId == null) {
      return;
    }
    for (final entry in cache.entries.toList(growable: false)) {
      final tracks = (entry.value['tracks'] as List?) ?? const [];
      cache[entry.key] = <String, dynamic>{
        ...entry.value,
        'tracks': tracks
            .map((item) {
              final track = (item as Map).cast<String, dynamic>();
              return _intValue(track['id']) == trackId ? updatedTrack : track;
            })
            .toList(growable: false),
      };
    }
  }

  Future<void> _updateFavoriteSettings(Map<String, dynamic> payload) async {
    final settings = await _run<Map<String, dynamic>>(
      () async => _asMap(await _api.postJson('/settings/favorites', payload)),
    );
    if (mounted && settings != null) {
      setState(() => _favoriteSettings = settings);
      await _refreshAll();
    }
  }

  Future<void> _updateMetadataSettings(Map<String, dynamic> payload) async {
    final settings = await _run<Map<String, dynamic>>(
      () async => _asMap(await _api.postJson('/settings/metadata', payload)),
    );
    if (mounted && settings != null) {
      setState(() => _metadataSettings = settings);
    }
  }

  void _replaceTrackInCollections(Map<String, dynamic> updatedTrack) {
    final trackId = _intValue(updatedTrack['id']);
    if (trackId == null) {
      return;
    }
    List<dynamic> replaceInList(List<dynamic> items) => items
        .map((item) {
          final map = (item as Map).cast<String, dynamic>();
          return _intValue(map['id']) == trackId ? updatedTrack : map;
        })
        .toList(growable: false);

    _tracks = replaceInList(_tracks);
    for (final entry in _searchResultCache.entries.toList(growable: false)) {
      final tracks = (entry.value['tracks'] as List?) ?? const [];
      _searchResultCache[entry.key] = <String, dynamic>{
        ...entry.value,
        'tracks': replaceInList(tracks),
      };
    }
  }

  Future<void> _playTrack(int trackId) async {
    final queueItems = (_playbackQueue?['items'] as List?) ?? const [];
    final queued = queueItems.any((item) {
      final queueItem = (item as Map).cast<String, dynamic>();
      final track = (queueItem['track'] as Map?)?.cast<String, dynamic>();
      return _intValue(track?['id']) == trackId;
    });
    if (!queued) {
      final trackIds = _tracks
          .map((track) => _intValue((track as Map)['id']))
          .whereType<int>()
          .toList(growable: false);
      final startIndex = trackIds.indexOf(trackId);
      if (startIndex >= 0) {
        final queue = await _run<Map<String, dynamic>>(
          () async => _asMap(
            await _api.postJson(
              '/zones/${Uri.encodeComponent(_selectedZoneId)}/queue',
              <String, dynamic>{
                'track_ids': trackIds,
                'start_index': startIndex,
                'mode': _playbackMode.nameForApi,
              },
            ),
          ),
        );
        if (queue != null) {
          _applyPlaybackQueue(queue);
        }
      }
    }
    final playback = await _playTrackOnZone(trackId, _selectedZoneId);
    if (mounted && playback != null) {
      setState(() {
        _applyPlayback(playback);
      });
    }
  }

  Future<Map<String, dynamic>?> _playTrackOnZone(int trackId, String zoneId) {
    return _run<Map<String, dynamic>>(
      () async => _asMap(
        await _api.postJson(
          '/zones/${Uri.encodeComponent(zoneId)}/play',
          <String, dynamic>{'track_id': trackId},
        ),
      ),
    );
  }

  Future<void> _playPreviousTrack() async {
    final playback = await _run<Map<String, dynamic>>(
      () async => _asMap(
        await _api.postJson(
          '/zones/${Uri.encodeComponent(_activeZoneId())}/previous',
          const <String, dynamic>{},
        ),
      ),
    );
    if (mounted && playback != null) {
      setState(() => _applyPlayback(playback));
    }
  }

  Future<void> _playNextTrack() async {
    final playback = await _run<Map<String, dynamic>>(
      () async => _asMap(
        await _api.postJson(
          '/zones/${Uri.encodeComponent(_activeZoneId())}/next',
          const <String, dynamic>{},
        ),
      ),
    );
    if (mounted && playback != null) {
      setState(() => _applyPlayback(playback));
    }
  }

  Future<void> _refreshPlaybackQueue({String? zoneId}) async {
    final targetZoneId = zoneId ?? _activeZoneId();
    try {
      final queue = _asMap(
        await _api.getJson('/zones/${Uri.encodeComponent(targetZoneId)}/queue'),
      );
      if (!mounted || targetZoneId != _activeZoneId()) {
        return;
      }
      setState(() => _applyPlaybackQueue(queue));
    } catch (_) {
      // Zone refresh and the event stream will retry the queue snapshot.
    }
  }

  void _applyPlaybackQueue(Map<String, dynamic> queue) {
    _playbackQueue = queue;
    _playbackMode = _PlaybackMode.fromApi(queue['mode']?.toString());
  }

  List<Map<String, dynamic>> _queueItems() =>
      ((_playbackQueue?['items'] as List?) ?? const [])
          .map((item) => (item as Map).cast<String, dynamic>())
          .toList(growable: false);

  Future<void> _addTrackToQueue(int trackId, {bool playNext = false}) {
    return _addTracksToQueue(<int>[trackId], playNext: playNext);
  }

  Future<void> _addTracksToQueue(
    List<int> trackIds, {
    bool playNext = false,
  }) async {
    if (trackIds.isEmpty) {
      return;
    }
    final currentIndex = _intValue(_playbackQueue?['current_index']);
    final position = playNext ? (currentIndex ?? -1) + 1 : null;
    final queue = await _run<Map<String, dynamic>>(
      () async => _asMap(
        await _api.postJson(
          '/zones/${Uri.encodeComponent(_activeZoneId())}/queue/items',
          <String, dynamic>{'track_ids': trackIds, 'position': ?position},
        ),
      ),
    );
    if (!mounted || queue == null) {
      return;
    }
    setState(() => _applyPlaybackQueue(queue));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 2),
        content: Text(
          playNext
              ? '${trackIds.length} track(s) will play next'
              : '${trackIds.length} track(s) added to queue',
        ),
      ),
    );
  }

  Future<Map<String, dynamic>?> _replaceQueue(
    List<int> trackIds, {
    int? startIndex,
    _PlaybackMode? mode,
  }) async {
    final queue = await _run<Map<String, dynamic>>(
      () async => _asMap(
        await _api.postJson(
          '/zones/${Uri.encodeComponent(_activeZoneId())}/queue',
          <String, dynamic>{
            'track_ids': trackIds,
            'start_index': startIndex,
            'mode': (mode ?? _playbackMode).nameForApi,
          },
        ),
      ),
    );
    if (mounted && queue != null) {
      setState(() => _applyPlaybackQueue(queue));
    }
    return queue;
  }

  Future<void> _playCollection(List<int> trackIds, bool shuffle) async {
    if (trackIds.isEmpty) {
      return;
    }
    final queue = await _replaceQueue(
      trackIds,
      startIndex: 0,
      mode: shuffle ? _PlaybackMode.shuffle : _PlaybackMode.sequential,
    );
    if (queue == null) {
      return;
    }
    final playback = await _playTrackOnZone(trackIds.first, _activeZoneId());
    if (mounted && playback != null) {
      setState(() => _applyPlayback(playback));
    }
  }

  Future<Map<String, dynamic>?> _clearUpcomingQueue() {
    final items = _queueItems();
    final currentIndex = _intValue(_playbackQueue?['current_index']);
    if (currentIndex == null || currentIndex < 0) {
      return _replaceQueue(const []);
    }
    final retainedIds = items
        .take(min(currentIndex + 1, items.length))
        .map((item) => _intValue(_asMap(item['track'])['id']))
        .whereType<int>()
        .toList(growable: false);
    return _replaceQueue(
      retainedIds,
      startIndex: retainedIds.isEmpty ? null : retainedIds.length - 1,
    );
  }

  Future<Map<String, dynamic>?> _clearEntireQueue() async {
    final queue = await _replaceQueue(const []);
    if (queue != null) {
      await _stopZone(_activeZoneId());
    }
    return queue;
  }

  Future<Map<String, dynamic>?> _moveQueueItem(int from, int to) async {
    final queue = await _run<Map<String, dynamic>>(
      () async => _asMap(
        await _api.postJson(
          '/zones/${Uri.encodeComponent(_activeZoneId())}/queue/move',
          <String, dynamic>{'from': from, 'to': to},
        ),
      ),
    );
    if (mounted && queue != null) {
      setState(() => _applyPlaybackQueue(queue));
    }
    return queue;
  }

  Future<Map<String, dynamic>?> _removeQueueItem(int itemId) async {
    final queue = await _run<Map<String, dynamic>>(
      () async => _asMap(
        await _api.deleteJson(
          '/zones/${Uri.encodeComponent(_activeZoneId())}/queue/items/$itemId',
        ),
      ),
    );
    if (mounted && queue != null) {
      setState(() => _applyPlaybackQueue(queue));
    }
    return queue;
  }

  void _cyclePlaybackMode() {
    final nextIndex =
        (_PlaybackMode.values.indexOf(_playbackMode) + 1) %
        _PlaybackMode.values.length;
    unawaited(_setPlaybackMode(_PlaybackMode.values[nextIndex]));
  }

  Future<void> _setPlaybackMode(_PlaybackMode mode) async {
    final queue = await _run<Map<String, dynamic>>(
      () async => _asMap(
        await _api.postJson(
          '/zones/${Uri.encodeComponent(_activeZoneId())}/queue/mode',
          <String, dynamic>{'mode': mode.nameForApi},
        ),
      ),
    );
    if (mounted && queue != null) {
      setState(() => _applyPlaybackQueue(queue));
    }
  }

  void _showPlaybackModeMenu(BuildContext anchorContext) {
    unawaited(
      _showAnchoredPopup<void>(
        context: anchorContext,
        anchorContext: anchorContext,
        width: 320,
        maxHeight: 340,
        child: _ModeSheet(
          playbackMode: _playbackMode,
          onSelected: (mode) {
            Navigator.of(anchorContext).pop();
            unawaited(_setPlaybackMode(mode));
          },
        ),
      ),
    );
  }

  void _showNavigationSheet(BuildContext anchorContext) {
    unawaited(
      _showAnchoredPopup<void>(
        context: anchorContext,
        anchorContext: anchorContext,
        width: 320,
        maxHeight: 560,
        child: _NavigationSheet(
          selectedIndex: _selectedDestinationIndex,
          onSelected: (index) {
            Navigator.of(anchorContext).pop();
            _setSelectedIndex(index);
          },
        ),
      ),
    );
  }

  void _showQueueSheet(BuildContext anchorContext) {
    unawaited(
      _showAnchoredPopup<void>(
        context: anchorContext,
        anchorContext: anchorContext,
        width: 460,
        maxHeight: 560,
        child: _QueueSheet(
          coreBaseUrl: _coreUrlController.text,
          items: _queueItems(),
          currentIndex: _intValue(_playbackQueue?['current_index']),
          onPlayTrack: (trackId) async {
            final playback = await _playTrackOnZone(trackId, _activeZoneId());
            if (mounted && playback != null) {
              setState(() => _applyPlayback(playback));
            }
          },
          onMove: _moveQueueItem,
          onRemove: _removeQueueItem,
          onClearUpcoming: _clearUpcomingQueue,
          onClearAll: _clearEntireQueue,
        ),
      ),
    );
  }

  void _showDeviceSheet(BuildContext anchorContext) {
    unawaited(
      _showAnchoredPopup<void>(
        context: anchorContext,
        anchorContext: anchorContext,
        width: 620,
        maxHeight: 620,
        child: _DeviceSheet(
          snapshot: _currentDeviceSheetSnapshot(),
          onRefresh: _refreshDeviceSheetSnapshot,
          onSelect: _selectZone,
          onResume: _resumeZone,
          onPause: _pauseZone,
          onStop: _stopZone,
          onMoveHere: (targetZoneId) =>
              _movePlayback(_activeZoneId(), targetZoneId),
          onPlayEverywhere: _playCurrentEverywhere,
          onStopEverywhere: _stopEverywhere,
          onRename: _renameZone,
        ),
      ),
    );
  }

  _DeviceSheetSnapshot _currentDeviceSheetSnapshot() => _DeviceSheetSnapshot(
    zones: _zones,
    selectedZoneId: _selectedZoneId,
    activeZoneId: _activeZoneId(),
    hasActiveTrack: _playback?['track_id'] != null,
  );

  Future<_DeviceSheetSnapshot> _refreshDeviceSheetSnapshot() async {
    try {
      final zones = await _api.getJson('/zones') as List<dynamic>;
      if (mounted) {
        setState(() {
          _zones = zones;
          _keepSelectedZoneValid();
          _syncPlaybackFromSelectedZone();
        });
      }
    } catch (_) {
      // Visible connection errors are owned by the main refresh path.
    }
    return _currentDeviceSheetSnapshot();
  }

  Future<void> _pausePlayback() async {
    await _pauseZone(_activeZoneId());
  }

  Future<void> _resumePlayback() async {
    await _resumeZone(_activeZoneId());
  }

  Future<void> _pauseZone(String zoneId) async {
    await _postZoneAction(zoneId, 'pause');
  }

  Future<void> _resumeZone(String zoneId) async {
    await _postZoneAction(zoneId, 'play');
  }

  Future<void> _stopZone(String zoneId) async {
    await _postZoneAction(zoneId, 'stop');
  }

  Future<void> _postZoneAction(String zoneId, String action) async {
    final playback = await _run<Map<String, dynamic>>(
      () async => _asMap(
        await _api.postJson(
          '/zones/${Uri.encodeComponent(zoneId)}/$action',
          <String, dynamic>{},
        ),
      ),
    );
    if (mounted && playback != null) {
      setState(() {
        _applyPlayback(playback);
      });
    }
  }

  Future<void> _movePlayback(String sourceZoneId, String targetZoneId) async {
    if (sourceZoneId == targetZoneId) {
      return;
    }
    final states = await _run<List<dynamic>>(
      () async =>
          await _api.postJson(
                '/zones/${Uri.encodeComponent(sourceZoneId)}/transfer',
                <String, dynamic>{'target_zone_id': targetZoneId},
              )
              as List<dynamic>,
    );
    if (!mounted || states == null) {
      return;
    }
    final stateMaps = states
        .map((state) => (state as Map).cast<String, dynamic>())
        .toList(growable: false);
    final targetState = stateMaps.firstWhere(
      (state) => state['zone_id']?.toString() == targetZoneId,
      orElse: () => stateMaps.first,
    );
    setState(() {
      for (final state in stateMaps) {
        _upsertZoneFromPlayback(state);
      }
      _selectedZoneId = targetZoneId;
      _selectedZoneLabel = _zoneLabelById(targetZoneId);
      _applyPlayback(targetState, syncZone: false);
    });
  }

  Future<void> _playCurrentEverywhere() async {
    final trackId = _intValue(_playback?['track_id']);
    if (trackId == null) {
      return;
    }
    final zoneIds = _onlineZoneIds();
    if (zoneIds.isEmpty) {
      return;
    }
    final states = await _run<List<dynamic>>(
      () async =>
          await _api.postJson('/zones/play-many', <String, dynamic>{
                'track_id': trackId,
                'zone_ids': zoneIds,
                'position_ms': _estimatedPlaybackPositionMs(_playback),
              })
              as List<dynamic>,
    );
    if (!mounted || states == null || states.isEmpty) {
      return;
    }
    final stateMaps = states
        .map((state) => (state as Map).cast<String, dynamic>())
        .toList(growable: false);
    final preferred = stateMaps.firstWhere(
      (state) => state['zone_id']?.toString() == _selectedZoneId,
      orElse: () => stateMaps.first,
    );
    setState(() {
      for (final state in stateMaps) {
        _upsertZoneFromPlayback(state);
      }
      _applyPlayback(preferred, syncZone: false);
    });
  }

  Future<void> _seekPlayback(int positionMs) async {
    final playback = await _run<Map<String, dynamic>>(
      () async => _asMap(
        await _api.postJson(
          '/zones/${Uri.encodeComponent(_activeZoneId())}/seek',
          <String, dynamic>{'position_ms': positionMs},
        ),
      ),
    );
    if (mounted && playback != null) {
      setState(() {
        _applyPlayback(playback);
      });
    }
  }

  double _activeZoneVolume() {
    final zone = _zoneById(_activeZoneId());
    return ((zone?['volume'] as num?)?.toDouble() ?? 1.0).clamp(0.0, 1.0);
  }

  bool _activeZoneMuted() => _zoneById(_activeZoneId())?['muted'] == true;

  Future<void> _setActiveZoneVolume(double volume, {bool? muted}) async {
    final zoneId = _activeZoneId();
    final normalized = volume.clamp(0.0, 1.0);
    final effectiveMuted = muted ?? (normalized <= 0.001);
    final result = await _run<Map<String, dynamic>>(
      () async => _asMap(
        await _api.postJson(
          '/zones/${Uri.encodeComponent(zoneId)}/volume',
          <String, dynamic>{'volume': normalized, 'muted': effectiveMuted},
        ),
      ),
    );
    if (!mounted || result == null) {
      return;
    }
    setState(() {
      _zones = _zones
          .map((item) {
            final zone = (item as Map).cast<String, dynamic>();
            if (zone['id']?.toString() != zoneId) {
              return zone;
            }
            return <String, dynamic>{
              ...zone,
              'volume': result['volume'],
              'muted': result['muted'],
            };
          })
          .toList(growable: false);
    });
    unawaited(
      _IntMusicPlatform.instance.updateVolume(
        normalized,
        muted: effectiveMuted,
      ),
    );
  }

  String _activeZoneId() =>
      _playback?['zone_id']?.toString() ?? _selectedZoneId;

  Future<void> _selectZone(Map<String, dynamic> zone) async {
    final zoneId = zone['id']?.toString() ?? 'local';
    setState(() {
      _selectedZoneId = zoneId;
      _selectedZoneLabel = _zoneDisplayName(zone);
      _syncPlaybackFromZone(zone);
    });
    await _refreshPlaybackQueue(zoneId: zoneId);
  }

  Future<void> _renameZone(String zoneId, String? alias) async {
    await _run<void>(() async {
      await _api.postJson(
        '/zones/${Uri.encodeComponent(zoneId)}/alias',
        <String, dynamic>{'alias': alias},
      );
      final zones = await _api.getJson('/zones') as List<dynamic>;
      if (!mounted) {
        return;
      }
      setState(() {
        _zones = zones;
        _keepSelectedZoneValid();
        _syncPlaybackFromSelectedZone();
      });
    });
  }

  Future<void> _stopEverywhere() async {
    final zoneIds = _onlineZoneIds();
    if (zoneIds.isEmpty) {
      return;
    }
    await _run<void>(() async {
      for (final zoneId in zoneIds) {
        await _api.postJson(
          '/zones/${Uri.encodeComponent(zoneId)}/stop',
          <String, dynamic>{},
        );
      }
      final zones = await _api.getJson('/zones') as List<dynamic>;
      if (!mounted) {
        return;
      }
      setState(() {
        _zones = zones;
        _syncPlaybackFromSelectedZone();
      });
    });
  }

  void _keepSelectedZoneValid() {
    final stillAvailable = _zones.isNotEmpty
        ? _zones.any((item) {
            final zone = (item as Map).cast<String, dynamic>();
            return zone['id']?.toString() == _selectedZoneId &&
                zone['is_online'] != false;
          })
        : _outputs.any((item) {
            final output = (item as Map).cast<String, dynamic>();
            return _zoneIdForOutput(output) == _selectedZoneId &&
                output['is_online'] == true;
          });
    if (!stillAvailable) {
      Map<String, dynamic>? clientZone;
      for (final item in _zones) {
        final zone = (item as Map).cast<String, dynamic>();
        if (zone['id']?.toString() == _clientOutputId) {
          clientZone = zone;
          break;
        }
      }
      if (clientZone != null) {
        _selectedZoneId = _clientOutputId;
        _selectedZoneLabel = _zoneDisplayName(clientZone);
      } else {
        _selectedZoneId = 'local';
        _selectedZoneLabel = 'Core local';
      }
    }
  }

  List<String> _onlineZoneIds() {
    final ids = <String>{};
    if (_zones.isNotEmpty) {
      for (final item in _zones) {
        final zone = (item as Map).cast<String, dynamic>();
        if (zone['is_online'] == false) {
          continue;
        }
        final zoneId = zone['id']?.toString();
        if (zoneId != null && zoneId.isNotEmpty) {
          ids.add(zoneId);
        }
      }
      return ids.toList(growable: false);
    }

    for (final item in _outputs) {
      final output = (item as Map).cast<String, dynamic>();
      if (output['is_online'] == false) {
        continue;
      }
      ids.add(_zoneIdForOutput(output));
    }
    return ids.toList(growable: false);
  }

  Map<String, dynamic>? _zoneById(String zoneId) {
    for (final item in _zones) {
      final zone = (item as Map).cast<String, dynamic>();
      if (zone['id']?.toString() == zoneId) {
        return zone;
      }
    }
    return null;
  }

  String _zoneLabelById(String zoneId) {
    final zone = _zoneById(zoneId);
    return zone == null ? zoneId : _zoneDisplayName(zone);
  }

  void _syncPlaybackFromSelectedZone() {
    final zone = _zoneById(_selectedZoneId);
    if (zone != null) {
      _selectedZoneLabel = _zoneDisplayName(zone);
      _syncPlaybackFromZone(zone);
    }
  }

  void _syncPlaybackFromZone(Map<String, dynamic> zone) {
    final playback = _playbackFromZone(zone);
    _applyPlayback(playback, syncZone: false);
  }

  Map<String, dynamic> _playbackFromZone(Map<String, dynamic> zone) {
    final zoneId = zone['id'];
    final trackId = _intValue(zone['track_id']);
    final state = zone['state']?.toString();
    var positionMs = _intValue(zone['position_ms']) ?? 0;
    final currentZoneId = _playback?['zone_id']?.toString();
    final currentTrackId = _intValue(_playback?['track_id']);
    if (zoneId?.toString() == currentZoneId &&
        trackId != null &&
        trackId == currentTrackId &&
        (state == 'playing' || state == 'paused')) {
      final currentPosition = _estimatedPlaybackPositionMs(_playback);
      if (positionMs + 1500 < currentPosition) {
        positionMs = currentPosition;
      }
    }

    return <String, dynamic>{
      'zone_id': zoneId,
      'state': state,
      'track_id': trackId,
      'track_title': zone['track_title'],
      'position_ms': positionMs,
      'queue_revision': 0,
    };
  }

  void _upsertZoneFromPlayback(Map<String, dynamic> playback) {
    final zoneId = playback['zone_id']?.toString();
    if (zoneId == null || zoneId.isEmpty) {
      return;
    }

    _zones = _zones
        .map((item) {
          final zone = (item as Map).cast<String, dynamic>();
          if (zone['id']?.toString() != zoneId) {
            return zone;
          }
          return <String, dynamic>{
            ...zone,
            'state': playback['state'],
            'track_id': playback['track_id'],
            'track_title': playback['track_title'],
            'position_ms': playback['position_ms'] ?? 0,
          };
        })
        .toList(growable: false);
  }

  void _mergePlaybackEvent(Map<String, dynamic> playback) {
    final stablePlayback = _stabilizeIncomingPlayback(playback);
    final zoneId = playback['zone_id']?.toString();
    final activeZoneId = _activeZoneId();
    if (zoneId == _selectedZoneId || zoneId == activeZoneId) {
      _applyPlayback(stablePlayback);
    } else {
      _upsertZoneFromPlayback(stablePlayback);
    }
  }

  Map<String, dynamic> _stabilizeIncomingPlayback(
    Map<String, dynamic> playback,
  ) {
    final zoneId = playback['zone_id']?.toString();
    final trackId = _intValue(playback['track_id']);
    final state = playback['state']?.toString();
    final currentZoneId = _playback?['zone_id']?.toString();
    final currentTrackId = _intValue(_playback?['track_id']);
    if (zoneId == null ||
        zoneId != currentZoneId ||
        trackId == null ||
        trackId != currentTrackId ||
        (state != 'playing' && state != 'paused')) {
      return playback;
    }

    final incomingPosition = _intValue(playback['position_ms']) ?? 0;
    final currentPosition = _estimatedPlaybackPositionMs(_playback);
    if (incomingPosition + 1500 >= currentPosition) {
      return playback;
    }
    return <String, dynamic>{...playback, 'position_ms': currentPosition};
  }

  Map<String, dynamic> _withPlaybackTimestamp(Map<String, dynamic> playback) {
    return <String, dynamic>{
      ...playback,
      '_received_at_ms': DateTime.now().millisecondsSinceEpoch,
    };
  }

  void _applyPlayback(Map<String, dynamic> playback, {bool syncZone = true}) {
    if (syncZone) {
      _upsertZoneFromPlayback(playback);
    }
    _playback = _withPlaybackTimestamp(playback);
    _scheduleActiveTrackDetailLoad(playback);
    _syncSystemPlayback();
  }

  void _syncSystemPlayback() {
    _IntMusicPlatform.instance._activeCoreBaseUrlForPlatform =
        _coreUrlController.text;
    unawaited(
      _IntMusicPlatform.instance.updatePlayback(
        playback: _playback,
        detail: _activeTrackDetail,
      ),
    );
  }

  void _scheduleActiveTrackDetailLoad(Map<String, dynamic>? playback) {
    final trackId = _intValue(playback?['track_id']);
    if (trackId == null) {
      _activeTrackDetailId = null;
      _activeTrackDetail = null;
      return;
    }
    if (_activeTrackDetailId == trackId && _activeTrackDetail != null) {
      return;
    }
    if (_activeTrackDetailId != trackId) {
      _activeTrackDetail = null;
    }
    _activeTrackDetailId = trackId;
    unawaited(_loadActiveTrackDetail(trackId));
  }

  Future<void> _loadActiveTrackDetail(int trackId) async {
    try {
      final detail = _asMap(await _api.getJson('/tracks/$trackId'));
      if (!mounted || _activeTrackDetailId != trackId) {
        return;
      }
      setState(() => _activeTrackDetail = detail);
      _syncSystemPlayback();
    } catch (_) {
      // Track detail loading is secondary to playback control.
    }
  }

  Future<T?> _run<T>(Future<T> Function() task) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      return await task();
    } catch (error) {
      _error = error.toString();
      return null;
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return _LocaleScope(
      language: _language,
      child: _TrackActionScope(
        onPlayNext: (trackId) => _addTrackToQueue(trackId, playNext: true),
        onAddToQueue: (trackId) => _addTrackToQueue(trackId),
        onPlayCollection: _playCollection,
        onQueueCollection: (trackIds, playNext) =>
            _addTracksToQueue(trackIds, playNext: playNext),
        child: CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.bracketLeft, meta: true):
                _navigateBack,
            const SingleActivator(LogicalKeyboardKey.bracketRight, meta: true):
                _navigateForward,
            const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true):
                _navigateBack,
            const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true):
                _navigateForward,
            const SingleActivator(LogicalKeyboardKey.browserBack):
                _navigateBack,
            const SingleActivator(LogicalKeyboardKey.browserForward):
                _navigateForward,
          },
          child: Focus(
            autofocus: true,
            child: PopScope(
              canPop: false,
              onPopInvokedWithResult: (didPop, result) {
                if (!didPop) {
                  unawaited(_handleBackNavigation());
                }
              },
              child: IntMusicBackdrop(
                child: Scaffold(
                  body: _WindowsA11yQuiet(
                    child: SafeArea(
                      child: LayoutBuilder(
                        builder: (context, constraints) =>
                            _buildShell(constraints),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _handleBackNavigation() async {
    if (_canNavigateBack) {
      _navigateBack();
      return;
    }
    await _moveAppToBackground();
  }

  Future<void> _moveAppToBackground() async {
    if (!Platform.isAndroid) {
      return;
    }
    await _IntMusicPlatform.instance.moveToBackground();
  }

  void _startPlaybackReveal() {
    if (!Platform.isAndroid || _currentRoute.kind == _AppRouteKind.playback) {
      return;
    }
    _playbackRevealController.stop();
  }

  void _updatePlaybackReveal(double delta) {
    if (!Platform.isAndroid || _currentRoute.kind == _AppRouteKind.playback) {
      return;
    }
    _playbackRevealController.value = (_playbackRevealController.value + delta)
        .clamp(0.0, 1.0);
  }

  void _endPlaybackReveal(double upwardVelocity) {
    if (!Platform.isAndroid || _currentRoute.kind == _AppRouteKind.playback) {
      return;
    }
    final shouldOpen =
        _playbackRevealController.value >= 0.36 || upwardVelocity >= 680;
    if (shouldOpen) {
      unawaited(
        _playbackRevealController.animateTo(1).then((_) {
          if (!mounted) {
            return;
          }
          setState(() => _navigateToInState(_AppRoute.destination(5)));
          _playbackRevealController.value = 0;
        }),
      );
      return;
    }
    unawaited(_playbackRevealController.animateBack(0));
  }

  Widget _buildShell(BoxConstraints constraints) {
    final viewport = _effectiveViewportSize(constraints);
    final effectiveWidth = viewport.width;
    final desktop = effectiveWidth >= _desktopShellWidth;
    final showPlaybackBar = _currentRoute.kind != _AppRouteKind.playback;
    final pageTitle = _currentRoute.title;
    final page = _AnimatedPageHost(
      pageKey: _currentRoute.animationKey,
      direction: _pageTransitionDirection,
      child: _page(),
    );
    final playbackBar = _PlaybackBar(
      coreBaseUrl: _coreUrlController.text,
      state: _playback,
      trackDetail: _activeTrackDetail,
      targetLabel: _selectedZoneLabel,
      playbackMode: _playbackMode,
      volume: _activeZoneVolume(),
      muted: _activeZoneMuted(),
      onResume: _resumePlayback,
      onPause: _pausePlayback,
      onPrevious: _playPreviousTrack,
      onNext: _playNextTrack,
      onSeek: _seekPlayback,
      onVolumeChanged: (value) => unawaited(_setActiveZoneVolume(value)),
      onToggleMute: () => unawaited(
        _setActiveZoneVolume(_activeZoneVolume(), muted: !_activeZoneMuted()),
      ),
      onCycleMode: _cyclePlaybackMode,
      onShowModeMenu: _showPlaybackModeMenu,
      onShowQueue: _showQueueSheet,
      onShowDevices: _showDeviceSheet,
      onOpenPlayback: () => _navigateTo(_AppRoute.destination(5)),
      enableRevealGesture: Platform.isAndroid,
      onRevealStart: _startPlaybackReveal,
      onRevealUpdate: _updatePlaybackReveal,
      onRevealEnd: _endPlaybackReveal,
    );
    final body = Expanded(
      child: LayoutBuilder(
        builder: (context, bodyConstraints) {
          return Stack(
            children: [
              Column(
                children: [
                  Expanded(child: page),
                  if (showPlaybackBar) playbackBar,
                ],
              ),
              if (showPlaybackBar)
                Positioned.fill(
                  child: AnimatedBuilder(
                    animation: _playbackRevealController,
                    builder: (context, _) {
                      final progress = _playbackRevealController.value;
                      if (progress <= 0.001) {
                        return const SizedBox.shrink();
                      }
                      final curved = Curves.easeOutCubic.transform(progress);
                      final radius = 24.0 * (1 - curved);
                      return IgnorePointer(
                        ignoring: progress < 0.98,
                        child: Transform.translate(
                          offset: Offset(
                            0,
                            bodyConstraints.maxHeight * (1 - curved),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.vertical(
                              top: Radius.circular(radius),
                            ),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: IntMusicTheme.of(context).canvas,
                              ),
                              child: _buildPlaybackPage(),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
    final content = Column(
      children: [
        _AppTopBar(
          title: pageTitle,
          desktop: desktop,
          canGoBack: _canNavigateBack,
          canGoForward: _canNavigateForward,
          onBack: _navigateBack,
          onForward: _navigateForward,
          searchController: _searchController,
          searchSuggestions: _searchSuggestions,
          onOpenMenu: _showNavigationSheet,
          onSearchChanged: _onSearchChanged,
          onSubmitSearch: (query) => unawaited(_submitSearch(query)),
          onSelectSuggestion: _selectSearchSuggestion,
          recentSearches: _recentSearches,
          onSelectRecentSearch: _selectRecentSearch,
          onClearSearch: _clearSearch,
        ),
        if (_error != null) _ErrorBanner(message: _error!),
        body,
      ],
    );
    final contentSurface = KeyedSubtree(
      key: const Key('app-content-surface'),
      child: Platform.isMacOS
          ? ColoredBox(
              color: IntMusicTheme.of(context).canvas.withValues(alpha: 0.96),
              child: content,
            )
          : content,
    );

    if (_enforceViewportLimits) {
      final sidebar = ValueListenableBuilder<double>(
        valueListenable: _IntMusicPlatform.instance.titlebarSafeInset,
        builder: (context, titlebarSafeInset, child) => _AppSidebar(
          selectedIndex: _selectedDestinationIndex,
          status: _status,
          zones: _zones,
          loading: _loading,
          error: _error,
          playback: _playback,
          titlebarSafeInset: Platform.isMacOS ? titlebarSafeInset : 0,
          onSelected: _setSelectedIndex,
        ),
      );
      return _withMinimumViewport(
        constraints,
        _AnimatedSidebarShell(
          expanded: desktop,
          sidebar: sidebar,
          content: contentSurface,
        ),
      );
    }

    return _withMinimumViewport(constraints, contentSurface);
  }

  bool get _enforceViewportLimits =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  Size _effectiveViewportSize(BoxConstraints constraints) {
    if (!_enforceViewportLimits) {
      return Size(constraints.maxWidth, constraints.maxHeight);
    }
    var width = max(constraints.maxWidth, _appMinWidth);
    var height = max(constraints.maxHeight, _appMinHeight);
    final ratio = width / height;
    if (ratio < _appMinAspectRatio) {
      width = height * _appMinAspectRatio;
    } else if (ratio > _appMaxAspectRatio) {
      height = width / _appMaxAspectRatio;
    }
    return Size(width, height);
  }

  Widget _withMinimumViewport(BoxConstraints constraints, Widget child) {
    if (!_enforceViewportLimits) {
      return child;
    }
    final viewport = _effectiveViewportSize(constraints);
    final width = viewport.width;
    final height = viewport.height;
    final constrained = SizedBox(width: width, height: height, child: child);
    final fitsWidth = constraints.maxWidth >= width;
    final fitsHeight = constraints.maxHeight >= height;
    if (fitsWidth && fitsHeight) {
      return child;
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SingleChildScrollView(child: constrained),
    );
  }

  Widget _buildPlaybackPage() {
    return _PlaybackPage(
      coreBaseUrl: _coreUrlController.text,
      playback: _playback,
      trackDetail: _activeTrackDetail,
      activeZoneId: _activeZoneId(),
      playbackMode: _playbackMode,
      onResume: _resumeZone,
      onPause: _pauseZone,
      onPrevious: _playPreviousTrack,
      onNext: _playNextTrack,
      onSeek: _seekPlayback,
      onCycleMode: _cyclePlaybackMode,
      onShowModeMenu: _showPlaybackModeMenu,
      onShowQueue: _showQueueSheet,
      onShowDevices: _showDeviceSheet,
      onToggleFavorite: _toggleFavorite,
      onOpenTrack: _openTrackDetail,
    );
  }

  Widget _page() {
    switch (_currentRoute.kind) {
      case _AppRouteKind.home:
        return _HomePage(
          coreBaseUrl: _coreUrlController.text,
          status: _status,
          playback: _playback,
          trackDetail: _activeTrackDetail,
          zones: _zones,
          stats: _playbackStats,
          history: _playbackHistory,
          onNavigate: _setSelectedIndex,
          onOpenTrack: _openTrackDetail,
          onPlayTrack: _playTrack,
        );
      case _AppRouteKind.albums:
        return _AlbumsPage(
          coreBaseUrl: _coreUrlController.text,
          albums: _albums,
          onOpenAlbum: _openAlbumDetail,
          viewMode: _albumViewMode,
          onViewModeChanged: (mode) => _setLibraryViewMode(
            _prefsAlbumViewModeKey,
            mode,
            (mode) => _albumViewMode = mode,
          ),
        );
      case _AppRouteKind.artists:
        return _ArtistsPage(
          artists: _artists,
          onOpenArtist: _openArtistDetail,
          viewMode: _artistViewMode,
          onViewModeChanged: (mode) => _setLibraryViewMode(
            _prefsArtistViewModeKey,
            mode,
            (mode) => _artistViewMode = mode,
          ),
        );
      case _AppRouteKind.tracks:
        return _TracksPage(
          coreBaseUrl: _coreUrlController.text,
          tracks: _tracks,
          onOpenTrack: _openTrackDetail,
          onPlayTrack: _playTrack,
          onToggleFavorite: _toggleFavorite,
          onAddToPlaylist: _addTrackToPlaylist,
          viewMode: _trackViewMode,
          onViewModeChanged: (mode) => _setLibraryViewMode(
            _prefsTrackViewModeKey,
            mode,
            (mode) => _trackViewMode = mode,
          ),
        );
      case _AppRouteKind.playlists:
        return _PlaylistsPage(
          playlists: _playlists,
          onOpenPlaylist: _openPlaylistDetail,
          onCreateManual: _createManualPlaylist,
          onCreateSmart: _createSmartPlaylist,
          onDeletePlaylist: _deletePlaylist,
          viewMode: _playlistViewMode,
          onViewModeChanged: (mode) => _setLibraryViewMode(
            _prefsPlaylistViewModeKey,
            mode,
            (mode) => _playlistViewMode = mode,
          ),
        );
      case _AppRouteKind.playback:
        return _buildPlaybackPage();
      case _AppRouteKind.history:
        return _HistoryPage(
          coreBaseUrl: _coreUrlController.text,
          stats: _playbackStats,
          events: _playbackHistory,
          onOpenTrack: _openTrackDetail,
          onPlayTrack: _playTrack,
        );
      case _AppRouteKind.settings:
        return _SettingsPage(
          coreUrlController: _coreUrlController,
          serverAliasController: _serverAliasController,
          clientAliasController: _clientAliasController,
          loading: _loading,
          status: _status,
          rendererStatus: _rendererStatus,
          settings: _favoriteSettings,
          metadataSettings: _metadataSettings,
          libraryRoots: _libraryRoots,
          diagnostics: _diagnostics,
          language: _language,
          libraryRootController: _libraryRootController,
          onConnect: _refreshAll,
          onDiscover: _discoverAndRefresh,
          onScan: _startScan,
          onAddLibraryRoot: () => unawaited(_addLibraryRoot()),
          onRemoveLibraryRoot: (id) => unawaited(_removeLibraryRoot(id)),
          onSaveServerAlias: () => unawaited(_saveServerAlias()),
          onSaveClientAlias: () => unawaited(_saveClientAlias()),
          onLanguageChanged: (language) => unawaited(_setLanguage(language)),
          onUpdateFavoriteSettings: _updateFavoriteSettings,
          onUpdateMetadataSettings: _updateMetadataSettings,
        );
      case _AppRouteKind.search:
        final query = _currentRoute.query ?? _searchQuery;
        return _SearchPage(
          coreBaseUrl: _coreUrlController.text,
          query: query,
          search: _searchResultCache[query],
          scope: _searchScopeByQuery[query] ?? _SearchScope.all,
          sort: _searchSortByQuery[query] ?? _SearchSort.relevance,
          onScopeChanged: (scope) =>
              setState(() => _searchScopeByQuery[query] = scope),
          onSortChanged: (sort) =>
              setState(() => _searchSortByQuery[query] = sort),
          onOpenAlbum: _openAlbumDetail,
          onOpenArtist: _openArtistDetail,
          onOpenTrack: _openTrackDetail,
          onOpenPlaylist: _openPlaylistDetail,
          onPlayTrack: _playTrack,
          onToggleFavorite: _toggleFavorite,
          onAddToPlaylist: _addTrackToPlaylist,
        );
      case _AppRouteKind.track:
        return _TrackInfoPage(
          coreBaseUrl: _coreUrlController.text,
          detail: _trackDetailCache[_currentRoute.entityId],
          onClose: _closeTrackDetail,
          onPlayTrack: _playTrack,
          onOpenAlbum: _openAlbumDetail,
          onToggleFavorite: _toggleFavorite,
          onAddToPlaylist: _addTrackToPlaylist,
        );
      case _AppRouteKind.album:
        return _AlbumInfoPage(
          coreBaseUrl: _coreUrlController.text,
          detail: _albumDetailCache[_currentRoute.entityId],
          onClose: _closeAlbumDetail,
          onPlayTrack: _playTrack,
          onOpenTrack: _openTrackDetail,
          onToggleFavorite: _toggleFavorite,
          onAddToPlaylist: _addTrackToPlaylist,
        );
      case _AppRouteKind.artist:
        return _ArtistInfoPage(
          coreBaseUrl: _coreUrlController.text,
          detail: _artistDetailCache[_currentRoute.entityId],
          onClose: _closeArtistDetail,
          onOpenAlbum: _openAlbumDetail,
          onPlayTrack: _playTrack,
          onOpenTrack: _openTrackDetail,
          onToggleFavorite: _toggleFavorite,
          onAddToPlaylist: _addTrackToPlaylist,
        );
      case _AppRouteKind.playlist:
        final playlistId = _currentRoute.entityId;
        final detail =
            _playlistDetailCache[playlistId] ?? const <String, dynamic>{};
        return _PlaylistDetailPage(
          coreBaseUrl: _coreUrlController.text,
          detail: detail,
          onPlayTrack: _playTrack,
          onOpenTrack: _openTrackDetail,
          onToggleFavorite: _toggleFavorite,
          onEditSmart: playlistId == null
              ? () async {}
              : () => _editSmartPlaylist(playlistId, detail),
          onRemoveTrack: playlistId == null
              ? (_) async {}
              : (trackId) => _removeTrackFromPlaylist(
                  playlistId: playlistId,
                  trackId: trackId,
                ),
        );
    }
  }
}
