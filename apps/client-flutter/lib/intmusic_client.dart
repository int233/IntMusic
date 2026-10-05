import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:audioplayers/audioplayers.dart' as ap;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as mobile_sqlite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'core/navigation_history.dart';
import 'core/connection_watchdog.dart';
import 'core/artwork_cache_coordinator.dart';
import 'core/json_values.dart';
import 'core/library_sync.dart';
import 'core/release_media.dart';
import 'core/song_display.dart';
import 'core/collections.dart';
import 'core/serial_task_queue.dart';
import 'core/logging/client_log.dart';
import 'core/network/core_api_client.dart';
import 'core/playback_agent.dart';
import 'core/playback/renderer_session.dart';
import 'core/renderer_audio_output_policy.dart';
import 'core/renderer_command_sequences.dart';
import 'core/storage/client_cache_database.dart';
import 'core/task_scheduler.dart';
import 'src/app_theme.dart';

export 'core/network/core_api_client.dart' show CoreApiClient;

part 'src/app_shared.dart';
part 'src/app_models.dart';
part 'src/app_helpers.dart';
part 'src/responsive_ui_test_harness.dart';
part 'src/app_shell.dart';
part 'src/app_top_bar.dart';
part 'src/app_sidebar.dart';
part 'src/home_page.dart';
part 'src/collection_pages.dart';
part 'src/collection_editor.dart';
part 'src/collection_rule_editor.dart';
part 'src/home_layout_editor.dart';
part 'src/library_pages.dart';
part 'src/track_library_page.dart';
part 'src/playback_page.dart';
part 'src/playback_controls.dart';
part 'src/playback_lyrics.dart';
part 'src/playback_devices.dart';
part 'src/playback_queue_sheet.dart';
part 'src/history_page.dart';
part 'src/library_management_page.dart';
part 'src/library_management_files.dart';
part 'src/library_management_merge.dart';
part 'src/library_management_auto_merge.dart';
part 'src/library_management_devices.dart';
part 'src/library_management_formatting.dart';
part 'src/settings_page.dart';
part 'src/settings_distribution.dart';
part 'src/settings_library.dart';
part 'src/settings_pending_files.dart';
part 'src/settings_preferences.dart';
part 'src/song_display.dart';
part 'src/search_page.dart';
part 'src/detail_sheets.dart';
part 'src/track_detail_sheet.dart';
part 'src/track_media_details.dart';
part 'src/track_availability.dart';
part 'src/track_version_manager.dart';
part 'src/artist_editor.dart';
part 'src/artist_editor_sections.dart';
part 'src/artist_editor_canvas.dart';
part 'src/album_editor.dart';
part 'src/album_editor_sections.dart';
part 'src/album_detail_metadata.dart';
part 'src/track_editor.dart';
part 'src/track_editor_sections.dart';
part 'src/track_editor_components.dart';
part 'src/lyric_timeline_editor.dart';
part 'src/core_discovery.dart';
part 'src/client_library.dart';
part 'src/offline_library.dart';
part 'src/client_cache.dart';
part 'src/distribution.dart';
part 'src/i18n.dart';
part 'src/platform_integration.dart';
part 'src/renderer_audio.dart';
part 'src/dashboard_bootstrap.dart';
part 'src/dashboard_navigation.dart';
part 'src/dashboard_artwork_cache.dart';
part 'src/dashboard_catalog_identity.dart';
part 'src/dashboard_sync.dart';
part 'src/dashboard_renderer_devices.dart';
part 'src/dashboard_distribution.dart';
part 'src/dashboard_connection.dart';
part 'src/dashboard_renderer_audio.dart';
part 'src/dashboard_library.dart';
part 'src/dashboard_event_router.dart';
part 'src/dashboard_renderer_commands.dart';
part 'src/dashboard_renderer_reporting.dart';
part 'src/dashboard_details.dart';
part 'src/dashboard_offline_playback.dart';
part 'src/dashboard_playback_queue.dart';
part 'src/dashboard_playback_session_v3.dart';
part 'src/dashboard_queue_mutations.dart';
part 'src/dashboard_playback_controls.dart';
part 'src/dashboard_zone_state.dart';
part 'src/dashboard_shell.dart';

const _prefsCoreUrlKey = 'intmusic.core_url';
const _prefsLanguageKey = 'intmusic.language';
const _prefsClientAliasKey = 'intmusic.client_alias';
const _prefsAlbumViewModeKey = 'intmusic.view.albums';
const _prefsArtistViewModeKey = 'intmusic.view.artists';
const _prefsTrackViewModeKey = 'intmusic.view.tracks';
const _prefsRecentSearchesKey = 'intmusic.search.recent';
const _prefsPinCurrentClientRegionKey =
    'intmusic.playback_regions.pin_current_client';
const _prefsRegionSortKey = 'intmusic.playback_regions.sort';
const _prefsClientLibraryRootsKey = 'intmusic.client_library.roots';
const _prefsDiagnosticLoggingKey = 'intmusic.diagnostics.logging';
final CacheManager _artworkCacheManager = CacheManager(
  Config(
    'intmusicArtworkCache',
    stalePeriod: const Duration(days: 60),
    maxNrOfCacheObjects: Platform.isAndroid ? 4000 : 8000,
  ),
);

void runIntMusicClient() {
  WidgetsFlutterBinding.ensureInitialized();
  if (_usesDesktopRendererBackend) {
    MediaKit.ensureInitialized();
  }
  PaintingBinding.instance.imageCache.maximumSizeBytes =
      (Platform.isAndroid ? 64 : 128) * 1024 * 1024;
  PaintingBinding.instance.imageCache.maximumSize = Platform.isAndroid
      ? 350
      : 700;
  runApp(const IntMusicClientApp());
}

@visibleForTesting
Widget libraryFileDetailDialogForTesting(Map<String, dynamic> detail) {
  return _LibraryFileDetailDialog(detail: detail, onOpenTrack: (_) {});
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
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            disableAnimations:
                media.disableAnimations || useCompactAndroidRendering(context),
          ),
          child: _WindowsA11yQuiet(child: child),
        );
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
  final _collections = CollectionStore();
  final _serverAliasController = TextEditingController();
  final _clientAliasController = TextEditingController();
  final _libraryRootController = TextEditingController();
  final Map<String, Future<RendererSession>> _audioPlayers = {};
  final Map<String, StreamSubscription<RendererSnapshot>>
  _rendererSessionSubscriptions = {};
  final Map<String, Map<String, dynamic>> _rendererActiveCommandByOutput = {};
  final Map<String, StreamSubscription<AudioParams>> _audioParamsSubscriptions =
      {};
  final Map<String, AudioDevice> _rendererAudioDevicesByOutput = {};
  final Map<String, _SystemVolumeState> _rendererSystemVolumeByOutput = {};
  final Map<String, Map<String, dynamic>> _rendererPlaybackByOutput = {};
  final Map<String, RendererSnapshot> _rendererSnapshotsByOutput = {};
  final Map<String, int> _rendererLoadedTrackByOutput = {};
  Player? _rendererDeviceProbe;
  StreamSubscription<List<AudioDevice>>? _rendererDeviceSubscription;
  Future<void>? _rendererAudioInitialization;
  final PeriodicTaskScheduler _taskScheduler = PeriodicTaskScheduler();
  Timer? _eventReconnectTimer;
  Timer? _eventHealthTimer;
  Timer? _offlineReconnectTimer;
  Timer? _playbackCheckpointTimer;
  DateTime? _lastPlaybackCheckpointAt;
  int _offlineReconnectFailures = 0;
  bool _offlineReconnectBusy = false;
  int _zoneRefreshFailures = 0;
  Timer? _searchDebounce;
  WebSocket? _eventSocket;
  String? _eventSocketBaseUrl;
  final _connectionClock = Stopwatch()..start();
  ConnectionWatchdog? _connectionWatchdog;
  int _eventPingSequence = 0;
  int _eventConnectionGeneration = 0;
  bool _eventRestartBusy = false;
  int _eventReconnectFailures = 0;
  String? _rendererRegisteredCoreUrl;
  Future<void>? _rendererRegistrationInFlight;
  bool _rendererRegistrationNeedsReset = false;
  bool _rendererRegistrationNeedsPlaybackSync = false;
  final RendererCommandSequences _rendererCommandSequences =
      RendererCommandSequences();
  final Map<String, int> _playbackStateSequenceByZone = {};
  final Map<String, int> _rendererOperationGenerationByOutput = {};
  final Map<String, Future<void>> _rendererCommandQueueByOutput = {};
  final Map<String, SerialTaskQueue> _playbackRequestsByZone = {};
  final Map<String, SerialTaskQueue> _rendererReportsByOutput = {};
  final Map<String, String> _desiredTransportStateByZone = {};
  final Map<String, Map<String, dynamic>> _pendingPlaybackCommandsV3 = {};
  bool _reconcilingPendingPlaybackCommandsV3 = false;
  SharedPreferences? _preferences;
  final NavigationHistory<_AppRoute> _navigation = NavigationHistory<_AppRoute>(
    const _AppRoute.home(),
  );
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
  final Map<String, PlaybackAgent> _playbackAgentsByOutput =
      <String, PlaybackAgent>{};
  Map<String, dynamic>? _activeTrackDetail;
  final Map<int, Map<String, dynamic>> _trackDetailCache = {};
  final Map<int, Map<String, dynamic>> _albumDetailCache = {};
  final Map<int, Map<String, dynamic>> _artistDetailCache = {};
  final Map<int, Map<String, dynamic>> _trackAvailabilityById = {};
  String? _trackAvailabilityPresenceSignature;
  final Map<String, Map<String, dynamic>> _searchResultCache = {};
  Map<String, dynamic>? _playbackStats;
  int? _activeTrackDetailId;
  List<dynamic> _albums = const [];
  List<dynamic> _artists = const [];
  List<dynamic> _tracks = const [];
  List<dynamic> _outputs = const [];
  List<dynamic> _zones = const [];
  List<dynamic> _libraryRoots = const [];
  List<_ClientLibraryRoot> _clientLibraryRoots = const [];
  List<dynamic> _clientLibraryStatuses = const [];
  List<dynamic> _distributionJobs = const [];
  Map<String, dynamic>? _transcodingStatus;
  final _clientLibrarySyncQueue = SerialTaskQueue();
  final _catalogSyncQueue = SerialTaskQueue();
  final _offlineMutationSyncQueue = SerialTaskQueue();
  final Set<String> _clientLibraryQueuedRootIds = <String>{};
  final Set<String> _clientLibrarySyncingRootIds = <String>{};
  final Set<String> _distributionDirtyRootIds = <String>{};
  bool _distributionWorkerBusy = false;
  _OfflineLibrarySnapshot _offlineLibrary = _OfflineLibrarySnapshot();
  String? _cacheServerId;
  String? _cacheCatalogEpoch;
  int _cacheCursor = 0;
  int _eventCursor = 0;
  bool _backgroundSyncBusy = false;
  bool _detailWarmupBusy = false;
  bool _artworkWarmupBusy = false;
  bool _artworkWarmupRequested = false;
  bool _zoneRefreshBusy = false;
  bool _coreOfflineProbeBusy = false;
  int _coreReachabilityFailures = 0;
  bool _eventConnectBusy = false;
  int _backgroundSyncTicks = 0;
  final Set<String> _detailRefreshScopes = <String>{};
  final Map<String, int> _detailWarmAfterIds = <String, int>{};
  final Map<String, int> _detailWarmTargetCursors = <String, int>{};
  bool _localPlaybackFallbackActive = false;
  final Set<int> _verifiedLocalTrackIds = <int>{};
  bool _diagnosticLoggingEnabled = true;
  String _diagnosticLogPath = '';

  final Map<String, bool> _rendererLocalFileByOutput = <String, bool>{};
  final Map<String, bool> _rendererPlayingByOutput = <String, bool>{};
  final Map<String, int> _rendererAudioOperationDepthByOutput = <String, int>{};
  final Set<String> _rendererFailoverBusy = <String>{};
  DateTime? _offlinePlaybackStartedAt;
  int _offlinePlaybackStartPositionMs = 0;
  List<dynamic> _playbackHistory = const [];
  Map<String, dynamic>? _favoriteSettings;
  Map<String, dynamic>? _metadataSettings;
  Map<String, dynamic> _songDisplaySettings = {};
  final _songDisplayState = SongDisplayState();
  final _songDisplaySettingsQueue = SerialTaskQueue();
  String _searchQuery = '';
  final Map<String, _SearchScope> _searchScopeByQuery = {};
  final Map<String, _SearchSort> _searchSortByQuery = {};
  _LibraryViewMode _albumViewMode = _LibraryViewMode.grid;
  _LibraryViewMode _artistViewMode = _LibraryViewMode.grid;
  _LibraryViewMode _trackViewMode = _LibraryViewMode.list;
  bool _pinCurrentClientRegion = true;
  _ZoneRegionSort _zoneRegionSort = _ZoneRegionSort.playingFirst;
  List<_SearchSuggestion> _searchSuggestions = const [];
  List<String> _recentSearches = const [];
  final ValueNotifier<int> _playbackRevision = ValueNotifier<int>(0);
  late final AnimationController _playbackRevealController;
  int _pageTransitionDirection = 1;

  CoreApiClient get _api => CoreApiClient(_coreUrlController.text);
  String get _clientId => _sanitizeRendererId(
    'flutter-${Platform.operatingSystem}-${Platform.localHostname}',
  );
  String get _clientZonePrefix => 'renderer:$_clientId:';
  String get _clientOutputId => 'renderer:$_clientId:default';

  void _mutate(VoidCallback mutation) {
    if (mounted) {
      setState(mutation);
    }
  }

  void _mutatePlayback(VoidCallback mutation) {
    if (!mounted) return;
    mutation();
    _playbackRevision.value += 1;
  }

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
    _taskScheduler.dispose();
    CoreApiClient.closeAll();
    _eventReconnectTimer?.cancel();
    _eventHealthTimer?.cancel();
    _offlineReconnectTimer?.cancel();
    _playbackCheckpointTimer?.cancel();
    _searchDebounce?.cancel();
    unawaited(_reportRendererShutdown());
    unawaited(_eventSocket?.close() ?? Future<void>.value());
    for (final subscription in _rendererSessionSubscriptions.values) {
      unawaited(subscription.cancel());
    }
    for (final subscription in _audioParamsSubscriptions.values) {
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
    _songDisplayState.dispose();
    _collections.dispose();
    _playbackRevision.dispose();
    _playbackRevealController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final backgrounded = state != AppLifecycleState.resumed;
    _taskScheduler.setBackgrounded(backgrounded);
    _collections.setBackgrounded(backgrounded);
    if (state == AppLifecycleState.detached) {
      unawaited(_reportRendererShutdown());
    }
  }

  Future<T?> _run<T>(Future<T> Function() task) async {
    _mutate(() {
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
        _mutate(() => _loading = false);
      }
    }
  }

  Widget _withTrackActions({required Widget child}) => _TrackActionScope(
    onPlayNext: (trackId) => _addTrackToQueue(trackId, playNext: true),
    onAddToQueue: (trackId) => _addTrackToQueue(trackId),
    onPlayCollection: _playCollection,
    onQueueCollection: (trackIds, playNext) =>
        _addTracksToQueue(trackIds, playNext: playNext),
    onDistributeCollection: _distributeTracks,
    songDisplaySettings: _songDisplaySettings,
    displayState: _songDisplayState,
    onSetSongDisplaySettings: _setSongDisplaySettings,
    catalogTracks: _tracks,
    onPlayListSong: _playTrackFromCollection,
    onSetDisplayMode: _setSongDisplayMode,
    onApplyTagMappings: _applyTagMappings,
    onOpenTrack: _openTrackDetail,
    onPlayTrack: _playTrack,
    child: child,
  );

  @override
  Widget build(BuildContext context) {
    _collections.configure(_api, _status);
    return _LocaleScope(
      language: _language,
      child: _withTrackActions(
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
}
