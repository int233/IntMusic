import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart' as ap;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
part 'src/artist_editor.dart';
part 'src/track_editor.dart';
part 'src/lyric_timeline_editor.dart';
part 'src/core_api_client.dart';
part 'src/core_discovery.dart';
part 'src/client_library.dart';
part 'src/offline_library.dart';
part 'src/client_cache.dart';
part 'src/client_log.dart';
part 'src/distribution.dart';
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
const _prefsPinCurrentClientRegionKey =
    'intmusic.playback_regions.pin_current_client';
const _prefsRegionSortKey = 'intmusic.playback_regions.sort';
const _prefsClientLibraryRootsKey = 'intmusic.client_library.roots';
const _prefsDiagnosticLoggingKey = 'intmusic.diagnostics.logging';
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
  final Map<String, StreamSubscription<bool>> _audioPlayingSubscriptions = {};
  final Map<String, AudioDevice> _rendererAudioDevicesByOutput = {};
  final Map<String, Map<String, dynamic>> _rendererPlaybackByOutput = {};
  final Map<String, int> _rendererLoadedTrackByOutput = {};
  Player? _rendererDeviceProbe;
  StreamSubscription<List<AudioDevice>>? _rendererDeviceSubscription;
  Future<void>? _rendererAudioInitialization;
  Timer? _rendererHeartbeat;
  Timer? _rendererPositionReporter;
  Timer? _zoneRefreshTimer;
  Timer? _offlineReconnectTimer;
  Timer? _distributionTimer;
  Timer? _librarySyncTimer;
  Timer? _eventReconnectTimer;
  int _zoneRefreshFailures = 0;
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
  List<_ClientLibraryRoot> _clientLibraryRoots = const [];
  List<dynamic> _clientLibraryStatuses = const [];
  List<dynamic> _distributionJobs = const [];
  Map<String, dynamic>? _transcodingStatus;
  final Set<String> _clientLibrarySyncingRootIds = <String>{};
  final Set<String> _distributionDirtyRootIds = <String>{};
  bool _distributionWorkerBusy = false;
  _OfflineLibrarySnapshot _offlineLibrary = _OfflineLibrarySnapshot();
  String? _cacheServerId;
  int _cacheCursor = 0;
  bool _backgroundSyncBusy = false;
  bool _detailWarmupBusy = false;
  bool _rendererHeartbeatBusy = false;
  bool _rendererPositionReportBusy = false;
  bool _zoneRefreshBusy = false;
  bool _eventConnectBusy = false;
  int _backgroundSyncTicks = 0;
  final Set<String> _detailRefreshScopes = <String>{};
  final Map<String, int> _detailWarmAfterIds = <String, int>{};
  final Map<String, int> _detailWarmTargetCursors = <String, int>{};
  bool _offlineMode = false;
  bool _diagnosticLoggingEnabled = true;
  String _diagnosticLogPath = '';
  final Map<String, int> _optimisticLocalTrackByOutput = <String, int>{};
  final Map<String, DateTime> _optimisticLocalStartedAtByOutput =
      <String, DateTime>{};
  final Map<String, bool> _rendererLocalFileByOutput = <String, bool>{};
  DateTime? _offlinePlaybackStartedAt;
  int _offlinePlaybackStartPositionMs = 0;
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
  bool _pinCurrentClientRegion = true;
  _ZoneRegionSort _zoneRegionSort = _ZoneRegionSort.playingFirst;
  List<_SearchSuggestion> _searchSuggestions = const [];
  List<String> _recentSearches = const [];
  late final AnimationController _playbackRevealController;
  int _pageTransitionDirection = 1;

  CoreApiClient get _api => CoreApiClient(_coreUrlController.text);
  String get _clientId => _sanitizeRendererId(
    'flutter-${Platform.operatingSystem}-${Platform.localHostname}',
  );
  String get _clientZonePrefix => 'renderer:$_clientId:';
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
    _offlineReconnectTimer?.cancel();
    _distributionTimer?.cancel();
    _librarySyncTimer?.cancel();
    _eventReconnectTimer?.cancel();
    _searchDebounce?.cancel();
    unawaited(_reportRendererShutdown());
    unawaited(_eventSocket?.close() ?? Future<void>.value());
    for (final subscription in _audioCompleteSubscriptions.values) {
      unawaited(subscription.cancel());
    }
    for (final subscription in _audioPlayingSubscriptions.values) {
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
    bool connected;
    if (_tracks.isNotEmpty || _albums.isNotEmpty || _artists.isNotEmpty) {
      try {
        await _refreshAllInner(allowDiscovery: true);
        connected = true;
        if (mounted) setState(() => _error = null);
      } catch (error) {
        connected = false;
        await _ClientCacheStore.recordError(_coreUrlController.text, error);
        if (mounted) {
          setState(() {
            _rendererStatus = 'Using cached library';
            _error = null;
          });
        }
      }
    } else {
      connected =
          await _run<bool>(() async {
            await _refreshAllInner(allowDiscovery: true);
            return true;
          }) ??
          false;
    }
    if (connected != true && _offlineLibrary.copies.isNotEmpty) {
      await _activateOfflineMode();
    }
  }

  Future<void> _initializeAndRefresh() async {
    await _IntMusicPlatform.instance.initialize(
      onCommand: _handlePlatformCommand,
      onSeek: _seekPlayback,
    );
    await _loadSavedCoreUrl();
    await _loadClientCache();
    await _rendererAudioInitialization;
    await _refreshAll();
  }

  Future<void> _loadClientCache() async {
    final cached = await _ClientCacheStore.load(_coreUrlController.text);
    if (cached.isEmpty || !mounted) return;
    setState(() {
      _cacheServerId = cached.serverId;
      _cacheCursor = cached.cursor;
      _applyCachedValues(cached.values);
      _trackDetailCache.addAll(cached.trackDetails);
      _albumDetailCache.addAll(cached.albumDetails);
      _artistDetailCache.addAll(cached.artistDetails);
      _playlistDetailCache.addAll(cached.playlistDetails);
      _detailWarmAfterIds.addAll(cached.pendingDetailRefresh);
      _detailWarmTargetCursors.addAll(cached.pendingDetailTargetCursors);
      _detailRefreshScopes.addAll(cached.pendingDetailRefresh.keys);
      _reconcileTrackSummariesInDetails();
      _rendererStatus = 'Cached library ready';
    });
  }

  void _applyCachedValues(Map<String, dynamic> values) {
    _albums = (values['albums'] as List?) ?? _albums;
    _artists = (values['artists'] as List?) ?? _artists;
    _tracks = (values['tracks'] as List?) ?? _tracks;
    _playlists = (values['playlists'] as List?) ?? _playlists;
    _outputs = (values['outputs'] as List?) ?? _outputs;
    _zones = (values['zones'] as List?) ?? _zones;
    if (values['playback'] is Map) {
      _playback = _withPlaybackTimestamp(_asMap(values['playback']));
    }
    if (values['playback_queue'] is Map) {
      _playbackQueue = _asMap(values['playback_queue']);
    }
    _playbackHistory =
        (values['playback_history'] as List?) ?? _playbackHistory;
    if (values['playback_stats'] is Map) {
      _playbackStats = _asMap(values['playback_stats']);
    }
    _libraryRoots = (values['library_roots'] as List?) ?? _libraryRoots;
    _clientLibraryStatuses =
        (values['client_library_roots'] as List?) ?? _clientLibraryStatuses;
    final settings = _asMap(values['settings']);
    if (settings.isNotEmpty) {
      _serverSettings = _asMap(settings['server']);
      _favoriteSettings = _asMap(settings['favorites']);
      _metadataSettings = _asMap(settings['metadata']);
    }
    if (values['status'] is Map) {
      _status = _asMap(values['status']);
    }
    if (values['diagnostics'] is Map) {
      _diagnostics = _asMap(values['diagnostics']);
    }
  }

  void _applySyncSnapshot(
    Map<String, dynamic> snapshot, {
    Map<String, dynamic>? status,
    Map<String, dynamic>? diagnostics,
  }) {
    final nextServerId = snapshot['server_id']?.toString();
    final serverChanged =
        _cacheServerId != null &&
        nextServerId != null &&
        _cacheServerId != nextServerId;
    if (serverChanged) {
      _trackDetailCache.clear();
      _albumDetailCache.clear();
      _artistDetailCache.clear();
      _playlistDetailCache.clear();
      _searchResultCache.clear();
      _detailWarmAfterIds.clear();
      _detailWarmTargetCursors.clear();
      _activeTrackDetail = null;
      _activeTrackDetailId = null;
    }
    _cacheServerId = nextServerId;
    _cacheCursor = _intValue(snapshot['cursor']) ?? _cacheCursor;
    _albums = (snapshot['albums'] as List?) ?? const <dynamic>[];
    _artists = (snapshot['artists'] as List?) ?? const <dynamic>[];
    _tracks = (snapshot['tracks'] as List?) ?? const <dynamic>[];
    _playlists = (snapshot['playlists'] as List?) ?? const <dynamic>[];
    _playbackHistory =
        (snapshot['playback_history'] as List?) ?? const <dynamic>[];
    _playbackStats = _asMap(snapshot['playback_stats']);
    _libraryRoots = (snapshot['library_roots'] as List?) ?? const <dynamic>[];
    _clientLibraryStatuses =
        (snapshot['client_library_roots'] as List?) ?? const <dynamic>[];
    final settings = _asMap(snapshot['settings']);
    _serverSettings = _asMap(settings['server']);
    _favoriteSettings = _asMap(settings['favorites']);
    _metadataSettings = _asMap(settings['metadata']);
    final trackIds = _entityIds(_tracks);
    final albumIds = _entityIds(_albums);
    final artistIds = _entityIds(_artists);
    final playlistIds = _entityIds(_playlists);
    _trackDetailCache.removeWhere((id, _) => !trackIds.contains(id));
    _albumDetailCache.removeWhere((id, _) => !albumIds.contains(id));
    _artistDetailCache.removeWhere((id, _) => !artistIds.contains(id));
    _playlistDetailCache.removeWhere((id, _) => !playlistIds.contains(id));
    _reconcileTrackSummariesInDetails();
    if (status != null) _status = status;
    if (diagnostics != null) _diagnostics = diagnostics;
  }

  Set<int> _entityIds(List<dynamic> values) => <int>{
    for (final value in values)
      if (value is Map && _intValue(value['id']) != null)
        _intValue(value['id'])!,
  };

  void _reconcileTrackSummariesInDetails() {
    final tracksById = <int, Map<String, dynamic>>{
      for (final value in _tracks)
        if (value is Map && _intValue(value['id']) != null)
          _intValue(value['id'])!: value.cast<String, dynamic>(),
    };
    for (final entry in _trackDetailCache.entries.toList(growable: false)) {
      final summary = tracksById[entry.key];
      if (summary != null) {
        _trackDetailCache[entry.key] = <String, dynamic>{
          ...entry.value,
          'track': summary,
        };
      }
    }
    for (final cache in <Map<int, Map<String, dynamic>>>[
      _albumDetailCache,
      _artistDetailCache,
      _playlistDetailCache,
    ]) {
      for (final entry in cache.entries.toList(growable: false)) {
        final detailTracks = (entry.value['tracks'] as List?) ?? const [];
        cache[entry.key] = <String, dynamic>{
          ...entry.value,
          'tracks': detailTracks
              .map((value) {
                if (value is! Map) return value;
                final id = _intValue(value['id']);
                return id == null ? value : tracksById[id] ?? value;
              })
              .toList(growable: false),
        };
      }
    }
  }

  Map<String, dynamic> _snapshotForStorage(
    Map<String, dynamic> snapshot, {
    Map<String, dynamic>? status,
    Map<String, dynamic>? diagnostics,
  }) {
    final stored = <String, dynamic>{...snapshot};
    if (status != null) stored['status'] = status;
    if (diagnostics != null) stored['diagnostics'] = diagnostics;
    return stored;
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
      final pinCurrentClientRegion =
          preferences.getBool(_prefsPinCurrentClientRegionKey) ?? true;
      final zoneRegionSort = _zoneRegionSortFromPreference(
        preferences.getString(_prefsRegionSortKey),
      );
      final diagnosticLoggingEnabled =
          preferences.getBool(_prefsDiagnosticLoggingKey) ?? true;
      await _ClientLog.initialize(enabled: diagnosticLoggingEnabled);
      var clientLibraryRoots = _decodeClientLibraryRoots(
        preferences.getString(_prefsClientLibraryRootsKey),
      );
      clientLibraryRoots = await Future.wait(
        clientLibraryRoots.map((root) async {
          final access = await _IntMusicPlatform.instance.restoreFolderAccess(
            root.path,
            root.accessToken,
          );
          return root.copyWith(path: access.path, accessToken: access.token);
        }),
      );
      await preferences.setString(
        _prefsClientLibraryRootsKey,
        jsonEncode(
          clientLibraryRoots
              .map((root) => root.toJson())
              .toList(growable: false),
        ),
      );
      final offlineLibrary = await _OfflineLibraryStore.load();
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
        _pinCurrentClientRegion = pinCurrentClientRegion;
        _zoneRegionSort = zoneRegionSort;
        _diagnosticLoggingEnabled = diagnosticLoggingEnabled;
        _diagnosticLogPath = _ClientLog.path;
        _clientLibraryRoots = clientLibraryRoots;
        _offlineLibrary = offlineLibrary;
        _recentSearches = recentSearches.take(10).toList(growable: false);
        _clientAliasController.text = savedClientAlias?.isNotEmpty == true
            ? savedClientAlias!
            : _defaultClientAlias();
      });
    } catch (error, stackTrace) {
      _ClientLog.error(
        'client.preferences.load_failed',
        error,
        stackTrace: stackTrace,
      );
      // Preferences are optional; discovery can still find the core.
    }
  }

  Future<void> _setDiagnosticLogging(bool enabled) async {
    final preferences = _preferences ?? await SharedPreferences.getInstance();
    _preferences = preferences;
    await preferences.setBool(_prefsDiagnosticLoggingKey, enabled);
    if (_ClientLog.path.isEmpty) {
      await _ClientLog.initialize(enabled: enabled);
    } else {
      _ClientLog.setEnabled(enabled);
    }
    if (!mounted) return;
    setState(() {
      _diagnosticLoggingEnabled = enabled;
      _diagnosticLogPath = _ClientLog.path;
    });
  }

  Future<void> _exportDiagnosticLog() async {
    try {
      final timestamp = DateTime.now().toUtc().toIso8601String().replaceAll(
        RegExp(r'[:.]'),
        '-',
      );
      final location = await getSaveLocation(
        suggestedName: 'intmusic-client-$timestamp.jsonl',
        acceptedTypeGroups: const <XTypeGroup>[
          XTypeGroup(label: 'JSON Lines log', extensions: <String>['jsonl']),
        ],
      );
      if (location == null) return;
      await _ClientLog.exportTo(location.path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_tr(context, 'Diagnostic log exported'))),
      );
    } catch (error, stackTrace) {
      _ClientLog.error(
        'client.log.export_failed',
        error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${_tr(context, 'Export failed')}: $error')),
      );
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

  _ZoneRegionSort _zoneRegionSortFromPreference(String? value) {
    return switch (value) {
      'name' => _ZoneRegionSort.name,
      _ => _ZoneRegionSort.playingFirst,
    };
  }

  Future<void> _setPinCurrentClientRegion(bool value) async {
    setState(() => _pinCurrentClientRegion = value);
    try {
      final preferences = _preferences ?? await SharedPreferences.getInstance();
      _preferences = preferences;
      await preferences.setBool(_prefsPinCurrentClientRegionKey, value);
    } catch (_) {
      // Region ordering remains available for the current session.
    }
  }

  Future<void> _setZoneRegionSort(_ZoneRegionSort value) async {
    setState(() => _zoneRegionSort = value);
    try {
      final preferences = _preferences ?? await SharedPreferences.getInstance();
      _preferences = preferences;
      await preferences.setString(_prefsRegionSortKey, value.name);
    } catch (_) {
      // Region ordering remains available for the current session.
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

  Future<void> _activateOfflineMode() async {
    if (_offlineMode) return;
    _rendererHeartbeat?.cancel();
    _rendererPositionReporter?.cancel();
    _zoneRefreshTimer?.cancel();
    _distributionTimer?.cancel();
    _librarySyncTimer?.cancel();
    _eventReconnectTimer?.cancel();
    await _eventSocket?.close();
    _eventSocket = null;
    final localTracks = <int, Map<String, dynamic>>{
      for (final value in _offlineTrackSummaries(
        _offlineLibrary,
      ).whereType<Map>())
        if (_intValue(value['id']) != null)
          _intValue(value['id'])!: value.cast<String, dynamic>(),
    };
    final tracks = _tracks.isEmpty
        ? localTracks.values.toList(growable: false)
        : _tracks
              .map((value) {
                final cached = _asMap(value);
                final local = localTracks[_intValue(cached['id'])];
                if (local == null) {
                  return <String, dynamic>{
                    ...cached,
                    '_local_available': false,
                  };
                }
                return <String, dynamic>{
                  ...cached,
                  'is_favorite': local['is_favorite'] ?? cached['is_favorite'],
                  'play_count': local['play_count'] ?? cached['play_count'],
                  '_offline': true,
                  '_local_available': true,
                };
              })
              .toList(growable: false);
    final albums = _albums.isEmpty
        ? _offlineAlbumSummaries(_offlineLibrary)
        : _albums;
    final artists = _artists.isEmpty
        ? _offlineArtistSummaries(_offlineLibrary)
        : _artists;
    final stoppedPlayback = <String, dynamic>{
      'zone_id': _clientOutputId,
      'state': 'stopped',
      'track_id': null,
      'track_title': null,
      'position_ms': 0,
      'queue_revision': 0,
    };
    if (!mounted) return;
    setState(() {
      _offlineMode = true;
      _rendererStatus = 'Offline local playback';
      _error = null;
      _tracks = tracks;
      _albums = albums;
      _artists = artists;
      _outputs = <dynamic>[
        <String, dynamic>{
          'id': _clientOutputId,
          'name': _clientAlias(),
          'node_name': _clientAlias(),
          'is_online': true,
          'is_default': true,
        },
      ];
      _zones = <dynamic>[
        <String, dynamic>{
          'id': _clientOutputId,
          'name': _clientAlias(),
          'state': 'stopped',
          'track_id': null,
          'track_title': null,
          'position_ms': 0,
          'volume': 1.0,
          'muted': false,
          'is_online': true,
        },
      ];
      _selectedZoneId = _clientOutputId;
      _selectedZoneLabel = _tr(context, 'Offline · This device');
      _playback = _withPlaybackTimestamp(stoppedPlayback);
      _playbackQueue = <String, dynamic>{
        'zone_id': _clientOutputId,
        'revision': 0,
        'mode': _playbackMode.nameForApi,
        'current_index': null,
        'items': const <dynamic>[],
      };
      _status = <String, dynamic>{
        ...?_status,
        'name': 'IntMusic Offline',
        'display_name': _tr(context, 'Offline library'),
        'version': _status?['version']?.toString() ?? 'local',
        'api_version': 'offline',
        'server_id': _offlineLibrary.serverId ?? 'offline',
        'database_path': '-',
        'counts': <String, dynamic>{
          'library_roots': _clientLibraryRoots.length,
          'files': tracks.length,
          'tracks': tracks.length,
          'albums': albums.length,
          'artists': artists.length,
          'scan_problems': 0,
        },
      };
      _favoriteSettings ??= <String, dynamic>{
        'treat_max_rating_as_favorite': true,
        'write_rating_on_favorite': false,
      };
    });
    _ClientLog.event(
      'client.offline.activated',
      data: <String, Object?>{
        'cached_tracks': tracks.length,
        'local_tracks': localTracks.length,
        'cached_albums': albums.length,
        'cached_artists': artists.length,
        'cached_playlists': _playlists.length,
      },
    );
    _offlineReconnectTimer?.cancel();
    _offlineReconnectTimer = Timer.periodic(const Duration(seconds: 12), (_) {
      if (!_loading && _offlineMode) {
        unawaited(_refreshAll());
      }
    });
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
    final serverId = status['server_id']?.toString() ?? '';
    final syncSnapshot = await _fetchSyncSnapshot(
      status,
      force: _cacheServerId != serverId || _tracks.isEmpty,
    );
    final results = await Future.wait<dynamic>([
      _api.getJson('/outputs'),
      _api.getJson('/zones'),
      _api.getJson('/diagnostics'),
      _api.getJson('/settings/server'),
      _api.getJson('/playback/stats?top_limit=20'),
      _api.getJson('/playback/history?limit=250'),
      _api.getJson('/settings/favorites'),
      _api.getJson('/settings/metadata'),
      _api
          .getJson('/transcoding/status')
          .catchError((_) => const <String, dynamic>{}),
    ]);
    _status = status;
    _outputs = results[0] as List<dynamic>;
    _zones = results[1] as List<dynamic>;
    _diagnostics = _asMap(results[2]);
    _serverSettings = _asMap(results[3]);
    _serverAliasController.text =
        _serverSettings?['alias']?.toString() ??
        status['display_name']?.toString() ??
        'Core local';
    _playbackStats = _asMap(results[4]);
    _playbackHistory = results[5] as List<dynamic>;
    _favoriteSettings = _asMap(results[6]);
    _metadataSettings = _asMap(results[7]);
    _transcodingStatus = _asMap(results[8]);
    if (syncSnapshot != null) {
      final settings = <String, dynamic>{
        ..._asMap(syncSnapshot['settings']),
        'server': _serverSettings,
        'favorites': _favoriteSettings,
        'metadata': _metadataSettings,
      };
      final storageSnapshot = <String, dynamic>{
        ...syncSnapshot,
        'settings': settings,
        'playback_stats': _playbackStats,
        'playback_history': _playbackHistory,
      };
      _applySyncSnapshot(
        storageSnapshot,
        status: status,
        diagnostics: _diagnostics,
      );
      await _ClientCacheStore.replaceSnapshot(
        coreUrl,
        _snapshotForStorage(
          storageSnapshot,
          status: status,
          diagnostics: _diagnostics,
        ),
      );
      await _markPendingDetailRefresh();
    } else {
      await _persistOverviewValues(<String, dynamic>{
        'status': status,
        'diagnostics': _diagnostics,
        'playback_stats': _playbackStats,
        'playback_history': _playbackHistory,
        'settings': <String, dynamic>{
          'server': _serverSettings,
          'favorites': _favoriteSettings,
          'metadata': _metadataSettings,
        },
      });
    }
    if (_offlineMode) {
      await _finishOfflinePlayback('reconnected');
      await (await _playerForOutput(_clientOutputId)).stop();
    }
    _offlineMode = false;
    _offlineReconnectTimer?.cancel();
    _startRendererHeartbeat();
    _startRendererPositionReporter();
    _startZoneRefresh();
    _startDistributionWorker();
    _startLibrarySync();
    unawaited(_refreshDistributionJobs());
    _offlineLibrary.serverId = status['server_id']?.toString();
    final flushedOfflineMutations = await _flushOfflineMutations();
    if (flushedOfflineMutations) {
      await _backgroundLibrarySync();
      unawaited(_refreshHistoryCache());
    }
    final onlineTracks = <int, Map<String, dynamic>>{
      for (final value in _tracks.whereType<Map>())
        if (_intValue(value['id']) != null)
          _intValue(value['id'])!: value.cast<String, dynamic>(),
    };
    for (final entry in _offlineLibrary.copies.entries.toList(
      growable: false,
    )) {
      final online = onlineTracks[entry.value.trackId];
      if (online == null) continue;
      _offlineLibrary.copies[entry.key] = entry.value.copyWith(
        isFavorite: online['is_favorite'] == true,
        playCount: _intValue(online['play_count']) ?? entry.value.playCount,
      );
    }
    await _OfflineLibraryStore.save(_offlineLibrary);
    _keepSelectedZoneValid();
    _syncPlaybackFromSelectedZone();
    await _refreshPlaybackQueue();
    _scheduleActiveTrackDetailLoad(_playback);
    await _persistOverviewValues(<String, dynamic>{
      'outputs': _outputs,
      'zones': _zones,
      if (_playback != null) 'playback': _playback,
      if (_playbackQueue != null) 'playback_queue': _playbackQueue,
    });
    unawaited(_warmDetailCache());
  }

  Future<Map<String, dynamic>?> _fetchSyncSnapshot(
    Map<String, dynamic> status, {
    bool force = false,
  }) async {
    final serverId = status['server_id']?.toString() ?? '';
    try {
      if (force) {
        _detailRefreshScopes.addAll(const <String>{
          'track',
          'album',
          'artist',
          'playlist',
        });
      }
      if (!force && _cacheServerId == serverId) {
        final changes = _asMap(
          await _api.getJson(
            '/client-sync/changes?after=$_cacheCursor&limit=500',
          ),
        );
        if (changes['server_id']?.toString() == serverId &&
            changes['requires_snapshot'] != true) {
          _cacheCursor = _intValue(changes['cursor']) ?? _cacheCursor;
          return null;
        }
        for (final value
            in ((changes['changes'] as List?) ?? const <dynamic>[])) {
          if (value is! Map) continue;
          final reason = value['reason']?.toString().toLowerCase() ?? '';
          switch (value['scope']?.toString()) {
            case 'tracks':
              if (!reason.contains('favorite') &&
                  !reason.contains('mutation')) {
                _detailRefreshScopes.addAll(const <String>{
                  'track',
                  'album',
                  'artist',
                  'playlist',
                });
              }
            case 'albums':
              _detailRefreshScopes.add('album');
            case 'artists':
              _detailRefreshScopes.add('artist');
            case 'playlists':
              _detailRefreshScopes.add('playlist');
            default:
              _detailRefreshScopes.addAll(const <String>{
                'track',
                'album',
                'artist',
                'playlist',
              });
          }
        }
      }
      return _asMap(
        await _api.getJson(
          '/client-sync/snapshot',
          requestTimeout: const Duration(seconds: 60),
        ),
      );
    } on HttpException {
      return _loadLegacySyncSnapshot(status);
    }
  }

  Future<Map<String, dynamic>> _loadLegacySyncSnapshot(
    Map<String, dynamic> status,
  ) async {
    final values = await Future.wait<dynamic>([
      _loadPagedList('/albums'),
      _loadPagedList('/artists'),
      _loadPagedList('/tracks'),
      _api.getJson('/playlists'),
      _api.getJson('/playback/history?limit=250'),
      _api.getJson('/playback/stats?top_limit=50'),
      _api.getJson('/library/roots'),
      _api.getJson('/client-library/manifests'),
      _api.getJson('/settings'),
    ]);
    return <String, dynamic>{
      'server_id': status['server_id']?.toString() ?? '',
      'cursor': _intValue(status['library_revision']) ?? 0,
      'generated_at': DateTime.now().toUtc().toIso8601String(),
      'albums': values[0],
      'artists': values[1],
      'tracks': values[2],
      'playlists': values[3],
      'playback_history': values[4],
      'playback_stats': values[5],
      'library_roots': values[6],
      'client_library_roots': values[7],
      'settings': values[8],
    };
  }

  void _startLibrarySync() {
    _librarySyncTimer?.cancel();
    _librarySyncTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      unawaited(_backgroundLibrarySync());
      _backgroundSyncTicks += 1;
      if (_backgroundSyncTicks % 4 == 0) {
        unawaited(_refreshHistoryCache());
      }
    });
  }

  Future<void> _refreshHistoryCache() async {
    if (_offlineMode || _cacheServerId == null) return;
    try {
      final values = await Future.wait<dynamic>([
        _api.getJson('/playback/history?limit=250'),
        _api.getJson('/playback/stats?top_limit=50'),
        _api.getJson('/settings'),
      ]);
      final settings = _asMap(values[2]);
      if (mounted) {
        setState(() {
          _playbackHistory = values[0] as List<dynamic>;
          _playbackStats = _asMap(values[1]);
          _serverSettings = _asMap(settings['server']);
          _favoriteSettings = _asMap(settings['favorites']);
          _metadataSettings = _asMap(settings['metadata']);
        });
      }
      await _persistOverviewValues(<String, dynamic>{
        'playback_history': values[0],
        'playback_stats': values[1],
        'settings': settings,
      });
    } catch (error) {
      await _ClientCacheStore.recordError(_coreUrlController.text, error);
    }
  }

  Future<void> _backgroundLibrarySync({bool force = false}) async {
    if (_backgroundSyncBusy ||
        _offlineMode ||
        _rendererRegisteredCoreUrl == null) {
      return;
    }
    _backgroundSyncBusy = true;
    try {
      final status = _asMap(await _api.getJson('/status'));
      if (!_isIntMusicCoreStatus(status)) return;
      final snapshot = await _fetchSyncSnapshot(status, force: force);
      if (snapshot == null) return;
      final storageSnapshot = <String, dynamic>{
        ...snapshot,
        'settings': <String, dynamic>{
          ..._asMap(snapshot['settings']),
          if (_serverSettings != null) 'server': _serverSettings,
          if (_favoriteSettings != null) 'favorites': _favoriteSettings,
          if (_metadataSettings != null) 'metadata': _metadataSettings,
        },
      };
      if (mounted) {
        setState(() {
          _applySyncSnapshot(
            storageSnapshot,
            status: status,
            diagnostics: _diagnostics,
          );
          _error = null;
        });
      } else {
        _applySyncSnapshot(
          storageSnapshot,
          status: status,
          diagnostics: _diagnostics,
        );
      }
      await _ClientCacheStore.replaceSnapshot(
        _coreUrlController.text,
        _snapshotForStorage(
          storageSnapshot,
          status: status,
          diagnostics: _diagnostics,
        ),
      );
      await _markPendingDetailRefresh();
      unawaited(_warmDetailCache());
    } catch (error) {
      await _ClientCacheStore.recordError(_coreUrlController.text, error);
    } finally {
      _backgroundSyncBusy = false;
    }
  }

  Future<void> _warmDetailCache() async {
    if (_detailWarmupBusy || _offlineMode || _cacheServerId == null) return;
    _detailWarmupBusy = true;
    final serverId = _cacheServerId!;
    var retryPending = false;
    try {
      for (final kind in const <String>[
        'artist',
        'album',
        'playlist',
        'track',
      ]) {
        if (!_detailRefreshScopes.contains(kind)) continue;
        final target = switch (kind) {
          'artist' => _artistDetailCache,
          'album' => _albumDetailCache,
          'playlist' => _playlistDetailCache,
          _ => _trackDetailCache,
        };
        var afterId = _detailWarmAfterIds[kind] ?? 0;
        final targetCursor = _detailWarmTargetCursors[kind] ?? _cacheCursor;
        var superseded = false;
        while (!_offlineMode && _cacheServerId == serverId) {
          final response = _asMap(
            await _api.getJson(
              '/client-sync/details?kind=$kind&after_id=$afterId&limit=100',
              requestTimeout: const Duration(seconds: 60),
            ),
          );
          if (response['server_id']?.toString() != serverId) return;
          if ((_detailWarmTargetCursors[kind] ?? targetCursor) !=
              targetCursor) {
            superseded = true;
            break;
          }
          final batch = <int, Map<String, dynamic>>{};
          for (final value
              in ((response['items'] as List?) ?? const <dynamic>[])) {
            if (value is! Map) continue;
            final id = _intValue(value['id']);
            final detail = _asMap(value['detail']);
            if (id == null || detail.isEmpty) continue;
            target[id] = detail;
            batch[id] = detail;
          }
          await _ClientCacheStore.putDetails(
            _coreUrlController.text,
            serverId,
            kind,
            batch,
          );
          final next = _intValue(response['next_after_id']) ?? afterId;
          final complete = response['has_more'] != true || next <= afterId;
          _detailWarmAfterIds[kind] = next;
          await _ClientCacheStore.updateDetailWarmProgress(
            _coreUrlController.text,
            kind,
            next,
            targetCursor: targetCursor,
            complete: complete,
          );
          if ((_detailWarmTargetCursors[kind] ?? targetCursor) !=
              targetCursor) {
            superseded = true;
            break;
          }
          if (complete) break;
          afterId = next;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        if (superseded ||
            (_detailWarmTargetCursors[kind] ?? targetCursor) != targetCursor) {
          retryPending = true;
          continue;
        }
        _detailWarmAfterIds.remove(kind);
        _detailWarmTargetCursors.remove(kind);
        _detailRefreshScopes.remove(kind);
      }
      if (mounted) setState(() {});
    } on HttpException catch (error) {
      // A 404 means an older Core: details are then cached on first visit.
      // Transient HTTP failures keep their durable cursor and retry later.
      retryPending = !error.message.startsWith('HTTP 404');
      if (retryPending) {
        await _ClientCacheStore.recordError(_coreUrlController.text, error);
      }
    } catch (error) {
      retryPending = true;
      await _ClientCacheStore.recordError(_coreUrlController.text, error);
    } finally {
      _detailWarmupBusy = false;
      if (retryPending && _detailRefreshScopes.isNotEmpty && !_offlineMode) {
        unawaited(
          Future<void>.delayed(const Duration(seconds: 3), () {
            if (mounted && !_offlineMode) unawaited(_warmDetailCache());
          }),
        );
      }
    }
  }

  Future<void> _markPendingDetailRefresh() async {
    final serverId = _cacheServerId;
    if (serverId == null || _detailRefreshScopes.isEmpty) return;
    for (final kind in _detailRefreshScopes) {
      _detailWarmAfterIds[kind] = 0;
      _detailWarmTargetCursors[kind] = _cacheCursor;
    }
    await _ClientCacheStore.markDetailsForRefresh(
      _coreUrlController.text,
      serverId,
      _cacheCursor,
      _detailRefreshScopes,
    );
  }

  Future<bool> _flushOfflineMutations() async {
    if (_offlineLibrary.outbox.isEmpty) return false;
    var flushedAny = false;
    while (_offlineLibrary.outbox.isNotEmpty) {
      final batch = _offlineLibrary.outbox.take(100).toList(growable: false);
      final result = _asMap(
        await _api.postJson('/client-sync/mutations', <String, dynamic>{
          'device_id': _clientId,
          'device_name': _clientAlias(),
          'platform': Platform.operatingSystem,
          'mutations': batch
              .map((mutation) => mutation.toJson())
              .toList(growable: false),
        }),
      );
      final acknowledged = <String>{
        for (final value
            in ((result['applied_ids'] as List?) ?? const <dynamic>[]))
          value.toString(),
        for (final value
            in ((result['duplicate_ids'] as List?) ?? const <dynamic>[]))
          value.toString(),
      };
      if (acknowledged.isEmpty) {
        break;
      }
      _offlineLibrary.outbox.removeWhere(
        (mutation) => acknowledged.contains(mutation.id),
      );
      flushedAny = true;
      await _OfflineLibraryStore.save(_offlineLibrary);
      if (acknowledged.length < batch.length) {
        break;
      }
    }
    return flushedAny;
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
      if (_rendererHeartbeatBusy) return;
      _rendererHeartbeatBusy = true;
      unawaited(
        _sendRendererRegistration()
            .catchError((Object error) {
              if (mounted) {
                setState(() => _rendererStatus = 'Renderer offline');
              }
            })
            .whenComplete(() => _rendererHeartbeatBusy = false),
      );
    });
  }

  void _startRendererPositionReporter() {
    _rendererPositionReporter?.cancel();
    _rendererPositionReporter = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_rendererPositionReportBusy) return;
      _rendererPositionReportBusy = true;
      unawaited(
        _reportRendererPositions()
            .catchError((_) {})
            .whenComplete(() => _rendererPositionReportBusy = false),
      );
    });
  }

  void _startZoneRefresh() {
    _zoneRefreshTimer?.cancel();
    _zoneRefreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      unawaited(_refreshZonesSilently());
    });
  }

  void _startDistributionWorker() {
    _distributionTimer?.cancel();
    _distributionTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_pollDistributionTasks());
    });
    unawaited(_pollDistributionTasks());
  }

  Future<void> _refreshDistributionJobs() async {
    try {
      final jobs =
          await _api.getJson('/distributions?limit=100') as List<dynamic>;
      if (mounted) {
        setState(() => _distributionJobs = jobs);
      } else {
        _distributionJobs = jobs;
      }
    } catch (_) {
      // Distribution is additive; older Core versions can still be controlled.
    }
  }

  Future<void> _distributeTracks(List<int> trackIds) async {
    final uniqueTrackIds = trackIds.where((id) => id > 0).toSet().toList()
      ..sort();
    if (uniqueTrackIds.isEmpty || !mounted) {
      return;
    }
    if (_offlineMode) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _tr(context, 'Connect to Core before distributing music'),
          ),
        ),
      );
      return;
    }
    final targets = _clientLibraryStatuses
        .whereType<Map>()
        .map((value) => value.cast<String, dynamic>())
        .where(
          (value) =>
              value['enabled'] != false &&
              value['device_id'] != null &&
              value['external_id'] != null,
        )
        .toList(growable: false);
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _tr(
              context,
              'Add and sync a Client music folder before distributing music',
            ),
          ),
        ),
      );
      return;
    }
    String targetKey(Map<String, dynamic> target) =>
        '${target['device_id']}\u0000${target['external_id']}';
    final currentTarget = targets
        .where((target) => target['device_id']?.toString() == _clientId)
        .firstOrNull;
    var selectedTarget = targetKey(currentTarget ?? targets.first);
    final rawProfiles =
        (_transcodingStatus?['profiles'] as List?)?.whereType<Map>().toList() ??
        const <Map>[];
    final profiles = rawProfiles
        .map((value) => value.cast<String, dynamic>())
        .where((profile) => profile['available'] == true)
        .toList();
    if (!profiles.any((profile) => profile['id'] == 'original')) {
      profiles.insert(0, <String, dynamic>{
        'id': 'original',
        'label': 'Original',
        'codec': 'source',
        'container': 'source',
        'lossless': false,
        'available': true,
      });
    }
    var selectedQuality = profiles.first['id']?.toString() ?? 'original';
    final selection = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final selectedProfile = profiles
              .where((profile) => profile['id']?.toString() == selectedQuality)
              .firstOrNull;
          return AlertDialog(
            title: Text(_tr(context, 'Distribute music')),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    uniqueTrackIds.length == 1
                        ? _tr(context, 'Send one track to a Client library')
                        : '${_tr(context, 'Send')} '
                              '${uniqueTrackIds.length} '
                              '${_tr(context, 'tracks to a Client library')}',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: IntMusicTheme.of(context).textSecondary,
                    ),
                  ),
                  const SizedBox(height: 18),
                  DropdownButtonFormField<String>(
                    initialValue: selectedTarget,
                    decoration: InputDecoration(
                      labelText: _tr(context, 'Destination'),
                      prefixIcon: const Icon(Icons.devices_outlined),
                    ),
                    items: [
                      for (final target in targets)
                        DropdownMenuItem(
                          value: targetKey(target),
                          child: Text(
                            _joinParts([
                              target['device_name'],
                              target['display_name'],
                              target['platform'],
                            ]),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => selectedTarget = value);
                      }
                    },
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    initialValue: selectedQuality,
                    decoration: InputDecoration(
                      labelText: _tr(context, 'Quality'),
                      prefixIcon: const Icon(Icons.high_quality_outlined),
                    ),
                    items: [
                      for (final profile in profiles)
                        DropdownMenuItem(
                          value: profile['id']?.toString(),
                          child: Text(
                            _tr(
                              context,
                              profile['label']?.toString() ??
                                  profile['id']?.toString() ??
                                  'Original',
                            ),
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => selectedQuality = value);
                      }
                    },
                  ),
                  if (selectedProfile != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _distributionProfileDescription(selectedProfile),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: IntMusicTheme.of(context).textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(_tr(context, 'Cancel')),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(dialogContext, {
                  'target': selectedTarget,
                  'quality': selectedQuality,
                }),
                icon: const Icon(Icons.send_outlined),
                label: Text(_tr(context, 'Send')),
              ),
            ],
          );
        },
      ),
    );
    if (selection == null || !mounted) {
      return;
    }
    final selected = targets
        .where((target) => targetKey(target) == selection['target'])
        .firstOrNull;
    if (selected == null) {
      return;
    }
    try {
      await _api.postJson('/distributions', <String, dynamic>{
        'target_device_id': selected['device_id']?.toString(),
        'target_root_external_id': selected['external_id']?.toString(),
        'quality': selection['quality'] ?? 'original',
        'track_ids': uniqueTrackIds,
        'album_ids': const <int>[],
        'playlist_ids': const <int>[],
      });
      await _refreshDistributionJobs();
      unawaited(_pollDistributionTasks());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${_tr(context, 'Distribution created')} · '
            '${selected['device_name']} / ${selected['display_name']}',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${_tr(context, 'Distribution failed')}: $error'),
        ),
      );
    }
  }

  String _distributionProfileDescription(Map<String, dynamic> profile) {
    if (profile['id'] == 'original') {
      return _tr(
        context,
        'Copies the existing file without changing its codec or quality.',
      );
    }
    final bitrate = _intValue(profile['bitrate_kbps']);
    return _joinParts([
      profile['codec']?.toString().toUpperCase(),
      profile['container']?.toString().toUpperCase(),
      bitrate == null ? null : '$bitrate kbps',
      profile['lossless'] == true ? _tr(context, 'Lossless') : null,
    ]);
  }

  Future<void> _cancelDistributionJob(String jobId) async {
    try {
      await _api.postJson(
        '/distributions/${Uri.encodeComponent(jobId)}/cancel',
        const <String, dynamic>{},
      );
      await _refreshDistributionJobs();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${_tr(context, 'Cancel failed')}: $error')),
      );
    }
  }

  Future<void> _pollDistributionTasks() async {
    if (_distributionWorkerBusy || _offlineMode) {
      return;
    }
    _distributionWorkerBusy = true;
    var runAgain = false;
    try {
      final sourceValue = await _api.getJson(
        '/distributions/source-tasks/next'
        '?device_id=${Uri.encodeQueryComponent(_clientId)}',
      );
      if (sourceValue is Map) {
        await _executeDistributionSourceTask(
          sourceValue.cast<String, dynamic>(),
        );
        runAgain = true;
        return;
      }
      final value = await _api.getJson(
        '/distributions/tasks/next'
        '?device_id=${Uri.encodeQueryComponent(_clientId)}',
      );
      if (value is Map) {
        await _executeDistributionTask(value.cast<String, dynamic>());
        runAgain = true;
      } else if (_distributionDirtyRootIds.isNotEmpty) {
        final dirtyRoots = _distributionDirtyRootIds.toList(growable: false);
        _distributionDirtyRootIds.clear();
        for (final rootId in dirtyRoots) {
          await _syncClientLibraryRoot(rootId, refreshAfter: false);
        }
        await _refreshDistributionJobs();
      }
    } catch (_) {
      // A transient Core failure is retried by the next worker tick.
    } finally {
      _distributionWorkerBusy = false;
      if (runAgain) {
        unawaited(_pollDistributionTasks());
      }
    }
  }

  Future<void> _executeDistributionSourceTask(Map<String, dynamic> task) async {
    final taskId = task['id']?.toString();
    final rootId = task['source_root_external_id']?.toString();
    final relativePath = task['source_relative_path']?.toString();
    final uploadPath = task['upload_path']?.toString();
    final expectedSize = _intValue(task['expected_size_bytes']);
    if (taskId == null ||
        rootId == null ||
        relativePath == null ||
        uploadPath == null ||
        expectedSize == null ||
        expectedSize < 0) {
      return;
    }
    final root = _clientLibraryRoots
        .where((candidate) => candidate.externalId == rootId)
        .firstOrNull;
    final sourcePath = root == null
        ? null
        : _distributionTargetPath(root, relativePath);
    if (root == null || sourcePath == null) {
      await _reportDistributionSourceFailure(
        taskId,
        'The source folder is no longer configured on this Client.',
        retryable: false,
      );
      return;
    }

    try {
      if (mounted) {
        setState(
          () => _rendererStatus =
              'Sending ${task['title']?.toString() ?? relativePath}',
        );
      }
      final uploadUrl = _api.apiUrl(
        '$uploadPath?device_id=${Uri.encodeQueryComponent(_clientId)}',
      );
      final uploaded = Platform.isAndroid
          ? await _IntMusicPlatform.instance.uploadDistributionSource(
              apiUrl: uploadUrl,
              taskId: taskId,
              rootToken: root.accessToken,
              relativePath: relativePath,
              expectedSize: expectedSize,
            )
          : await _uploadDistributionSourceFile(
              uploadUrl: uploadUrl,
              sourcePath: sourcePath,
              expectedSize: expectedSize,
            );
      if (uploaded != expectedSize) {
        throw FileSystemException(
          'Uploaded source size does not match the catalog.',
          sourcePath,
        );
      }
      if (mounted) {
        setState(() => _rendererStatus = 'Source item sent');
      }
      await _refreshDistributionJobs();
    } catch (error) {
      await _reportDistributionSourceFailure(
        taskId,
        error.toString(),
        retryable: true,
      );
    }
  }

  Future<int> _uploadDistributionSourceFile({
    required String uploadUrl,
    required String sourcePath,
    required int expectedSize,
  }) async {
    final source = File(sourcePath);
    final actualSize = await source.length();
    if (actualSize != expectedSize) {
      throw FileSystemException(
        'The local source changed after its last library sync.',
        sourcePath,
      );
    }
    final client = HttpClient();
    try {
      final request = await client.putUrl(Uri.parse(uploadUrl));
      request.contentLength = expectedSize;
      request.headers.contentType = ContentType.binary;
      await request.addStream(source.openRead());
      final response = await request.close();
      final responseText = await utf8.decoder.bind(response).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          responseText.isEmpty
              ? 'Core rejected the source upload (${response.statusCode}).'
              : responseText,
          uri: Uri.parse(uploadUrl),
        );
      }
      return actualSize;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _reportDistributionSourceFailure(
    String taskId,
    String error, {
    required bool retryable,
  }) async {
    try {
      await _api.postJson(
        '/distributions/source-tasks/${Uri.encodeComponent(taskId)}/progress',
        <String, dynamic>{
          'device_id': _clientId,
          'state': 'failed',
          'transferred_bytes': 0,
          'retryable': retryable,
          'error': error,
        },
      );
    } catch (_) {
      // The source lease recovers the task if the failure report is lost.
    }
    if (mounted) {
      setState(() => _rendererStatus = 'Source distribution failed: $error');
    }
    await _refreshDistributionJobs();
  }

  Future<void> _executeDistributionTask(Map<String, dynamic> task) async {
    final taskId = task['id']?.toString();
    final rootId = task['target_root_external_id']?.toString();
    final relativePath = task['relative_path']?.toString();
    final contentPath = task['content_path']?.toString();
    final expectedSize = _intValue(task['expected_size_bytes']);
    if (taskId == null ||
        rootId == null ||
        relativePath == null ||
        contentPath == null ||
        expectedSize == null ||
        expectedSize < 0) {
      return;
    }
    final root = _clientLibraryRoots
        .where((candidate) => candidate.externalId == rootId)
        .firstOrNull;
    if (root == null) {
      await _reportDistributionFailure(
        taskId,
        0,
        'The target folder is no longer configured on this Client.',
        retryable: false,
      );
      return;
    }
    final targetPath = _distributionTargetPath(root, relativePath);
    if (targetPath == null) {
      await _reportDistributionFailure(
        taskId,
        0,
        'Core returned an unsafe distribution path.',
        retryable: false,
      );
      return;
    }

    var transferred = 0;
    try {
      if (mounted) {
        setState(
          () => _rendererStatus =
              'Receiving ${task['title']?.toString() ?? relativePath}',
        );
      }
      Future<void> reportProgress(int bytes) async {
        transferred = bytes;
        try {
          await _api.postJson(
            '/distributions/tasks/${Uri.encodeComponent(taskId)}/progress',
            <String, dynamic>{
              'device_id': _clientId,
              'state': 'progress',
              'transferred_bytes': bytes,
              'retryable': true,
              'error': null,
            },
          );
        } catch (_) {
          // Completion or the durable lease will reconcile missed heartbeats.
        }
      }

      final result = Platform.isAndroid
          ? await _IntMusicPlatform.instance.downloadDistributionTask(
              apiUrl: _api.apiUrl(
                '$contentPath?device_id=${Uri.encodeQueryComponent(_clientId)}',
              ),
              taskId: taskId,
              rootToken: root.accessToken,
              relativePath: relativePath,
              expectedSize: expectedSize,
              expectedQuickHash: task['expected_quick_hash']?.toString(),
            )
          : await _downloadDistributionFile(
              api: _api,
              contentPath: contentPath,
              deviceId: _clientId,
              taskId: taskId,
              targetPath: targetPath,
              expectedSize: expectedSize,
              expectedQuickHash: task['expected_quick_hash']?.toString(),
              onProgress: reportProgress,
            );
      transferred = result.bytes;
      await _api.postJson(
        '/distributions/tasks/${Uri.encodeComponent(taskId)}/progress',
        <String, dynamic>{
          'device_id': _clientId,
          'state': 'completed',
          'transferred_bytes': result.bytes,
          'retryable': false,
          'error': null,
        },
      );
      _distributionDirtyRootIds.add(rootId);
      if (mounted) {
        setState(() => _rendererStatus = 'Distribution item completed');
      }
      await _refreshDistributionJobs();
    } catch (error) {
      await _reportDistributionFailure(
        taskId,
        transferred,
        error.toString(),
        retryable: true,
      );
    }
  }

  Future<void> _reportDistributionFailure(
    String taskId,
    int transferred,
    String error, {
    required bool retryable,
  }) async {
    try {
      await _api.postJson(
        '/distributions/tasks/${Uri.encodeComponent(taskId)}/progress',
        <String, dynamic>{
          'device_id': _clientId,
          'state': 'failed',
          'transferred_bytes': transferred,
          'retryable': retryable,
          'error': error,
        },
      );
    } catch (_) {
      // The Core lease recovers tasks when an error report cannot be delivered.
    }
    if (mounted) {
      setState(() => _rendererStatus = 'Distribution failed: $error');
    }
    await _refreshDistributionJobs();
  }

  Future<void> _refreshZonesSilently() async {
    if (_zoneRefreshBusy) return;
    _zoneRefreshBusy = true;
    try {
      final zones = await _api.getJson('/zones') as List<dynamic>;
      _zoneRefreshFailures = 0;
      if (!mounted) {
        return;
      }
      setState(() {
        _zones = zones;
        _keepSelectedZoneValid();
        _syncPlaybackFromSelectedZone();
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

  Future<void> _connectEventStream() async {
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
      final socket = await WebSocket.connect(_api.wsUrl('/ws/v1/events'));
      _eventSocket = socket;
      _ClientLog.event(
        'core.websocket.connected',
        data: <String, Object?>{'host': Uri.parse(baseUrl).host},
      );
      socket.listen(
        _handleCoreEvent,
        onDone: () {
          if (mounted && _eventSocket == socket) {
            setState(() => _rendererStatus = 'Renderer disconnected');
            _eventSocket = null;
            _ClientLog.event('core.websocket.closed', level: 'warning');
            _scheduleEventReconnect();
          }
        },
        onError: (Object error) {
          if (mounted && _eventSocket == socket) {
            setState(() => _rendererStatus = 'Renderer disconnected');
            _eventSocket = null;
            _ClientLog.error('core.websocket.error', error);
            _scheduleEventReconnect();
          }
        },
      );
    } catch (error, stackTrace) {
      _ClientLog.error(
        'core.websocket.connect_failed',
        error,
        stackTrace: stackTrace,
      );
      _eventSocket = null;
      _rendererStatus = 'Renderer offline';
      _scheduleEventReconnect();
    } finally {
      _eventConnectBusy = false;
    }
  }

  void _scheduleEventReconnect() {
    _eventReconnectTimer?.cancel();
    _eventReconnectTimer = Timer(const Duration(seconds: 3), () {
      if (!_offlineMode && mounted) {
        unawaited(_connectEventStream());
      }
    });
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
      _audioPlayingSubscriptions[outputId] = player.playing.distinct().listen((
        playing,
      ) {
        _ClientLog.event(
          playing
              ? 'renderer.player.audio_started'
              : 'renderer.player.audio_inactive',
          data: <String, Object?>{
            'output_id': outputId,
            'track_id': _rendererLoadedTrackByOutput[outputId],
          },
        );
      });
      return player;
    } catch (_) {
      await _audioCompleteSubscriptions.remove(outputId)?.cancel();
      await _audioPlayingSubscriptions.remove(outputId)?.cancel();
      await player?.dispose();
      rethrow;
    }
  }

  Future<void> _disposeRendererPlayer(String outputId) async {
    final subscription = _audioCompleteSubscriptions.remove(outputId);
    await subscription?.cancel();
    final playingSubscription = _audioPlayingSubscriptions.remove(outputId);
    await playingSubscription?.cancel();
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
    if (_offlineMode && outputId == _clientOutputId) {
      await _finishOfflinePlayback('completed');
      await _playNextOfflineTrack(completed: true);
      return;
    }
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

  Future<void> _addClientLibraryRoot() async {
    try {
      final addFolderLabel = _tr(context, 'Add folder');
      final androidSelection = Platform.isAndroid
          ? await _IntMusicPlatform.instance.selectClientLibraryFolder()
          : null;
      final path = Platform.isAndroid
          ? androidSelection?.path
          : await getDirectoryPath(confirmButtonText: addFolderLabel);
      if (!mounted || path == null || path.trim().isEmpty) {
        return;
      }
      final access = Platform.isAndroid
          ? (path: path, token: androidSelection!.token as String?)
          : await _IntMusicPlatform.instance.persistFolderAccess(path);
      final normalizedPath = _normalizeLocalRootPath(access.path);
      final existing = _clientLibraryRoots
          .where((root) => root.path == normalizedPath)
          .firstOrNull;
      if (existing != null) {
        await _syncClientLibraryRoot(existing.externalId);
        return;
      }
      final root = _ClientLibraryRoot(
        externalId: _newClientLibraryRootId(),
        path: normalizedPath,
        displayName:
            androidSelection?.displayName ??
            _localRootDisplayName(normalizedPath),
        accessToken: access.token,
      );
      setState(() => _clientLibraryRoots = [..._clientLibraryRoots, root]);
      await _persistClientLibraryRoots();
      await _syncClientLibraryRoot(root.externalId);
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Unable to add this device folder: $error');
      }
    }
  }

  Future<void> _syncAllClientLibraryRoots() async {
    for (final root in List<_ClientLibraryRoot>.of(_clientLibraryRoots)) {
      await _syncClientLibraryRoot(root.externalId, refreshAfter: false);
    }
    if (mounted && _clientLibraryRoots.isNotEmpty) {
      await _refreshAll();
    }
  }

  Future<void> _syncClientLibraryRoot(
    String externalId, {
    bool refreshAfter = true,
  }) async {
    final root = _clientLibraryRoots
        .where((item) => item.externalId == externalId)
        .firstOrNull;
    if (root == null || _clientLibrarySyncingRootIds.contains(externalId)) {
      return;
    }
    setState(() {
      _clientLibrarySyncingRootIds.add(externalId);
      _replaceClientLibraryRoot(root.copyWith(clearError: true));
    });
    try {
      final directory = Directory(root.path);
      if (!await directory.exists()) {
        throw FileSystemException(
          'The folder is unavailable. Re-add it to restore access.',
          root.path,
        );
      }
      final scanId =
          '${DateTime.now().toUtc().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
      var accepted = 0;
      var batch = <Map<String, dynamic>>[];
      final seenExternalIds = <String>{};
      Future<void> sendBatch({required bool complete}) async {
        final sentBatch = List<Map<String, dynamic>>.of(batch);
        final result = _asMap(
          await _api.postJson('/client-library/manifests', <String, dynamic>{
            'device_id': _clientId,
            'device_name': _clientAlias(),
            'platform': Platform.operatingSystem,
            'root': <String, dynamic>{
              'external_id': root.externalId,
              'display_name': root.displayName,
              'path_hint': root.path,
            },
            'scan_id': scanId,
            'complete': complete,
            'files': batch,
          }),
        );
        accepted += _intValue(result['accepted_files']) ?? batch.length;
        final bindings = <String, Map<String, dynamic>>{
          for (final value in ((result['bindings'] as List?) ?? const []))
            if (value is Map && value['external_id'] != null)
              value['external_id'].toString(): value.cast<String, dynamic>(),
        };
        for (final file in sentBatch) {
          final externalId = file['external_id']?.toString();
          final binding = externalId == null ? null : bindings[externalId];
          final trackId = _intValue(binding?['track_id']);
          final variantId = _intValue(binding?['media_variant_id']);
          if (externalId == null || trackId == null || variantId == null) {
            continue;
          }
          seenExternalIds.add(externalId);
          _offlineLibrary.upsert(
            _OfflineTrackCopy(
              trackId: trackId,
              mediaVariantId: variantId,
              rootExternalId: root.externalId,
              fileExternalId: externalId,
              relativePath: file['relative_path']?.toString() ?? externalId,
              extension: file['extension']?.toString() ?? '',
              sizeBytes: _intValue(file['size_bytes']) ?? 0,
              modifiedAt:
                  DateTime.tryParse(file['modified_at']?.toString() ?? '') ??
                  DateTime.now().toUtc(),
              metadata:
                  (file['metadata'] as Map?)?.cast<String, dynamic>() ??
                  const <String, dynamic>{},
              isFavorite: _offlineLibrary.track(trackId)?.isFavorite ?? false,
              playCount: _offlineLibrary.track(trackId)?.playCount ?? 0,
            ),
          );
        }
        batch = <Map<String, dynamic>>[];
      }

      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File || !_isSupportedClientAudioPath(entity.path)) {
          continue;
        }
        batch.add(await _clientFileManifest(root.path, entity));
        if (batch.length >= 50) {
          await sendBatch(complete: false);
        }
      }
      await sendBatch(complete: true);
      _offlineLibrary.retainRootFiles(root.externalId, seenExternalIds);
      await _OfflineLibraryStore.save(_offlineLibrary);
      final updated = root.copyWith(
        lastSyncedAt: DateTime.now().toUtc(),
        fileCount: accepted,
        clearError: true,
      );
      if (mounted) {
        setState(() => _replaceClientLibraryRoot(updated));
      } else {
        _replaceClientLibraryRoot(updated);
      }
      await _persistClientLibraryRoots();
      if (refreshAfter && mounted) {
        await _refreshAll();
      }
    } catch (error) {
      final updated = root.copyWith(lastError: error.toString());
      if (mounted) {
        setState(() {
          _replaceClientLibraryRoot(updated);
          _error = 'Local library sync failed: $error';
        });
      } else {
        _replaceClientLibraryRoot(updated);
      }
      await _persistClientLibraryRoots();
    } finally {
      if (mounted) {
        setState(() => _clientLibrarySyncingRootIds.remove(externalId));
      } else {
        _clientLibrarySyncingRootIds.remove(externalId);
      }
    }
  }

  Future<void> _removeClientLibraryRoot(String externalId) async {
    final root = _clientLibraryRoots
        .where((item) => item.externalId == externalId)
        .firstOrNull;
    if (root == null) {
      return;
    }
    try {
      await _api.deleteJson(
        '/client-library/devices/${Uri.encodeComponent(_clientId)}'
        '/roots/${Uri.encodeComponent(externalId)}',
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _clientLibraryRoots = _clientLibraryRoots
            .where((item) => item.externalId != externalId)
            .toList(growable: false);
        _offlineLibrary.retainRootFiles(externalId, const <String>{});
      });
      await _persistClientLibraryRoots();
      await _OfflineLibraryStore.save(_offlineLibrary);
      await _refreshAll();
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Unable to remove local folder: $error');
      }
    }
  }

  void _replaceClientLibraryRoot(_ClientLibraryRoot replacement) {
    _clientLibraryRoots = _clientLibraryRoots
        .map(
          (root) =>
              root.externalId == replacement.externalId ? replacement : root,
        )
        .toList(growable: false);
  }

  Future<void> _persistClientLibraryRoots() async {
    final preferences = _preferences ?? await SharedPreferences.getInstance();
    _preferences = preferences;
    await preferences.setString(
      _prefsClientLibraryRootsKey,
      jsonEncode(
        _clientLibraryRoots
            .map((root) => root.toJson())
            .toList(growable: false),
      ),
    );
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
    final normalizedTerms = query
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    bool matches(Map<String, dynamic> value, Iterable<String> keys) {
      final searchable = keys
          .map((key) => value[key]?.toString().toLowerCase() ?? '')
          .join(' ');
      return normalizedTerms.every(searchable.contains);
    }

    List<dynamic> filter(List<dynamic> values, Iterable<String> keys) => values
        .whereType<Map>()
        .map((value) => value.cast<String, dynamic>())
        .where((value) => matches(value, keys))
        .take(limit)
        .toList(growable: false);

    final memoryResult = <String, dynamic>{
      'query': query,
      'tracks': filter(_tracks, const [
        'title',
        'artist_display',
        'album_title',
      ]),
      'albums': filter(_albums, const [
        'title',
        'album_artist_display',
        'year',
      ]),
      'artists': filter(_artists, const ['name', 'sort_name']),
      'playlists': filter(_playlists, const ['name', 'description']),
    };
    return _ClientCacheStore.search(
      _coreUrlController.text,
      query,
      limit: limit,
    ).then((cached) {
      final cachedCount =
          const <String>['tracks', 'albums', 'artists', 'playlists'].fold<int>(
            0,
            (count, key) => count + ((cached[key] as List?)?.length ?? 0),
          );
      return cachedCount == 0 ? memoryResult : cached;
    });
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
    final result = await _loadSearch(query, limit: 120);
    if (!mounted) return;
    setState(() {
      _searchResultCache[query] = result;
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
        _ClientLog.event(
          'renderer.command.received',
          data: <String, Object?>{
            'action': command['action']?.toString(),
            'command_id': command['command_id']?.toString(),
            'track_id': _intValue(command['track_id']),
            'output_id': targetOutputId,
          },
        );
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
          unawaited(
            _persistOverviewValues(<String, dynamic>{'playback_queue': queue}),
          );
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
      if (eventType == 'distribution.created' ||
          eventType == 'distribution.updated') {
        unawaited(_refreshDistributionJobs());
        unawaited(_pollDistributionTasks());
      }
      if (eventType == 'library.changed' ||
          eventType == 'client.mutations_applied') {
        unawaited(_backgroundLibrarySync());
      }
      if (eventType == 'core.settings_changed') {
        unawaited(_refreshSettingsCache());
      }
    } catch (error, stackTrace) {
      _ClientLog.error('renderer.event.invalid', error, stackTrace: stackTrace);
      if (mounted) {
        setState(() => _rendererStatus = 'Renderer event error');
      }
    }
  }

  Future<void> _refreshSettingsCache() async {
    try {
      final values = await Future.wait<dynamic>([
        _api.getJson('/settings/server'),
        _api.getJson('/settings/favorites'),
        _api.getJson('/settings/metadata'),
      ]);
      if (mounted) {
        setState(() {
          _serverSettings = _asMap(values[0]);
          _favoriteSettings = _asMap(values[1]);
          _metadataSettings = _asMap(values[2]);
        });
      }
      await _persistOverviewValues(<String, dynamic>{
        'settings': <String, dynamic>{
          'server': values[0],
          'favorites': values[1],
          'metadata': values[2],
        },
      });
    } catch (error) {
      await _ClientCacheStore.recordError(_coreUrlController.text, error);
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
          final optimisticTrack = _optimisticLocalTrackByOutput[outputId];
          final optimisticStarted = _optimisticLocalStartedAtByOutput[outputId];
          final reuseOptimisticLocal =
              trackId != null &&
              optimisticTrack == trackId &&
              optimisticStarted != null &&
              DateTime.now().difference(optimisticStarted) <
                  const Duration(seconds: 30) &&
              _rendererLocalFileByOutput[outputId] == true;
          if (reuseOptimisticLocal) {
            _optimisticLocalTrackByOutput.remove(outputId);
            _optimisticLocalStartedAtByOutput.remove(outputId);
            _ClientLog.event(
              'renderer.command.reused_local_fast_start',
              data: <String, Object?>{
                'track_id': trackId,
                'output_id': outputId,
                'command_delay_ms': DateTime.now()
                    .difference(optimisticStarted)
                    .inMilliseconds,
              },
            );
            await _reportRendererState(
              'playing',
              outputId: outputId,
              command: command,
            );
            break;
          }
          final source = await _rendererSource(trackId, streamPath);
          final openWatch = Stopwatch()..start();
          _ClientLog.event(
            'renderer.player.open.start',
            data: <String, Object?>{
              'track_id': trackId,
              'output_id': outputId,
              'source': source.localFile ? 'local' : 'core_stream',
            },
          );
          await player.stop();
          if (trackId != null) {
            _rendererLoadedTrackByOutput[outputId] = trackId;
          }
          await player.open(source.uri, localFile: source.localFile);
          _rendererLocalFileByOutput[outputId] = source.localFile;
          _ClientLog.event(
            'renderer.player.open.end',
            data: <String, Object?>{
              'track_id': trackId,
              'output_id': outputId,
              'source': source.localFile ? 'local' : 'core_stream',
              'elapsed_ms': openWatch.elapsedMilliseconds,
            },
          );
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
          _rendererLocalFileByOutput.remove(outputId);
          _optimisticLocalTrackByOutput.remove(outputId);
          _optimisticLocalStartedAtByOutput.remove(outputId);
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
    } catch (error, stackTrace) {
      _rendererLoadedTrackByOutput.remove(outputId);
      _rendererLocalFileByOutput.remove(outputId);
      _ClientLog.error(
        'renderer.command.failed',
        error,
        stackTrace: stackTrace,
        data: <String, Object?>{
          'action': action,
          'track_id': _intValue(command['track_id']),
          'output_id': outputId,
        },
      );
      if (mounted) {
        setState(() => _error = 'Renderer playback failed: $error');
      }
      try {
        await _reportRendererState('stopped', outputId: outputId);
      } catch (reportError, reportStackTrace) {
        _ClientLog.error(
          'renderer.state_report.failed',
          reportError,
          stackTrace: reportStackTrace,
          data: <String, Object?>{'output_id': outputId},
        );
      }
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
    final source = await _rendererSource(trackId, streamPath);
    final openWatch = Stopwatch()..start();
    _rendererLoadedTrackByOutput[outputId] = trackId;
    await player.open(source.uri, localFile: source.localFile);
    _rendererLocalFileByOutput[outputId] = source.localFile;
    _ClientLog.event(
      'renderer.player.ensure_source',
      data: <String, Object?>{
        'track_id': trackId,
        'output_id': outputId,
        'source': source.localFile ? 'local' : 'core_stream',
        'elapsed_ms': openWatch.elapsedMilliseconds,
      },
    );
    _rendererLoadedTrackByOutput[outputId] = trackId;
    if (positionMs > 0) {
      await player.seek(Duration(milliseconds: positionMs));
    }
    return true;
  }

  Future<({String uri, bool localFile})> _rendererSource(
    int? trackId,
    String streamPath,
  ) async {
    if (trackId != null && _clientLibraryRoots.isNotEmpty) {
      final cachedCopy = await _availableOfflineCopy(trackId);
      final cachedPath = cachedCopy == null
          ? null
          : _offlineCopyPath(cachedCopy, _clientLibraryRoots);
      if (cachedPath != null && await File(cachedPath).exists()) {
        _ClientLog.event(
          'renderer.source.selected',
          data: <String, Object?>{
            'track_id': trackId,
            'source': 'offline_manifest',
            'local': true,
          },
        );
        return (uri: cachedPath, localFile: true);
      }
      try {
        final media = _asMap(await _api.getJson('/tracks/$trackId/media'));
        final localPath = _resolveClientReplicaPath(
          _clientLibraryRoots,
          media,
          _clientId,
        );
        if (localPath != null && await File(localPath).exists()) {
          _ClientLog.event(
            'renderer.source.selected',
            data: <String, Object?>{
              'track_id': trackId,
              'source': 'core_replica_catalog',
              'local': true,
            },
          );
          return (uri: localPath, localFile: true);
        }
      } catch (error, stackTrace) {
        _ClientLog.error(
          'renderer.source.catalog_lookup_failed',
          error,
          stackTrace: stackTrace,
          data: <String, Object?>{'track_id': trackId},
        );
        // A catalog lookup failure must not prevent the normal Core stream.
      }
    }
    _ClientLog.event(
      'renderer.source.selected',
      data: <String, Object?>{
        'track_id': trackId,
        'source': 'core_stream',
        'local': false,
      },
    );
    return (uri: _api.apiUrl(streamPath), localFile: false);
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
    if (_offlineMode) {
      final detail =
          _albumDetailCache[albumId] ??
          _albumDetailFromOverview(albumId) ??
          _offlineAlbumDetail(_offlineLibrary, albumId);
      if (detail != null && mounted) {
        setState(() {
          _albumDetailCache[albumId] = detail;
          _navigateToInState(_AppRoute.album(albumId));
        });
      }
      return;
    }
    final detail =
        _albumDetailCache[albumId] ?? _albumDetailFromOverview(albumId);
    if (detail == null || !mounted) return;
    setState(() {
      _albumDetailCache[albumId] = detail;
      _navigateToInState(_AppRoute.album(albumId));
    });
    unawaited(_refreshAlbumDetail(albumId));
  }

  Map<String, dynamic>? _albumDetailFromOverview(int albumId) {
    final album = _findEntity(_albums, albumId);
    if (album == null) return null;
    return <String, dynamic>{
      'album': album,
      'tracks': _tracks
          .whereType<Map>()
          .map((value) => value.cast<String, dynamic>())
          .where((track) => _intValue(track['album_id']) == albumId)
          .toList(growable: false),
    };
  }

  Future<void> _refreshAlbumDetail(int albumId) async {
    try {
      final detail = _asMap(await _api.getJson('/albums/$albumId'));
      _albumDetailCache[albumId] = detail;
      await _persistDetail('album', albumId, detail);
      if (mounted && _currentRoute == _AppRoute.album(albumId)) {
        setState(() {});
      }
    } catch (error) {
      await _ClientCacheStore.recordError(_coreUrlController.text, error);
    }
  }

  void _closeAlbumDetail() => _closeDetailPage();

  Future<void> _openArtistDetail(int artistId) async {
    if (_offlineMode) {
      final detail =
          _artistDetailCache[artistId] ??
          _artistDetailFromOverview(artistId) ??
          _offlineArtistDetail(_offlineLibrary, artistId);
      if (detail != null && mounted) {
        setState(() {
          _artistDetailCache[artistId] = detail;
          _navigateToInState(_AppRoute.artist(artistId));
        });
      }
      return;
    }
    final detail =
        _artistDetailCache[artistId] ?? _artistDetailFromOverview(artistId);
    if (detail == null || !mounted) return;
    setState(() {
      _artistDetailCache[artistId] = detail;
      _navigateToInState(_AppRoute.artist(artistId));
    });
    unawaited(_refreshArtistDetail(artistId));
  }

  Future<void> _openArtistByName(String displayName) async {
    final query = displayName.trim().toLowerCase();
    if (query.isEmpty) return;
    Map<String, dynamic>? match;
    for (final value in _artists.whereType<Map>()) {
      final artist = value.cast<String, dynamic>();
      final name = artist['name']?.toString().trim().toLowerCase() ?? '';
      if (name == query) {
        match = artist;
        break;
      }
    }
    if (match == null) {
      for (final value in _artists.whereType<Map>()) {
        final artist = value.cast<String, dynamic>();
        final name = artist['name']?.toString().trim().toLowerCase() ?? '';
        if (name.length >= 2 &&
            RegExp(
              '(^|[,;/&、，]\\s*)${RegExp.escape(name)}(\\s*[,;/&、，]|\$)',
            ).hasMatch(query)) {
          match = artist;
          break;
        }
      }
    }
    final artistId = _intValue(match?['id']);
    if (artistId != null) {
      await _openArtistDetail(artistId);
    }
  }

  Map<String, dynamic>? _artistDetailFromOverview(int artistId) {
    final artist = _findEntity(_artists, artistId);
    if (artist == null) return null;
    return <String, dynamic>{
      'artist': artist,
      'profile': <String, dynamic>{
        'display_name': artist['name'],
        'sort_name': artist['sort_name'],
        'aliases': const <String>[],
        'genres': const <String>[],
        'links': const <dynamic>[],
      },
      'assets': const <dynamic>[],
      'visuals': const <dynamic>[],
      'albums': const <dynamic>[],
      'tracks': const <dynamic>[],
    };
  }

  Future<void> _refreshArtistDetail(int artistId) async {
    try {
      final detail = _asMap(await _api.getJson('/artists/$artistId'));
      _artistDetailCache[artistId] = detail;
      await _persistDetail('artist', artistId, detail);
      if (mounted && _currentRoute == _AppRoute.artist(artistId)) {
        setState(() {});
      }
    } catch (error) {
      await _ClientCacheStore.recordError(_coreUrlController.text, error);
    }
  }

  void _closeArtistDetail() => _closeDetailPage();

  Future<void> _editArtist(int artistId, Map<String, dynamic> detail) async {
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _LocaleScope(
        language: _language,
        child: _ArtistEditorDialog(
          api: _api,
          artistId: artistId,
          detail: detail,
        ),
      ),
    );
    if (changed != true || !mounted) {
      return;
    }
    final refreshed = await _run<Map<String, dynamic>>(
      () async => _asMap(await _api.getJson('/artists/$artistId')),
    );
    if (!mounted || refreshed == null) {
      return;
    }
    setState(() {
      _artistDetailCache[artistId] = refreshed;
      final artist = _asMap(refreshed['artist']);
      _artists = _artists
          .map(
            (value) => value is Map && _intValue(value['id']) == artistId
                ? artist
                : value,
          )
          .toList(growable: false);
    });
    unawaited(_persistDetail('artist', artistId, refreshed));
    unawaited(_persistOverviewValues(<String, dynamic>{'artists': _artists}));
    unawaited(_backgroundLibrarySync());
  }

  Future<void> _openTrackDetail(int trackId) async {
    if (_offlineMode) {
      final copy = await _availableOfflineCopy(trackId);
      final path = copy == null
          ? null
          : _offlineCopyPath(copy, _clientLibraryRoots);
      final cached =
          _trackDetailCache[trackId] ?? _trackDetailFromOverview(trackId);
      if (cached != null && mounted) {
        final detail = copy == null || path == null
            ? cached
            : _detailWithLocalCopy(cached, copy, path);
        setState(() {
          _trackDetailCache[trackId] = detail;
          _navigateToInState(_AppRoute.track(trackId));
        });
      }
      return;
    }
    final detail =
        _trackDetailCache[trackId] ?? _trackDetailFromOverview(trackId);
    if (detail == null || !mounted) return;
    setState(() {
      _trackDetailCache[trackId] = detail;
      _navigateToInState(_AppRoute.track(trackId));
    });
    unawaited(_refreshTrackDetail(trackId));
  }

  Map<String, dynamic> _detailWithLocalCopy(
    Map<String, dynamic> detail,
    _OfflineTrackCopy copy,
    String path,
  ) {
    return <String, dynamic>{
      ...detail,
      'track': <String, dynamic>{
        ..._asMap(detail['track']),
        '_local_available': true,
      },
      '_client_local_copy': <String, dynamic>{
        'media_variant_id': copy.mediaVariantId,
        'device_id': _clientId,
        'device_name': _clientAlias(),
        'source_kind': 'client',
        'availability_state': 'ready',
        'is_primary': false,
        'relative_path': copy.relativePath,
        'root_external_id': copy.rootExternalId,
        'client_file_id': copy.fileExternalId,
        'file_path': path,
        'extension': copy.extension,
        'size_bytes': copy.sizeBytes,
        'modified_at': copy.modifiedAt.toUtc().toIso8601String(),
        'codec': copy.metadata['codec'],
        'bitrate': copy.metadata['bitrate'],
        'sample_rate': copy.metadata['sample_rate'],
        'bit_depth': copy.metadata['bit_depth'],
        'channels': copy.metadata['channels'],
        'duration_ms': copy.metadata['duration_ms'],
      },
    };
  }

  Map<String, dynamic>? _trackDetailFromOverview(int trackId) {
    final track = _findEntity(_tracks, trackId);
    if (track == null) return null;
    return <String, dynamic>{
      'track': track,
      'file_path': '',
      'relative_path': '',
      'extension': '',
      'size_bytes': _intValue(track['size_bytes']) ?? 0,
      'modified_at': track['added_at'],
      'scan_status': 'cached_summary',
      'genres': const <String>[],
      'composers': const <String>[],
      'lyricists': const <String>[],
      'lyrics': null,
      'media': null,
    };
  }

  Future<void> _refreshTrackDetail(int trackId) async {
    try {
      final detail = _asMap(await _api.getJson('/tracks/$trackId'));
      _trackDetailCache[trackId] = detail;
      await _persistDetail('track', trackId, detail);
      if (_activeTrackDetailId == trackId) _activeTrackDetail = detail;
      if (mounted &&
          (_currentRoute == _AppRoute.track(trackId) ||
              _activeTrackDetailId == trackId)) {
        setState(() {});
      }
    } catch (error) {
      await _ClientCacheStore.recordError(_coreUrlController.text, error);
    }
  }

  Future<void> _editTrack(int trackId) async {
    final snapshot = await _run<Map<String, dynamic>>(
      () async => _asMap(await _api.getJson('/tracks/$trackId/edit')),
    );
    if (!mounted || snapshot == null) {
      return;
    }
    final updated = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _LocaleScope(
        language: _language,
        child: _TrackEditorDialog(
          api: _api,
          trackId: trackId,
          snapshot: snapshot,
        ),
      ),
    );
    if (!mounted || updated == null) {
      return;
    }
    final detail = _asMap(updated['detail']);
    setState(() {
      _trackDetailCache[trackId] = detail;
      _searchResultCache.clear();
      final updatedTrack = _asMap(detail['track']);
      _replaceTrackInCollections(updatedTrack);
      if (_activeTrackDetailId == trackId) {
        _activeTrackDetail = detail;
      }
    });
    unawaited(_persistDetail('track', trackId, detail));
    unawaited(_persistOverviewValues(<String, dynamic>{'tracks': _tracks}));
    unawaited(_backgroundLibrarySync());
  }

  Future<void> _manageTrackVersions(int trackId) async {
    final detail = _trackDetailCache[trackId];
    if (detail == null) {
      return;
    }
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _LocaleScope(
        language: _language,
        child: _TrackVersionManagerDialog(
          api: _api,
          trackId: trackId,
          detail: detail,
        ),
      ),
    );
    if (changed != true || !mounted) {
      return;
    }
    final refreshed = await _run<Map<String, dynamic>>(
      () async => _asMap(await _api.getJson('/tracks/$trackId')),
    );
    if (!mounted || refreshed == null) {
      return;
    }
    setState(() {
      _trackDetailCache[trackId] = refreshed;
      if (_activeTrackDetailId == trackId) {
        _activeTrackDetail = refreshed;
      }
    });
    unawaited(_persistDetail('track', trackId, refreshed));
    unawaited(_backgroundLibrarySync());
  }

  void _closeTrackDetail() => _closeDetailPage();

  Future<void> _openPlaylistDetail(int playlistId) async {
    final detail =
        _playlistDetailCache[playlistId] ??
        _playlistDetailFromOverview(playlistId);
    if (detail == null || !mounted) return;
    setState(() {
      _playlistDetailCache[playlistId] = detail;
      _navigateToInState(_AppRoute.playlist(playlistId));
    });
    if (!_offlineMode) {
      unawaited(_refreshPlaylistDetail(playlistId));
    }
  }

  Map<String, dynamic>? _playlistDetailFromOverview(int playlistId) {
    final playlist = _findEntity(_playlists, playlistId);
    if (playlist == null) return null;
    return <String, dynamic>{
      'playlist': playlist,
      'rules': null,
      'tracks': const <dynamic>[],
    };
  }

  Future<void> _refreshPlaylistDetail(int playlistId) async {
    try {
      final detail = _asMap(await _api.getJson('/playlists/$playlistId'));
      _playlistDetailCache[playlistId] = detail;
      await _persistDetail('playlist', playlistId, detail);
      if (mounted && _currentRoute == _AppRoute.playlist(playlistId)) {
        setState(() {});
      }
    } catch (error) {
      await _ClientCacheStore.recordError(_coreUrlController.text, error);
    }
  }

  Map<String, dynamic>? _findEntity(List<dynamic> values, int id) {
    for (final value in values) {
      if (value is Map && _intValue(value['id']) == id) {
        return value.cast<String, dynamic>();
      }
    }
    return null;
  }

  Future<void> _persistDetail(
    String kind,
    int id,
    Map<String, dynamic> detail,
  ) {
    final serverId = _cacheServerId ?? _status?['server_id']?.toString();
    if (serverId == null || serverId.isEmpty) return Future<void>.value();
    return _ClientCacheStore.putDetail(
      _coreUrlController.text,
      serverId,
      kind,
      id,
      detail,
    );
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
      unawaited(_persistDetail('playlist', playlistId, updated));
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
    await _persistOverviewValues(<String, dynamic>{'playlists': playlists});
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
      final playlistId = _intValue(_asMap(detail['playlist'])['id']);
      if (playlistId != null) {
        _playlistDetailCache[playlistId] = detail;
        unawaited(_persistDetail('playlist', playlistId, detail));
      }
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
      unawaited(_persistDetail('playlist', playlistId, detail));
    }
  }

  Future<void> _toggleFavorite(Map<String, dynamic> track) async {
    final trackId = _intValue(track['id']);
    if (trackId == null) {
      return;
    }
    final favorite = track['is_favorite'] != true;
    final mutation = _OfflineMutation(
      id: _newClientMutationId(),
      kind: 'favorite',
      trackId: trackId,
      occurredAt: DateTime.now().toUtc(),
      payload: <String, dynamic>{'is_favorite': favorite},
    );
    _offlineLibrary.setFavorite(trackId, favorite);
    _offlineLibrary.outbox.add(mutation);
    final optimisticTrack = <String, dynamic>{
      ...track,
      'is_favorite': favorite,
      if (favorite && track['user_rating'] == null) 'user_rating': 100,
    };
    if (mounted) {
      setState(() {
        _replaceTrackInCollections(optimisticTrack);
        _replaceTrackInDetailCache(_albumDetailCache, optimisticTrack);
        _replaceTrackInDetailCache(_artistDetailCache, optimisticTrack);
        _replaceTrackInDetailCache(_playlistDetailCache, optimisticTrack);
        final detail = _trackDetailCache[trackId];
        if (detail != null) {
          _trackDetailCache[trackId] = <String, dynamic>{
            ...detail,
            'track': optimisticTrack,
          };
        }
        if (_activeTrackDetailId == trackId && _activeTrackDetail != null) {
          _activeTrackDetail = <String, dynamic>{
            ...?_activeTrackDetail,
            'track': optimisticTrack,
          };
        }
      });
    }
    await _OfflineLibraryStore.save(_offlineLibrary);
    await _persistOverviewValues(<String, dynamic>{'tracks': _tracks});
    if (_offlineMode) return;
    Map<String, dynamic> detail;
    try {
      detail = _asMap(
        await _api.postJson('/tracks/$trackId/favorite', <String, dynamic>{
          'is_favorite': favorite,
        }),
      );
      _offlineLibrary.outbox.removeWhere((value) => value.id == mutation.id);
      unawaited(_OfflineLibraryStore.save(_offlineLibrary));
    } catch (_) {
      if (mounted) {
        setState(() => _rendererStatus = 'Change queued for synchronization');
      }
      return;
    }
    if (!mounted) {
      return;
    }
    final updatedTrack = _asMap(detail['track']);
    _offlineLibrary.setFavorite(trackId, updatedTrack['is_favorite'] == true);
    unawaited(_OfflineLibraryStore.save(_offlineLibrary));
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
    unawaited(_persistDetail('track', trackId, detail));
    unawaited(_persistOverviewValues(<String, dynamic>{'tracks': _tracks}));
  }

  Future<void> _persistOverviewValues(Map<String, dynamic> values) {
    final serverId = _cacheServerId ?? _status?['server_id']?.toString();
    if (serverId == null || serverId.isEmpty) return Future<void>.value();
    return _ClientCacheStore.putOverviewValues(
      _coreUrlController.text,
      serverId,
      values,
    );
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

  Future<_OfflineTrackCopy?> _availableOfflineCopy(int trackId) async {
    final copies = _offlineLibrary.copies.values.where(
      (copy) => copy.trackId == trackId,
    );
    for (final copy in copies) {
      final path = _offlineCopyPath(copy, _clientLibraryRoots);
      if (path != null && await File(path).exists()) {
        return copy;
      }
    }
    return null;
  }

  bool _zoneUsesThisClient(String zoneId) {
    if (_isClientOutputId(zoneId) || zoneId.startsWith(_clientZonePrefix)) {
      return true;
    }
    final zone = _zoneById(zoneId);
    final outputId = zone?['output_id']?.toString();
    return _isClientOutputId(outputId) ||
        (outputId?.startsWith(_clientZonePrefix) ?? false);
  }

  String? _clientOutputForZone(String zoneId) {
    if (_isClientOutputId(zoneId)) return zoneId;
    final outputId = _zoneById(zoneId)?['output_id']?.toString();
    return _isClientOutputId(outputId) ? outputId : null;
  }

  bool _hasActiveLocalSource(String zoneId) {
    final outputId = _clientOutputForZone(zoneId);
    return outputId != null &&
        _rendererLocalFileByOutput[outputId] == true &&
        _rendererLoadedTrackByOutput[outputId] != null;
  }

  /// Starts an accessible local replica before waiting for Core.
  ///
  /// Core remains authoritative for the shared queue and history. The later
  /// renderer command is reconciled without reopening the already-playing
  /// source.
  Future<bool> _tryStartLocalPlayback(
    int trackId, {
    required String zoneId,
    List<int>? sourceTrackIds,
  }) async {
    if (!_zoneUsesThisClient(zoneId)) return false;
    final copy = await _availableOfflineCopy(trackId);
    if (copy == null) {
      _ClientLog.event(
        'playback.local_fast_start.unavailable',
        data: <String, Object?>{'track_id': trackId, 'zone_id': zoneId},
      );
      return false;
    }
    final path = _offlineCopyPath(copy, _clientLibraryRoots);
    if (path == null || !await File(path).exists()) {
      _ClientLog.event(
        'playback.local_fast_start.missing_file',
        level: 'warning',
        data: <String, Object?>{'track_id': trackId, 'zone_id': zoneId},
      );
      return false;
    }

    if (sourceTrackIds != null) {
      _setOfflineQueue(
        sourceTrackIds,
        startIndex: sourceTrackIds.indexOf(trackId),
      );
    } else {
      final items = _queueItems();
      final existingIndex = items.indexWhere(
        (item) => _intValue(_asMap(item['track'])['id']) == trackId,
      );
      if (existingIndex >= 0) {
        _playbackQueue = <String, dynamic>{
          ...?_playbackQueue,
          'current_index': existingIndex,
        };
      }
    }

    final outputId = _isClientOutputId(zoneId)
        ? zoneId
        : (_zoneById(zoneId)?['output_id']?.toString() ?? _clientOutputId);
    final player = await _playerForOutput(outputId);
    final watch = Stopwatch()..start();
    _ClientLog.event(
      'playback.local_fast_start.begin',
      data: <String, Object?>{
        'track_id': trackId,
        'zone_id': zoneId,
        'output_id': outputId,
      },
    );
    try {
      await player.stop();
      _rendererLoadedTrackByOutput[outputId] = trackId;
      await player.open(path, localFile: true);
    } catch (error, stackTrace) {
      if (_rendererLoadedTrackByOutput[outputId] == trackId) {
        _rendererLoadedTrackByOutput.remove(outputId);
      }
      _ClientLog.error(
        'playback.local_fast_start.failed',
        error,
        stackTrace: stackTrace,
        data: <String, Object?>{
          'track_id': trackId,
          'zone_id': zoneId,
          'elapsed_ms': watch.elapsedMilliseconds,
        },
      );
      return false;
    }
    _rendererLocalFileByOutput[outputId] = true;
    _optimisticLocalTrackByOutput[outputId] = trackId;
    _optimisticLocalStartedAtByOutput[outputId] = DateTime.now();

    final summary = _findEntity(_tracks, trackId) ?? copy.toTrackSummary();
    final cachedDetail =
        _trackDetailCache[trackId] ??
        _trackDetailFromOverview(trackId) ??
        copy.toTrackDetail(path);
    final localDetail = _detailWithLocalCopy(cachedDetail, copy, path);
    final playback = _withPlaybackTimestamp(<String, dynamic>{
      'zone_id': zoneId,
      'state': 'playing',
      'track_id': trackId,
      'track_title': summary['title'],
      'position_ms': 0,
      'queue_revision': _intValue(_playbackQueue?['revision']) ?? 0,
    });
    _rendererPlaybackByOutput[outputId] = playback;
    if (mounted) {
      setState(() {
        _activeTrackDetailId = trackId;
        _activeTrackDetail = localDetail;
        _trackDetailCache[trackId] = localDetail;
        _applyPlayback(playback);
        _rendererStatus = _tr(
          context,
          'Playing local copy · syncing with Core',
        );
        _error = null;
      });
    }
    _ClientLog.event(
      'playback.local_fast_start.ready',
      data: <String, Object?>{
        'track_id': trackId,
        'zone_id': zoneId,
        'output_id': outputId,
        'elapsed_ms': watch.elapsedMilliseconds,
      },
    );
    return true;
  }

  void _setOfflineQueue(List<int> trackIds, {int? startIndex}) {
    final summaries = <int, Map<String, dynamic>>{
      for (final value in _tracks.whereType<Map>())
        if (_intValue(value['id']) != null)
          _intValue(value['id'])!: value.cast<String, dynamic>(),
    };
    for (final value in _offlineTrackSummaries(
      _offlineLibrary,
    ).whereType<Map>()) {
      final trackId = _intValue(value['id']);
      if (trackId != null) {
        summaries.putIfAbsent(trackId, () => value.cast<String, dynamic>());
      }
    }
    final validIds = trackIds
        .where((trackId) => summaries.containsKey(trackId))
        .toList(growable: false);
    _playbackQueue = <String, dynamic>{
      'zone_id': _clientOutputId,
      'revision': (_intValue(_playbackQueue?['revision']) ?? 0) + 1,
      'mode': _playbackMode.nameForApi,
      'current_index':
          startIndex == null || startIndex < 0 || startIndex >= validIds.length
          ? null
          : startIndex,
      'items': <dynamic>[
        for (var index = 0; index < validIds.length; index += 1)
          <String, dynamic>{
            'id': -(index + 1),
            'position': index,
            'track': summaries[validIds[index]],
          },
      ],
    };
  }

  Future<void> _playOfflineTrack(
    int trackId, {
    List<int>? sourceTrackIds,
  }) async {
    var copy = await _availableOfflineCopy(trackId);
    if (copy == null) {
      if (mounted) {
        setState(
          () => _error = _tr(
            context,
            'No accessible local copy is available for this track.',
          ),
        );
      }
      return;
    }
    if (sourceTrackIds != null) {
      _setOfflineQueue(
        sourceTrackIds,
        startIndex: sourceTrackIds.indexOf(trackId),
      );
    } else {
      final items = _queueItems();
      final existingIndex = items.indexWhere(
        (item) => _intValue(_asMap(item['track'])['id']) == trackId,
      );
      if (existingIndex < 0) {
        _setOfflineQueue(<int>[trackId], startIndex: 0);
      } else {
        _playbackQueue = <String, dynamic>{
          ...?_playbackQueue,
          'current_index': existingIndex,
        };
      }
    }
    await _finishOfflinePlayback('replaced');
    final path = _offlineCopyPath(copy, _clientLibraryRoots);
    if (path == null) return;
    final player = await _playerForOutput(_clientOutputId);
    await player.stop();
    await player.open(path, localFile: true);
    final measuredDuration = await player.durationMs();
    if ((_intValue(copy.metadata['duration_ms']) ?? 0) <= 0 &&
        measuredDuration != null &&
        measuredDuration > 0) {
      copy = copy.copyWith(durationMs: measuredDuration);
      _offlineLibrary.upsert(copy);
      unawaited(_OfflineLibraryStore.save(_offlineLibrary));
    }
    _offlinePlaybackStartedAt = DateTime.now().toUtc();
    _offlinePlaybackStartPositionMs = 0;
    final summary = _findEntity(_tracks, trackId) ?? copy.toTrackSummary();
    final cachedDetail =
        _trackDetailCache[trackId] ??
        _trackDetailFromOverview(trackId) ??
        copy.toTrackDetail(path);
    final detail = _detailWithLocalCopy(cachedDetail, copy, path);
    final playback = <String, dynamic>{
      'zone_id': _clientOutputId,
      'state': 'playing',
      'track_id': trackId,
      'track_title': summary['title'],
      'position_ms': 0,
      'queue_revision': _intValue(_playbackQueue?['revision']) ?? 0,
    };
    if (!mounted) return;
    setState(() {
      _replaceTrackInCollections(<String, dynamic>{
        ...summary,
        '_offline': true,
        '_local_available': true,
      });
      _activeTrackDetailId = trackId;
      _activeTrackDetail = detail;
      _trackDetailCache[trackId] = detail;
      _applyPlayback(playback);
      _error = null;
    });
  }

  Future<void> _finishOfflinePlayback(String reason) async {
    if (!_offlineMode || _offlinePlaybackStartedAt == null) return;
    final trackId = _intValue(_playback?['track_id']);
    if (trackId == null) return;
    final player = await _playerForOutput(_clientOutputId);
    final endPosition =
        await player.currentPositionMs() ??
        _estimatedPlaybackPositionMs(_playback);
    final mutation = _OfflineMutation(
      id: _newClientMutationId(),
      kind: 'playback',
      trackId: trackId,
      occurredAt: DateTime.now().toUtc(),
      payload: <String, dynamic>{
        'started_at': _offlinePlaybackStartedAt!.toIso8601String(),
        'ended_at': DateTime.now().toUtc().toIso8601String(),
        'start_position_ms': _offlinePlaybackStartPositionMs,
        'end_position_ms': endPosition,
        'reason': reason,
      },
    );
    _offlineLibrary.outbox.add(mutation);
    _offlineLibrary.incrementPlayCount(trackId);
    _offlinePlaybackStartedAt = null;
    await _OfflineLibraryStore.save(_offlineLibrary);
  }

  Future<void> _playNextOfflineTrack({bool completed = false}) async {
    final items = _queueItems();
    if (items.isEmpty) {
      await _setOfflineStopped();
      return;
    }
    var currentIndex = _intValue(_playbackQueue?['current_index']) ?? -1;
    if (_playbackMode == _PlaybackMode.repeatOne && completed) {
      // Keep the current index.
    } else if (_playbackMode == _PlaybackMode.shuffle && items.length > 1) {
      var next = currentIndex;
      while (next == currentIndex) {
        next = Random.secure().nextInt(items.length);
      }
      currentIndex = next;
    } else {
      currentIndex += 1;
      if (currentIndex >= items.length) {
        if (_playbackMode == _PlaybackMode.repeatAll) {
          currentIndex = 0;
        } else {
          await _setOfflineStopped();
          return;
        }
      }
    }
    final trackId = _intValue(_asMap(items[currentIndex]['track'])['id']);
    if (trackId == null) {
      await _setOfflineStopped();
      return;
    }
    _playbackQueue = <String, dynamic>{
      ...?_playbackQueue,
      'current_index': currentIndex,
    };
    await _playOfflineTrack(trackId);
  }

  Future<void> _playPreviousOfflineTrack() async {
    final items = _queueItems();
    if (items.isEmpty) return;
    var currentIndex = _intValue(_playbackQueue?['current_index']) ?? 0;
    currentIndex -= 1;
    if (currentIndex < 0) {
      currentIndex = _playbackMode == _PlaybackMode.repeatAll
          ? items.length - 1
          : 0;
    }
    final trackId = _intValue(_asMap(items[currentIndex]['track'])['id']);
    if (trackId == null) return;
    _playbackQueue = <String, dynamic>{
      ...?_playbackQueue,
      'current_index': currentIndex,
    };
    await _playOfflineTrack(trackId);
  }

  Future<void> _setOfflineStopped() async {
    final player = await _playerForOutput(_clientOutputId);
    await player.stop();
    if (!mounted) return;
    setState(() {
      _applyPlayback(<String, dynamic>{
        'zone_id': _clientOutputId,
        'state': 'stopped',
        'track_id': null,
        'track_title': null,
        'position_ms': 0,
        'queue_revision': _intValue(_playbackQueue?['revision']) ?? 0,
      });
    });
  }

  Future<void> _playTrack(int trackId) async {
    _ClientLog.event(
      'playback.user.play_track',
      data: <String, Object?>{
        'track_id': trackId,
        'zone_id': _activeZoneId(),
        'offline': _offlineMode,
      },
    );
    if (_offlineMode) {
      final trackIds = _tracks
          .map((track) => _intValue((track as Map)['id']))
          .whereType<int>()
          .toList(growable: false);
      await _playOfflineTrack(trackId, sourceTrackIds: trackIds);
      return;
    }
    final queueItems = (_playbackQueue?['items'] as List?) ?? const [];
    final queued = queueItems.any((item) {
      final queueItem = (item as Map).cast<String, dynamic>();
      final track = (queueItem['track'] as Map?)?.cast<String, dynamic>();
      return _intValue(track?['id']) == trackId;
    });
    if (!queued) {
      await _playTrackFromCollection(trackId, _tracks);
      return;
    }
    final playback = await _playTrackOnZone(trackId, _selectedZoneId);
    if (mounted && playback != null) {
      setState(() {
        _applyPlayback(playback);
      });
    }
  }

  Future<void> _playTrackFromCollection(
    int trackId,
    List<dynamic> sourceTracks,
  ) async {
    final trackIds = sourceTracks
        .map((track) => _intValue((track as Map)['id']))
        .whereType<int>()
        .toList(growable: false);
    final startIndex = trackIds.indexOf(trackId);
    if (_offlineMode) {
      await _playOfflineTrack(trackId, sourceTrackIds: trackIds);
      return;
    }
    if (startIndex < 0) {
      await _playTrack(trackId);
      return;
    }
    final zoneId = _activeZoneId();
    final requestWatch = Stopwatch()..start();
    _ClientLog.event(
      'playback.user.play_collection',
      data: <String, Object?>{
        'track_id': trackId,
        'zone_id': zoneId,
        'collection_size': trackIds.length,
        'start_index': startIndex,
      },
    );
    final optimisticTrack = _findEntity(_tracks, trackId);
    if (mounted) {
      setState(() {
        _applyPlayback(<String, dynamic>{
          'zone_id': zoneId,
          'state': 'loading',
          'track_id': trackId,
          'track_title': optimisticTrack?['title'],
          'position_ms': 0,
          'queue_revision': _intValue(_playbackQueue?['revision']) ?? 0,
        });
      });
    }
    final localStarted = await _tryStartLocalPlayback(
      trackId,
      zoneId: zoneId,
      sourceTrackIds: trackIds,
    );
    try {
      final result = _asMap(
        await _api.postJson(
          '/zones/${Uri.encodeComponent(zoneId)}/play-collection',
          <String, dynamic>{
            'track_ids': trackIds,
            'start_index': startIndex,
            'mode': _PlaybackMode.sequential.nameForApi,
          },
          requestTimeout: const Duration(seconds: 8),
        ),
      );
      final queue = _asMap(result['queue']);
      final playback = _asMap(result['playback']);
      if (mounted) {
        setState(() {
          if (queue.isNotEmpty) _applyPlaybackQueue(queue);
          if (playback.isNotEmpty) _applyPlayback(playback);
        });
      }
      _ClientLog.event(
        'playback.core.play_collection.applied',
        data: <String, Object?>{
          'track_id': trackId,
          'zone_id': zoneId,
          'elapsed_ms': requestWatch.elapsedMilliseconds,
          'local_fast_start': localStarted,
          'core_timing_ms': _asMap(result['timing_ms']),
        },
      );
    } on HttpException catch (error) {
      final unsupported =
          error.message.contains('HTTP 404') ||
          error.message.contains('HTTP 405');
      if (!unsupported) {
        _ClientLog.error(
          'playback.core.play_collection.failed',
          error,
          data: <String, Object?>{
            'track_id': trackId,
            'zone_id': zoneId,
            'elapsed_ms': requestWatch.elapsedMilliseconds,
            'local_fast_start': localStarted,
          },
        );
        if (mounted && localStarted) {
          setState(
            () => _rendererStatus = _tr(
              context,
              'Weak connection · local playback continues',
            ),
          );
        } else if (mounted) {
          setState(() => _error = error.toString());
        }
        return;
      }
      final queue = await _replaceQueue(
        trackIds,
        startIndex: startIndex,
        mode: _PlaybackMode.sequential,
      );
      if (queue == null) return;
      final playback = await _playTrackOnZone(
        trackId,
        zoneId,
        tryLocalFastStart: false,
      );
      if (mounted && playback != null) {
        setState(() => _applyPlayback(playback));
      }
    } catch (error, stackTrace) {
      _ClientLog.error(
        'playback.core.play_collection.failed',
        error,
        stackTrace: stackTrace,
        data: <String, Object?>{
          'track_id': trackId,
          'zone_id': zoneId,
          'elapsed_ms': requestWatch.elapsedMilliseconds,
          'local_fast_start': localStarted,
        },
      );
      if (mounted && localStarted) {
        setState(
          () => _rendererStatus = _tr(
            context,
            'Weak connection · local playback continues',
          ),
        );
      } else if (mounted) {
        setState(() => _error = error.toString());
      }
    }
  }

  Future<Map<String, dynamic>?> _playTrackOnZone(
    int trackId,
    String zoneId, {
    bool tryLocalFastStart = true,
  }) async {
    if (_offlineMode) {
      await _playOfflineTrack(trackId);
      return _playback;
    }
    final watch = Stopwatch()..start();
    final localStarted =
        tryLocalFastStart &&
        await _tryStartLocalPlayback(trackId, zoneId: zoneId);
    try {
      final playback = _asMap(
        await _api.postJson(
          '/zones/${Uri.encodeComponent(zoneId)}/play',
          <String, dynamic>{'track_id': trackId},
          requestTimeout: const Duration(seconds: 8),
        ),
      );
      _ClientLog.event(
        'playback.core.play_track.applied',
        data: <String, Object?>{
          'track_id': trackId,
          'zone_id': zoneId,
          'elapsed_ms': watch.elapsedMilliseconds,
          'local_fast_start': localStarted,
        },
      );
      return playback;
    } catch (error, stackTrace) {
      _ClientLog.error(
        'playback.core.play_track.failed',
        error,
        stackTrace: stackTrace,
        data: <String, Object?>{
          'track_id': trackId,
          'zone_id': zoneId,
          'elapsed_ms': watch.elapsedMilliseconds,
          'local_fast_start': localStarted,
        },
      );
      if (mounted && localStarted) {
        setState(
          () => _rendererStatus = _tr(
            context,
            'Weak connection · local playback continues',
          ),
        );
      } else if (mounted) {
        setState(() => _error = error.toString());
      }
      return null;
    }
  }

  Future<void> _playPreviousTrack() async {
    if (_offlineMode) {
      await _finishOfflinePlayback('previous');
      await _playPreviousOfflineTrack();
      return;
    }
    await _tryStartAdjacentLocalPlayback(next: false);
    final playback = await _postPlaybackControl(
      '/zones/${Uri.encodeComponent(_activeZoneId())}/previous',
      const <String, dynamic>{},
    );
    if (mounted && playback != null) {
      setState(() => _applyPlayback(playback));
    }
  }

  Future<void> _playNextTrack() async {
    if (_offlineMode) {
      await _finishOfflinePlayback('next');
      await _playNextOfflineTrack();
      return;
    }
    await _tryStartAdjacentLocalPlayback(next: true);
    final playback = await _postPlaybackControl(
      '/zones/${Uri.encodeComponent(_activeZoneId())}/next',
      const <String, dynamic>{},
    );
    if (mounted && playback != null) {
      setState(() => _applyPlayback(playback));
    }
  }

  Future<bool> _tryStartAdjacentLocalPlayback({required bool next}) async {
    if (_playbackMode == _PlaybackMode.shuffle ||
        _playbackMode == _PlaybackMode.repeatOne ||
        !_zoneUsesThisClient(_activeZoneId())) {
      return false;
    }
    final items = _queueItems();
    if (items.isEmpty) return false;
    var index = _intValue(_playbackQueue?['current_index']);
    if (index == null || index < 0 || index >= items.length) {
      final currentTrackId = _intValue(_playback?['track_id']);
      index = items.indexWhere(
        (item) => _intValue(_asMap(item['track'])['id']) == currentTrackId,
      );
    }
    if (index < 0) return false;
    index += next ? 1 : -1;
    if (index < 0 || index >= items.length) {
      if (_playbackMode != _PlaybackMode.repeatAll) return false;
      index = next ? 0 : items.length - 1;
    }
    final trackId = _intValue(_asMap(items[index]['track'])['id']);
    if (trackId == null) return false;
    return _tryStartLocalPlayback(trackId, zoneId: _activeZoneId());
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
      unawaited(
        _persistOverviewValues(<String, dynamic>{'playback_queue': queue}),
      );
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
    if (_offlineMode) {
      final ids = _queueItems()
          .map((item) => _intValue(_asMap(item['track'])['id']))
          .whereType<int>()
          .toList();
      final currentIndex = _intValue(_playbackQueue?['current_index']);
      final insertAt = playNext
          ? min((currentIndex ?? -1) + 1, ids.length)
          : ids.length;
      ids.insertAll(insertAt, trackIds);
      if (mounted) {
        setState(() => _setOfflineQueue(ids, startIndex: currentIndex));
      }
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
    if (_offlineMode) {
      if (mode != null) _playbackMode = mode;
      if (mounted) {
        setState(() => _setOfflineQueue(trackIds, startIndex: startIndex));
      } else {
        _setOfflineQueue(trackIds, startIndex: startIndex);
      }
      return _playbackQueue;
    }
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
    if (_offlineMode) {
      final offlineIds = List<int>.of(trackIds);
      if (shuffle) offlineIds.shuffle(Random.secure());
      _playbackMode = shuffle
          ? _PlaybackMode.shuffle
          : _PlaybackMode.sequential;
      await _playOfflineTrack(offlineIds.first, sourceTrackIds: offlineIds);
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
    if (_offlineMode) {
      final ids = _queueItems()
          .map((item) => _intValue(_asMap(item['track'])['id']))
          .whereType<int>()
          .toList();
      if (from < 0 || from >= ids.length || to < 0 || to >= ids.length) {
        return _playbackQueue;
      }
      final currentTrackId = _intValue(_playback?['track_id']);
      final moved = ids.removeAt(from);
      ids.insert(to, moved);
      final currentIndex = ids.indexOf(currentTrackId ?? -1);
      if (mounted) {
        setState(() => _setOfflineQueue(ids, startIndex: currentIndex));
      }
      return _playbackQueue;
    }
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
    if (_offlineMode) {
      final items = _queueItems();
      final ids = items
          .where((item) => _intValue(item['id']) != itemId)
          .map((item) => _intValue(_asMap(item['track'])['id']))
          .whereType<int>()
          .toList(growable: false);
      final currentTrackId = _intValue(_playback?['track_id']);
      final currentIndex = ids.indexOf(currentTrackId ?? -1);
      if (mounted) {
        setState(() => _setOfflineQueue(ids, startIndex: currentIndex));
      }
      return _playbackQueue;
    }
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
    if (_offlineMode) {
      if (mounted) {
        setState(() {
          _playbackMode = mode;
          _playbackQueue = <String, dynamic>{
            ...?_playbackQueue,
            'mode': mode.nameForApi,
          };
        });
      }
      return;
    }
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
          currentClientZonePrefix: _clientZonePrefix,
          pinCurrentClientRegion: _pinCurrentClientRegion,
          regionSort: _zoneRegionSort,
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
    if (_offlineMode) {
      final player = await _playerForOutput(_clientOutputId);
      final position =
          await player.currentPositionMs() ??
          _estimatedPlaybackPositionMs(_playback);
      await player.pause();
      if (mounted) {
        setState(() {
          _applyPlayback(<String, dynamic>{
            ...?_playback,
            'state': 'paused',
            'position_ms': position,
          });
        });
      }
      return;
    }
    await _pauseZone(_activeZoneId());
  }

  Future<void> _resumePlayback() async {
    if (_offlineMode) {
      final trackId = _intValue(_playback?['track_id']);
      if (trackId == null) {
        final items = _queueItems();
        if (items.isNotEmpty) {
          final index = _intValue(_playbackQueue?['current_index']) ?? 0;
          final nextTrackId = _intValue(
            _asMap(items[index.clamp(0, items.length - 1)]['track'])['id'],
          );
          if (nextTrackId != null) await _playOfflineTrack(nextTrackId);
        }
        return;
      }
      final player = await _playerForOutput(_clientOutputId);
      await player.play();
      if (mounted) {
        setState(() {
          _applyPlayback(<String, dynamic>{
            ...?_playback,
            'state': 'playing',
            'position_ms': _estimatedPlaybackPositionMs(_playback),
          });
        });
      }
      return;
    }
    await _resumeZone(_activeZoneId());
  }

  Future<void> _pauseZone(String zoneId) async {
    await _postZoneAction(zoneId, 'pause');
  }

  Future<void> _resumeZone(String zoneId) async {
    await _postZoneAction(zoneId, 'play');
  }

  Future<void> _stopZone(String zoneId) async {
    if (_offlineMode) {
      await _finishOfflinePlayback('stopped');
      await _setOfflineStopped();
      return;
    }
    await _postZoneAction(zoneId, 'stop');
  }

  Future<void> _postZoneAction(String zoneId, String action) async {
    final outputId = _clientOutputForZone(zoneId);
    if (outputId != null && _hasActiveLocalSource(zoneId)) {
      final player = await _playerForOutput(outputId);
      final position =
          await player.currentPositionMs() ??
          _estimatedPlaybackPositionMs(_playback);
      switch (action) {
        case 'pause':
          await player.pause();
        case 'play':
          await player.play();
        case 'stop':
          await player.stop();
          _rendererLoadedTrackByOutput.remove(outputId);
          _rendererLocalFileByOutput.remove(outputId);
          _optimisticLocalTrackByOutput.remove(outputId);
          _optimisticLocalStartedAtByOutput.remove(outputId);
      }
      if (mounted) {
        setState(() {
          _applyPlayback(<String, dynamic>{
            ...?_playback,
            'state': action == 'play'
                ? 'playing'
                : action == 'pause'
                ? 'paused'
                : 'stopped',
            if (action == 'stop') 'track_id': null,
            if (action == 'stop') 'track_title': null,
            'position_ms': action == 'stop' ? 0 : position,
          });
        });
      }
      _ClientLog.event(
        'playback.local_control.applied',
        data: <String, Object?>{
          'action': action,
          'zone_id': zoneId,
          'position_ms': position,
        },
      );
    }
    final playback = await _postPlaybackControl(
      '/zones/${Uri.encodeComponent(zoneId)}/$action',
      const <String, dynamic>{},
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
    if (_offlineMode) {
      final player = await _playerForOutput(_clientOutputId);
      await player.seek(Duration(milliseconds: positionMs));
      if (mounted) {
        setState(() {
          _applyPlayback(<String, dynamic>{
            ...?_playback,
            'position_ms': positionMs,
          });
        });
      }
      return;
    }
    final zoneId = _activeZoneId();
    final outputId = _clientOutputForZone(zoneId);
    if (outputId != null && _hasActiveLocalSource(zoneId)) {
      await (await _playerForOutput(
        outputId,
      )).seek(Duration(milliseconds: positionMs));
      if (mounted) {
        setState(() {
          _applyPlayback(<String, dynamic>{
            ...?_playback,
            'position_ms': positionMs,
          });
        });
      }
    }
    final playback = await _postPlaybackControl(
      '/zones/${Uri.encodeComponent(zoneId)}/seek',
      <String, dynamic>{'position_ms': positionMs},
    );
    if (mounted && playback != null) {
      setState(() {
        _applyPlayback(playback);
      });
    }
  }

  Future<Map<String, dynamic>?> _postPlaybackControl(
    String path,
    Map<String, dynamic> body,
  ) async {
    final watch = Stopwatch()..start();
    _ClientLog.event(
      'playback.control.start',
      data: <String, Object?>{'path': path},
    );
    try {
      final result = _asMap(
        await _api.postJson(
          path,
          body,
          requestTimeout: const Duration(seconds: 8),
        ),
      );
      _ClientLog.event(
        'playback.control.end',
        data: <String, Object?>{
          'path': path,
          'elapsed_ms': watch.elapsedMilliseconds,
        },
      );
      return result;
    } catch (error, stackTrace) {
      _ClientLog.error(
        'playback.control.failed',
        error,
        stackTrace: stackTrace,
        data: <String, Object?>{
          'path': path,
          'elapsed_ms': watch.elapsedMilliseconds,
        },
      );
      if (mounted) setState(() => _rendererStatus = 'Playback link is slow');
      return null;
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
    if (_offlineMode) {
      final player = await _playerForOutput(_clientOutputId);
      await player.setVolume(effectiveMuted ? 0 : normalized);
      if (mounted) {
        setState(() {
          _zones = _zones
              .map((value) {
                final zone = _asMap(value);
                return <String, dynamic>{
                  ...zone,
                  'volume': normalized,
                  'muted': effectiveMuted,
                };
              })
              .toList(growable: false);
        });
      }
      return;
    }
    final localOutputId = _clientOutputForZone(zoneId);
    if (localOutputId != null && _hasActiveLocalSource(zoneId)) {
      await (await _playerForOutput(
        localOutputId,
      )).setVolume(effectiveMuted ? 0 : normalized);
      if (mounted) {
        setState(() {
          _zones = _zones
              .map((value) {
                final zone = _asMap(value);
                if (zone['id']?.toString() != zoneId) return zone;
                return <String, dynamic>{
                  ...zone,
                  'volume': normalized,
                  'muted': effectiveMuted,
                };
              })
              .toList(growable: false);
        });
      }
    }
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
    if (_offlineMode) {
      final copy = await _availableOfflineCopy(trackId);
      final path = copy == null
          ? null
          : _offlineCopyPath(copy, _clientLibraryRoots);
      if (!mounted ||
          copy == null ||
          path == null ||
          _activeTrackDetailId != trackId) {
        return;
      }
      final detail = copy.toTrackDetail(path);
      setState(() {
        _activeTrackDetail = detail;
        _trackDetailCache[trackId] = detail;
      });
      _syncSystemPlayback();
      return;
    }
    final cached =
        _trackDetailCache[trackId] ?? _trackDetailFromOverview(trackId);
    if (cached != null && _activeTrackDetailId == trackId) {
      _activeTrackDetail = cached;
      if (mounted) setState(() {});
      _syncSystemPlayback();
    }
    try {
      final detail = _asMap(await _api.getJson('/tracks/$trackId'));
      if (!mounted || _activeTrackDetailId != trackId) {
        return;
      }
      setState(() {
        _activeTrackDetail = detail;
        _trackDetailCache[trackId] = detail;
      });
      unawaited(_persistDetail('track', trackId, detail));
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
        onDistributeCollection: _distributeTracks,
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
      volume: _activeZoneVolume(),
      muted: _activeZoneMuted(),
      onResume: _resumeZone,
      onPause: _pauseZone,
      onPrevious: _playPreviousTrack,
      onNext: _playNextTrack,
      onSeek: _seekPlayback,
      onCycleMode: _cyclePlaybackMode,
      onShowModeMenu: _showPlaybackModeMenu,
      onShowQueue: _showQueueSheet,
      onShowDevices: _showDeviceSheet,
      onVolumeChanged: (value) => unawaited(_setActiveZoneVolume(value)),
      onToggleMute: () => unawaited(
        _setActiveZoneVolume(_activeZoneVolume(), muted: !_activeZoneMuted()),
      ),
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
          coreBaseUrl: _coreUrlController.text,
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
          onDistributeTracks: _distributeTracks,
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
          clientLibraryRoots: _clientLibraryRoots,
          clientLibraryStatuses: _clientLibraryStatuses,
          clientLibrarySyncingRootIds: _clientLibrarySyncingRootIds,
          distributionJobs: _distributionJobs,
          transcodingStatus: _transcodingStatus,
          clientId: _clientId,
          diagnostics: _diagnostics,
          diagnosticLoggingEnabled: _diagnosticLoggingEnabled,
          diagnosticLogPath: _diagnosticLogPath,
          language: _language,
          pinCurrentClientRegion: _pinCurrentClientRegion,
          zoneRegionSort: _zoneRegionSort,
          libraryRootController: _libraryRootController,
          onConnect: _refreshAll,
          onDiscover: _discoverAndRefresh,
          onScan: _startScan,
          onAddLibraryRoot: () => unawaited(_addLibraryRoot()),
          onRemoveLibraryRoot: (id) => unawaited(_removeLibraryRoot(id)),
          onAddClientLibraryRoot: () => unawaited(_addClientLibraryRoot()),
          onSyncClientLibraryRoot: (id) =>
              unawaited(_syncClientLibraryRoot(id)),
          onSyncAllClientLibraryRoots: () =>
              unawaited(_syncAllClientLibraryRoots()),
          onRemoveClientLibraryRoot: (id) =>
              unawaited(_removeClientLibraryRoot(id)),
          onRefreshDistributions: () => unawaited(_refreshDistributionJobs()),
          onCancelDistribution: (id) => unawaited(_cancelDistributionJob(id)),
          onSaveServerAlias: () => unawaited(_saveServerAlias()),
          onSaveClientAlias: () => unawaited(_saveClientAlias()),
          onLanguageChanged: (language) => unawaited(_setLanguage(language)),
          onPinCurrentClientRegionChanged: (value) =>
              unawaited(_setPinCurrentClientRegion(value)),
          onZoneRegionSortChanged: (value) =>
              unawaited(_setZoneRegionSort(value)),
          onDiagnosticLoggingChanged: (value) =>
              unawaited(_setDiagnosticLogging(value)),
          onExportDiagnosticLog: () => unawaited(_exportDiagnosticLog()),
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
        final trackId = _currentRoute.entityId;
        return _TrackInfoPage(
          coreBaseUrl: _coreUrlController.text,
          detail: _trackDetailCache[trackId],
          onClose: _closeTrackDetail,
          onPlayTrack: _playTrack,
          onOpenAlbum: _openAlbumDetail,
          onOpenArtist: _openArtistByName,
          onToggleFavorite: _toggleFavorite,
          onAddToPlaylist: _addTrackToPlaylist,
          onEdit: trackId == null ? () async {} : () => _editTrack(trackId),
          onManageVersions: trackId == null
              ? () async {}
              : () => _manageTrackVersions(trackId),
        );
      case _AppRouteKind.album:
        final detail =
            _albumDetailCache[_currentRoute.entityId] ??
            const <String, dynamic>{};
        return _AlbumInfoPage(
          coreBaseUrl: _coreUrlController.text,
          detail: detail,
          onClose: _closeAlbumDetail,
          onPlayTrack: (trackId) => _playTrackFromCollection(
            trackId,
            (detail['tracks'] as List?) ?? const [],
          ),
          onOpenTrack: _openTrackDetail,
          onToggleFavorite: _toggleFavorite,
          onAddToPlaylist: _addTrackToPlaylist,
        );
      case _AppRouteKind.artist:
        final artistId = _currentRoute.entityId;
        final detail =
            _artistDetailCache[artistId] ?? const <String, dynamic>{};
        return _ArtistInfoPage(
          coreBaseUrl: _coreUrlController.text,
          detail: detail,
          onClose: _closeArtistDetail,
          onEdit: artistId == null
              ? () async {}
              : () => _editArtist(artistId, detail),
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
          onPlayTrack: (trackId) => _playTrackFromCollection(
            trackId,
            (detail['tracks'] as List?) ?? const [],
          ),
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
