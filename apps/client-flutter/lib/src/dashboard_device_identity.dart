part of '../intmusic_client.dart';

extension _DashboardDeviceIdentity on _CoreDashboardState {
  Future<void> _initializeDeviceIdentity() async {
    final native = await _IntMusicPlatform.instance.deviceIdentity();
    SharedPreferences? preferences;
    try {
      preferences = await SharedPreferences.getInstance();
      _preferences = preferences;
    } catch (error) {
      ClientLog.error('device.identity.preferences_failed', error);
    }
    _deviceIdentity = ClientDeviceIdentity.resolve(
      platform: Platform.operatingSystem,
      native: native,
      fallbackId: preferences?.getString('intmusic.device.id') ?? _clientId,
      hostname: Platform.localHostname,
    );
    try {
      await preferences?.setString('intmusic.device.id', _clientId);
    } catch (error) {
      ClientLog.error('device.identity.save_failed', error);
    }
    _selectedZoneId = _clientOutputId;
    _selectedZoneLabel = 'This device';
    _clientAliasController.text = _defaultClientAlias();
    if (!_deviceIdentity.systemBacked) {
      ClientLog.event(
        'device.identity.system_unavailable',
        level: 'warning',
        message:
            'Using a saved installation ID; reinstall stability is unavailable.',
      );
    }
  }

  Future<void> _ensureLocalLibraryDeviceBinding() async {
    final preferences = _preferences;
    if (preferences == null ||
        _clientLibraryRoots.isEmpty ||
        _clientLibraryDeviceBinding) {
      return;
    }
    final key =
        'intmusic.client_library.owner.${_cacheServerId ?? _api.baseUrl}';
    final hasUnboundFiles = _offlineLibrary.copies.values.any(
      (copy) => copy.trackId < 0,
    );
    final needsIndexRepair = _clientLibraryRoots.any(
      (root) =>
          _offlineLibrary.copies.values
              .where((copy) => copy.rootExternalId == root.externalId)
              .length <
          root.fileCount,
    );
    if (preferences.getString(key) == _clientId &&
        !hasUnboundFiles &&
        !needsIndexRepair) {
      return;
    }
    _clientLibraryDeviceBinding = true;
    try {
      await _clientLibrarySyncQueue.run(() async {});
      await _syncAllClientLibraryRoots(refreshAfter: false);
      if (!mounted ||
          _clientLibraryRoots.any((root) => root.lastError != null) ||
          key !=
              'intmusic.client_library.owner.${_cacheServerId ?? _api.baseUrl}') {
        return;
      }
      await preferences.setString(key, _clientId);
      await _backgroundLibrarySync(force: true);
    } catch (error) {
      ClientLog.error('device.library.rebind_failed', error);
    } finally {
      _clientLibraryDeviceBinding = false;
    }
  }
}
