import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit;
import 'package:flutter/services.dart';

import '../models/subscription_metadata.dart';
import '../models/subscription_profile.dart';
import '../models/local_socks_auth_settings.dart';
import '../models/vpn_routing_settings.dart';
import '../services/app_settings_store.dart';
import '../services/auth_api.dart';
import '../services/auth_store.dart';
import '../services/subscription_api.dart';
import '../services/subscription_store.dart';
import '../vpn/vpn_runtime.dart';
import '../vpn/vpn_runtime_factory.dart';
import '../vpn/vpn_connection_restarter.dart';
import 'settings_screen.dart';
import 'subscription_screen.dart';

final _connectivityTestUri =
    Uri.https('connectivitycheck.gstatic.com', '/generate_204');

int _compareGroupOrders(int? a, int? b) {
  if (a == null) return b == null ? 0 : 1;
  if (b == null) return -1;
  return a.compareTo(b);
}

class VpnHomeScreen extends StatefulWidget {
  const VpnHomeScreen({
    super.key,
    required this.profiles,
    required this.accountName,
    required this.themeMode,
    required this.onThemeModeChanged,
    this.authToken,
    this.accountProfile,
    this.primarySubscriptionError,
    this.primaryMetadata = const SubscriptionMetadata(),
    this.initialTab = 0,
  });

  final List<SubscriptionProfile> profiles;
  final String accountName;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final String? authToken;
  final AuthProfile? accountProfile;
  final String? primarySubscriptionError;
  final SubscriptionMetadata primaryMetadata;
  final int initialTab;

  @override
  State<VpnHomeScreen> createState() => _VpnHomeScreenState();
}

class _VpnHomeScreenState extends State<VpnHomeScreen> {
  static const _deepLinkChannel = MethodChannel('oksanavpn/deep_links');
  late final VpnRuntime _runtime = createVpnRuntime();
  final _externalUrlController = TextEditingController();
  final _subscriptionApi = SubscriptionApi();
  final _subscriptionStore = const SubscriptionStore();
  final _settingsStore = const AppSettingsStore();
  final _authApi = AuthApi();
  final _authStore = const AuthStore();

  late final List<SubscriptionProfile> _primaryProfiles =
      List.of(widget.profiles);
  SubscriptionMetadata _primaryMetadata = const SubscriptionMetadata();
  late List<SubscriptionProfile> _profiles = List.of(widget.profiles);
  final Map<String, List<SubscriptionProfile>> _externalProfilesByUrl = {};
  final Map<String, SubscriptionMetadata> _externalMetadataByUrl = {};
  final Map<String, Timer> _subscriptionTimers = {};
  SubscriptionProfile? _selectedProfile;
  final Map<SubscriptionProfile, int> _pingResults = {};
  final Set<SubscriptionProfile> _pingingProfiles = {};
  final Map<String, Set<String>> _favoriteProfilesBySubscription = {};
  bool _pingingAll = false;
  bool _savingFavorites = false;
  bool _favoritesExpanded = true;
  bool _refreshingSubscriptions = false;
  String? _activeSubscriptionKey = 'oksana';
  VpnMode _selectedMode = VpnMode.tun;
  VpnRoutingSettings _routingSettings = const VpnRoutingSettings();
  GlobalDnsSettings _globalDnsSettings = const GlobalDnsSettings();
  LocalSocksAuthSettings _localSocksAuthSettings =
      const LocalSocksAuthSettings();
  ThemeMode _selectedThemeMode = ThemeMode.system;
  late int _selectedTab = widget.initialTab;
  bool _switchingServer = false;
  bool _restartingForSettings = false;
  bool _connectionSettingsLoaded = false;
  List<String> _externalUrls = [];
  bool _loadingExternal = false;
  String? _externalError;
  String? _primarySubscriptionError;
  late AuthProfile? _accountProfile = widget.accountProfile;
  String? _accountError;
  bool _refreshingAccount = false;
  final Map<String, bool> _expandedServerGroups = {};
  String? _subscriptionError;

  bool get _pinging => _pingingProfiles.isNotEmpty;

  @override
  void dispose() {
    _runtime.dispose();
    for (final timer in _subscriptionTimers.values) {
      timer.cancel();
    }
    _subscriptionApi.close();
    _authApi.close();
    _externalUrlController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _primarySubscriptionError = widget.primarySubscriptionError;
    _primaryMetadata = widget.primaryMetadata;
    _selectedThemeMode = widget.themeMode;
    if (widget.authToken != null && _accountProfile == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_refreshAccount());
      });
    }
    unawaited(_restoreVpnMode());
    if (_profiles.isNotEmpty) {
      _selectedProfile = _profiles.first;
      _scheduleSubscriptionUpdate('oksana', _primaryMetadata);
    } else {
      _activeSubscriptionKey = null;
    }
    unawaited(_restoreExternalSubscriptions());
    unawaited(_restoreFavoriteProfiles());
  }

  Future<void> _refreshAccount() async {
    final token = widget.authToken;
    if (token == null || _refreshingAccount) return;
    setState(() {
      _refreshingAccount = true;
      _accountError = null;
    });
    try {
      final profile = await _authApi.fetchProfile(token);
      if (!mounted) return;
      setState(() {
        _accountProfile = profile;
        _accountError = null;
      });
    } on AuthApiException catch (error) {
      if (mounted) setState(() => _accountError = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _accountError = 'Не удалось обновить данные аккаунта.');
      }
    } finally {
      if (mounted) setState(() => _refreshingAccount = false);
    }
  }

  Future<void> _restoreVpnMode() async {
    try {
      final mode = await _settingsStore.readVpnMode();
      final themeMode = await _settingsStore.readThemeMode();
      final routingSettings = await _settingsStore.readRoutingSettings();
      final globalDnsSettings = await _settingsStore.readGlobalDnsSettings();
      final localSocksAuthSettings =
          await _settingsStore.readLocalSocksAuthSettings();
      if (!mounted) return;
      setState(() {
        if (mode != null && _runtime.supports(mode)) _selectedMode = mode;
        if (themeMode != null) _selectedThemeMode = themeMode;
        _routingSettings = routingSettings;
        _globalDnsSettings = globalDnsSettings;
        _localSocksAuthSettings = localSocksAuthSettings;
        _connectionSettingsLoaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _localSocksAuthSettings = LocalSocksAuthSettings.createSecureDefault();
        _connectionSettingsLoaded = true;
      });
    }
  }

  Future<void> _restoreFavoriteProfiles() async {
    try {
      final favorites = await _subscriptionStore.readFavoriteProfiles();
      if (!mounted) return;
      setState(() {
        for (final entry in favorites.entries) {
          final existing =
              _favoriteProfilesBySubscription.putIfAbsent(entry.key, () => {});
          existing.addAll(entry.value);
        }
      });
    } catch (_) {
      // Favorites remain available for the current session if storage fails.
    }
  }

  bool _isFavorite(SubscriptionProfile profile) {
    final subscriptionKey = _activeSubscriptionKey;
    if (subscriptionKey == null) return false;
    return _favoriteProfilesBySubscription[subscriptionKey]
            ?.contains(profile.favoriteKey) ??
        false;
  }

  Future<void> _toggleFavorite(SubscriptionProfile profile) async {
    final subscriptionKey = _activeSubscriptionKey;
    if (subscriptionKey == null || _savingFavorites) return;

    final previous = Set<String>.of(
      _favoriteProfilesBySubscription[subscriptionKey] ?? const {},
    );
    final updated = Set<String>.of(previous);
    if (!updated.add(profile.favoriteKey)) {
      updated.remove(profile.favoriteKey);
    }

    setState(() {
      _favoriteProfilesBySubscription[subscriptionKey] = updated;
      _savingFavorites = true;
    });
    try {
      await _subscriptionStore.saveFavoriteProfiles(
        _favoriteProfilesBySubscription.map(
          (key, value) => MapEntry(key, Set<String>.of(value)),
        ),
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          if (previous.isEmpty) {
            _favoriteProfilesBySubscription.remove(subscriptionKey);
          } else {
            _favoriteProfilesBySubscription[subscriptionKey] = previous;
          }
        });
        _showMessage('Не удалось сохранить избранное.');
      }
    } finally {
      if (mounted) setState(() => _savingFavorites = false);
    }
  }

  Future<void> _restoreExternalSubscriptions() async {
    try {
      final urls = await _subscriptionStore.readExternalSubscriptions();
      if (!mounted || urls.isEmpty) return;
      await _refreshAllExternal(urls);
    } catch (_) {
      if (mounted) {
        setState(() =>
            _externalError = 'Не удалось прочитать список сторонних подписок.');
      }
    }
  }

  Map<String, List<SubscriptionProfile>> _subscriptionSets() {
    final sets = <String, List<SubscriptionProfile>>{};
    if (_primaryProfiles.isNotEmpty) sets['oksana'] = _primaryProfiles;
    for (final url in _externalUrls) {
      final profiles = _externalProfilesByUrl[url];
      if (profiles != null && profiles.isNotEmpty) {
        sets['external:$url'] = profiles;
      }
    }
    return sets;
  }

  SubscriptionMetadata _metadataFor(String? key) {
    if (key == 'oksana') return _primaryMetadata;
    if (key != null && key.startsWith('external:')) {
      return _externalMetadataByUrl[key.substring('external:'.length)] ??
          const SubscriptionMetadata();
    }
    return const SubscriptionMetadata();
  }

  String _subscriptionName(String key) {
    final title = _metadataFor(key).title;
    if (title != null && title.isNotEmpty) return title;
    if (key == 'oksana') return 'Oksana VPN';
    final index = _externalUrls.indexOf(key.substring('external:'.length));
    return index < 0 ? 'Сторонняя подписка' : 'Сторонняя подписка ${index + 1}';
  }

  void _selectAvailableSubscription({bool selectPrimaryFirst = false}) {
    final previousKey = _activeSubscriptionKey;
    final previousProfile = _selectedProfile;
    final sets = _subscriptionSets();
    if (sets.isEmpty) {
      _activeSubscriptionKey = null;
      _profiles = [];
      _selectedProfile = null;
      return;
    }
    final preferredKey = selectPrimaryFirst && sets.containsKey('oksana')
        ? 'oksana'
        : sets.containsKey(_activeSubscriptionKey)
            ? _activeSubscriptionKey!
            : sets.keys.first;
    _activeSubscriptionKey = preferredKey;
    _profiles = sets[preferredKey]!;
    if (!_profiles.contains(previousProfile)) {
      final previousId = previousProfile?.stableId;
      final preserved = previousKey == preferredKey && previousId != null
          ? _profiles.where((profile) => profile.stableId == previousId)
          : const <SubscriptionProfile>[];
      _selectedProfile = preserved.isNotEmpty
          ? preserved.first
          : _profiles.isEmpty
              ? null
              : _profiles.first;
    }
  }

  Future<Map<String, SubscriptionLoadResult>> _fetchExternal(
      List<String> urls) async {
    final profilesByUrl = <String, SubscriptionLoadResult>{};
    for (var i = 0; i < urls.length; i++) {
      try {
        profilesByUrl[urls[i]] =
            await _subscriptionApi.fetchExternalProfiles(urls[i]);
      } on SubscriptionApiException catch (error) {
        _externalError = error.message;
      }
    }
    return profilesByUrl;
  }

  Future<void> _refreshAllExternal(List<String> urls) async {
    setState(() {
      _loadingExternal = true;
      _externalError = null;
    });
    final externalProfiles = await _fetchExternal(urls);
    if (!mounted) return;
    setState(() {
      _externalUrls = List.of(urls);
      _mergeExternalResults(externalProfiles);
      _scheduleExternalUpdates(externalProfiles);
      _selectAvailableSubscription();
      _loadingExternal = false;
    });
  }

  void _mergeExternalResults(
    Map<String, SubscriptionLoadResult> sources,
  ) {
    _externalProfilesByUrl
        .removeWhere((url, _) => !_externalUrls.contains(url));
    _externalMetadataByUrl
        .removeWhere((url, _) => !_externalUrls.contains(url));
    for (final entry in sources.entries) {
      _externalProfilesByUrl[entry.key] = entry.value.profiles;
      _externalMetadataByUrl[entry.key] = entry.value.metadata;
    }
  }

  void _scheduleExternalUpdates(
    Map<String, SubscriptionLoadResult> sources,
  ) {
    final activeUrls = sources.keys.toSet();
    for (final url in _externalUrls) {
      final key = 'external:$url';
      final metadata = sources[url]?.metadata ?? _externalMetadataByUrl[url];
      if (!activeUrls.contains(url) && metadata == null) {
        _subscriptionTimers.remove(key)?.cancel();
        continue;
      }
      _scheduleSubscriptionUpdate(key, metadata!);
    }
  }

  void _scheduleSubscriptionUpdate(
    String key,
    SubscriptionMetadata metadata, {
    Duration? delay,
  }) {
    _subscriptionTimers.remove(key)?.cancel();
    final interval = delay ?? metadata.refreshInterval;
    if (interval == null) return;
    _subscriptionTimers[key] = Timer(
      interval,
      () => unawaited(_autoRefreshSubscription(key)),
    );
  }

  Future<void> _autoRefreshSubscription(String key) async {
    if (!mounted) return;
    if (_runtime.snapshot.phase != VpnRuntimePhase.disconnected ||
        _refreshingSubscriptions ||
        _loadingExternal) {
      _scheduleSubscriptionUpdate(
        key,
        _metadataFor(key),
        delay: const Duration(minutes: 5),
      );
      return;
    }

    try {
      if (key == 'oksana') {
        final token = widget.authToken;
        if (token == null) return;
        final account = await _authApi.fetchProfile(token);
        final loaded = await _subscriptionApi.fetchProfiles(account.uuid);
        if (!mounted) return;
        setState(() {
          _accountProfile = account;
          _accountError = null;
          _primaryProfiles
            ..clear()
            ..addAll(loaded.profiles);
          _primaryMetadata = loaded.metadata;
          _primarySubscriptionError = null;
          _selectAvailableSubscription();
          _pingResults.clear();
        });
        _scheduleSubscriptionUpdate(key, loaded.metadata);
        return;
      }

      final url = key.substring('external:'.length);
      if (!_externalUrls.contains(url)) return;
      final loaded = await _subscriptionApi.fetchExternalProfiles(url);
      if (!mounted || !_externalUrls.contains(url)) return;
      setState(() {
        _externalProfilesByUrl[url] = loaded.profiles;
        _externalMetadataByUrl[url] = loaded.metadata;
        if (_activeSubscriptionKey == key) _selectAvailableSubscription();
        _pingResults.clear();
      });
      _scheduleSubscriptionUpdate(key, loaded.metadata);
    } on AuthApiException catch (error) {
      if (mounted) setState(() => _subscriptionError = error.message);
      _scheduleSubscriptionUpdate(key, _metadataFor(key));
    } on SubscriptionApiException catch (error) {
      if (mounted) setState(() => _subscriptionError = error.message);
      _scheduleSubscriptionUpdate(key, _metadataFor(key));
    } catch (_) {
      _scheduleSubscriptionUpdate(key, _metadataFor(key));
    }
  }

  Future<void> _toggleConnection() async {
    if (!_connectionSettingsLoaded) {
      _showMessage('Загружаем настройки подключения…');
      return;
    }
    final selectedProfile = _selectedProfile;
    if (selectedProfile == null) {
      _showMessage('Добавьте подписку, чтобы выбрать сервер.');
      return;
    }
    try {
      if (_runtime.snapshot.phase == VpnRuntimePhase.running) {
        await _runtime.disconnect();
      } else {
        await _runtime.connect(
          selectedProfile,
          _selectedMode,
          routingSettings: _routingSettings,
          globalDnsSettings: _globalDnsSettings,
          localSocksAuthSettings: _localSocksAuthSettings,
        );
      }
    } on VpnRuntimeException catch (error) {
      _showMessage(error.message);
    }
  }

  Future<void> _selectProfile(SubscriptionProfile profile) async {
    if (!_connectionSettingsLoaded) return;
    final phase = _runtime.snapshot.phase;
    if (_switchingServer ||
        phase == VpnRuntimePhase.starting ||
        phase == VpnRuntimePhase.stopping ||
        (identical(profile, _selectedProfile) &&
            phase == VpnRuntimePhase.running)) {
      return;
    }

    final shouldStopFirst =
        phase == VpnRuntimePhase.running || phase == VpnRuntimePhase.error;
    setState(() {
      _selectedProfile = profile;
      _switchingServer = shouldStopFirst;
    });

    try {
      if (shouldStopFirst) {
        await _runtime.disconnect();
        if (_runtime.snapshot.phase == VpnRuntimePhase.error) {
          throw VpnRuntimeException(
            _runtime.snapshot.errorMessage ?? 'Не удалось отключить VPN.',
          );
        }
      }
      await _runtime.connect(
        profile,
        _selectedMode,
        routingSettings: _routingSettings,
        globalDnsSettings: _globalDnsSettings,
        localSocksAuthSettings: _localSocksAuthSettings,
      );
    } on VpnRuntimeException catch (error) {
      _showMessage(error.message);
    } finally {
      if (mounted) setState(() => _switchingServer = false);
    }
  }

  Future<void> _selectSubscription(String key) async {
    final nextProfiles = _subscriptionSets()[key];
    final phase = _runtime.snapshot.phase;
    if (nextProfiles == null ||
        nextProfiles.isEmpty ||
        key == _activeSubscriptionKey ||
        _switchingServer ||
        phase == VpnRuntimePhase.starting ||
        phase == VpnRuntimePhase.stopping) {
      return;
    }

    final wasRunning = phase == VpnRuntimePhase.running;
    if (wasRunning && !_connectionSettingsLoaded) {
      _showMessage('Загружаем настройки подключения…');
      return;
    }
    setState(() => _switchingServer = wasRunning);
    try {
      if (wasRunning || phase == VpnRuntimePhase.error) {
        await _runtime.disconnect();
        if (_runtime.snapshot.phase == VpnRuntimePhase.error) {
          throw VpnRuntimeException(
            _runtime.snapshot.errorMessage ?? 'Не удалось отключить VPN.',
          );
        }
      }
      final profile = nextProfiles.first;
      setState(() {
        _activeSubscriptionKey = key;
        _profiles = nextProfiles;
        _selectedProfile = profile;
        _pingResults.clear();
      });
      if (wasRunning) {
        await _runtime.connect(
          profile,
          _selectedMode,
          routingSettings: _routingSettings,
          globalDnsSettings: _globalDnsSettings,
          localSocksAuthSettings: _localSocksAuthSettings,
        );
      }
    } on VpnRuntimeException catch (error) {
      _showMessage(error.message);
    } finally {
      if (mounted) setState(() => _switchingServer = false);
    }
  }

  Future<void> _pingProfile(SubscriptionProfile profile) async {
    if (!_pingingProfiles.add(profile)) return;
    setState(() {});
    final result = await _measureProfile(profile);
    if (mounted) {
      setState(() {
        _pingResults[profile] = result;
        _pingingProfiles.remove(profile);
      });
    } else {
      _pingingProfiles.remove(profile);
    }
  }

  Future<int> _measureProfile(SubscriptionProfile profile) async {
    final runtime = _runtime;
    if (runtime is! VpnConnectivityProbe) return -1;
    try {
      return await (runtime as VpnConnectivityProbe)
          .probeConnectivity(profile, _connectivityTestUri);
    } catch (_) {
      return -1;
    }
  }

  Future<void> _pingAllProfiles() async {
    if (_pingingAll || _profiles.isEmpty || _pingingProfiles.isNotEmpty) return;
    setState(() => _pingingAll = true);
    try {
      await _pingProfiles(List<SubscriptionProfile>.of(_profiles));
    } finally {
      if (mounted) setState(() => _pingingAll = false);
    }
  }

  Future<void> _pingGroupProfiles(
    List<SubscriptionProfile> profiles,
  ) async {
    if (_pingingAll || _pingingProfiles.isNotEmpty) return;
    await _pingProfiles(profiles);
  }

  Future<void> _pingProfiles(List<SubscriptionProfile> profiles) async {
    if (profiles.isEmpty || profiles.any(_pingingProfiles.contains)) return;
    setState(() {
      _pingingProfiles.addAll(profiles);
      for (final profile in profiles) {
        _pingResults.remove(profile);
      }
    });

    var nextIndex = 0;
    Future<void> worker() async {
      while (nextIndex < profiles.length) {
        final profile = profiles[nextIndex++];
        final result = await _measureProfile(profile);
        if (!mounted) return;
        setState(() => _pingResults[profile] = result);
      }
    }

    final workerCount = profiles.length < 3 ? profiles.length : 3;
    try {
      await Future.wait(List.generate(workerCount, (_) => worker()));
    } finally {
      _pingingProfiles.removeAll(profiles);
      if (mounted) setState(() {});
    }
  }

  Future<void> _updateSubscriptions() async {
    final authToken = widget.authToken;
    if (_refreshingSubscriptions ||
        _runtime.snapshot.phase != VpnRuntimePhase.disconnected) {
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _refreshingSubscriptions = true;
      _loadingExternal = true;
      _subscriptionError = null;
      _externalError = null;
    });

    List<SubscriptionProfile>? refreshedPrimary;
    SubscriptionMetadata? refreshedPrimaryMetadata;
    AuthProfile? refreshedAccountProfile;
    String? primaryError;
    if (authToken != null) {
      try {
        final account = await _authApi.fetchProfile(authToken);
        refreshedAccountProfile = account;
        final loaded = await _subscriptionApi.fetchProfiles(account.uuid);
        refreshedPrimary = loaded.profiles;
        refreshedPrimaryMetadata = loaded.metadata;
      } on AuthApiException catch (error) {
        primaryError = error.message;
      } on SubscriptionApiException catch (error) {
        primaryError = error.message;
      }
    }

    final refreshedExternal = await _fetchExternal(_externalUrls);
    if (!mounted) return;

    setState(() {
      if (refreshedAccountProfile != null) {
        _accountProfile = refreshedAccountProfile;
        _accountError = null;
      }
      if (refreshedPrimary != null) {
        _primaryProfiles
          ..clear()
          ..addAll(refreshedPrimary);
        _primaryMetadata = refreshedPrimaryMetadata!;
        _primarySubscriptionError = null;
        _scheduleSubscriptionUpdate('oksana', refreshedPrimaryMetadata);
      } else if (authToken != null) {
        _primarySubscriptionError = primaryError;
      }
      _mergeExternalResults(refreshedExternal);
      _scheduleExternalUpdates(refreshedExternal);
      _pingResults.clear();
      _selectAvailableSubscription(selectPrimaryFirst: true);
      _loadingExternal = false;
      _refreshingSubscriptions = false;
      if (primaryError != null) _subscriptionError = primaryError;
      if (_externalError != null) _subscriptionError ??= _externalError;
    });
  }

  Future<void> _addExternalSubscription() async {
    final url = _externalUrlController.text.trim();
    if (url.isEmpty || _externalUrls.contains(url)) return;
    final urls = [..._externalUrls, url];
    setState(() {
      _loadingExternal = true;
      _externalError = null;
    });
    try {
      final loaded = await _subscriptionApi.fetchExternalProfiles(url);
      await _subscriptionStore.saveExternalSubscriptions(urls);
      if (!mounted) return;
      _externalUrlController.clear();
      setState(() {
        _externalUrls = urls;
        _externalProfilesByUrl[url] = loaded.profiles;
        _externalMetadataByUrl[url] = loaded.metadata;
        _scheduleSubscriptionUpdate('external:$url', loaded.metadata);
        _pingResults.clear();
        if (_activeSubscriptionKey == null || _primaryProfiles.isEmpty) {
          _activeSubscriptionKey = 'external:$url';
        }
        _selectAvailableSubscription();
        _loadingExternal = false;
      });
    } on SubscriptionApiException catch (error) {
      if (mounted) {
        setState(() {
          _externalError = error.message;
          _loadingExternal = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _externalError = 'Не удалось сохранить ссылку подписки.';
          _loadingExternal = false;
        });
      }
    }
  }

  Future<void> _removeExternalSubscription(String url) async {
    final urls = _externalUrls.where((value) => value != url).toList();
    await _subscriptionStore.saveExternalSubscriptions(urls);
    await _refreshAllExternal(urls);
  }

  Future<void> _logout() async {
    final authToken = widget.authToken;
    if (authToken == null) return;
    if (_runtime.snapshot.phase != VpnRuntimePhase.disconnected) {
      await _runtime.disconnect();
    }
    await _authApi.logout(authToken);
    await _authStore.clear();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil<void>(
      MaterialPageRoute<void>(
        builder: (_) => SubscriptionScreen(
          themeMode: _selectedThemeMode,
          onThemeModeChanged: widget.onThemeModeChanged,
        ),
      ),
      (_) => false,
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openExternalLink(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null ||
        !{'https', 'http'}.contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      _showMessage('Ссылка подписки некорректна.');
      return;
    }
    try {
      final opened = await _deepLinkChannel.invokeMethod<bool>(
        'openExternalUrl',
        uri.toString(),
      );
      if (opened != true) _showMessage('Не удалось открыть ссылку.');
    } on PlatformException {
      _showMessage('Не удалось открыть ссылку.');
    }
  }

  Future<void> _changeMode(VpnMode mode) async {
    if (mode == _selectedMode) return;
    _ensureSettingsCanChange();
    if (!_runtime.supports(mode)) {
      throw const VpnRuntimeException('Этот режим недоступен на устройстве.');
    }
    final wasRunning = _runtime.snapshot.phase == VpnRuntimePhase.running;
    if (wasRunning && _selectedProfile == null) {
      throw const VpnRuntimeException('Не выбран сервер для переподключения.');
    }
    setState(() => _selectedMode = mode);
    final saving = _saveVpnMode(mode);
    if (wasRunning) {
      await _restartForSettings(saving);
    } else {
      await saving;
    }
    if (wasRunning || !mounted) return;
    final hint = mode == VpnMode.tun
        ? 'Весь системный трафик пойдёт через VPN. Может потребоваться разрешение на изменение сетевых настроек.'
        : _localSocksAuthSettings.enabled
            ? 'Proxy доступен через локальные порты. Для SOCKS5 используйте логин и пароль из настроек.'
            : 'VPN будет доступен приложениям через локальные SOCKS/HTTP порты.';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(hint),
          width: 420,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
  }

  Future<void> _saveVpnMode(VpnMode mode) async {
    try {
      await _settingsStore.saveVpnMode(mode);
    } catch (_) {
      // Keep the selected mode for this session if storage is unavailable.
    }
  }

  Future<void> _changeRoutingSettings(VpnRoutingSettings settings) async {
    if (_canonicalRoutingSettings(_routingSettings) ==
        _canonicalRoutingSettings(settings)) {
      return;
    }
    _ensureSettingsCanChange();
    final wasRunning = _runtime.snapshot.phase == VpnRuntimePhase.running;
    if (wasRunning && _selectedProfile == null) {
      throw const VpnRuntimeException('Не выбран сервер для переподключения.');
    }
    setState(() => _routingSettings = settings);
    final saving = _saveRoutingSettings(settings);
    if (wasRunning) {
      await _restartForSettings(saving);
    } else {
      await saving;
    }
  }

  Future<void> _changeLocalSocksAuthSettings(
    LocalSocksAuthSettings settings,
  ) async {
    if (_localSocksAuthSettings.encode() == settings.encode()) return;
    if (settings.enabled && settings.validationError != null) {
      throw VpnRuntimeException(settings.validationError!);
    }
    _ensureSettingsCanChange();
    final wasRunning = _selectedMode == VpnMode.proxy &&
        _runtime.snapshot.phase == VpnRuntimePhase.running;
    if (wasRunning && _selectedProfile == null) {
      throw const VpnRuntimeException('Не выбран сервер для переподключения.');
    }
    setState(() => _localSocksAuthSettings = settings);
    final saving = _saveLocalSocksAuthSettings(settings);
    if (wasRunning) {
      await _restartForSettings(saving);
    } else {
      await saving;
    }
  }

  Future<void> _changeGlobalDnsSettings(GlobalDnsSettings settings) async {
    if (_globalDnsSettings.encode() == settings.encode()) return;
    _ensureSettingsCanChange();
    final wasRunning = _selectedMode == VpnMode.tun &&
        _runtime.snapshot.phase == VpnRuntimePhase.running;
    if (wasRunning && _selectedProfile == null) {
      throw const VpnRuntimeException('Не выбран сервер для переподключения.');
    }
    setState(() => _globalDnsSettings = settings);
    final saving = _saveGlobalDnsSettings(settings);
    if (wasRunning) {
      await _restartForSettings(saving);
    } else {
      await saving;
    }
  }

  String _canonicalRoutingSettings(VpnRoutingSettings settings) =>
      VpnRoutingSettings(
        enabled: settings.enabled,
        templates: settings.templates.isEmpty
            ? [settings.activeTemplate]
            : settings.templates,
        activeTemplateId: settings.activeTemplate.id,
      ).encode();

  void _ensureSettingsCanChange() {
    if (!_connectionSettingsLoaded) {
      throw const VpnRuntimeException('Загружаем настройки подключения.');
    }
    final phase = _runtime.snapshot.phase;
    if (_switchingServer ||
        phase == VpnRuntimePhase.starting ||
        phase == VpnRuntimePhase.stopping) {
      throw const VpnRuntimeException('Дождитесь завершения подключения.');
    }
  }

  Future<void> _restartForSettings(Future<void> saving) async {
    final profile = _selectedProfile;
    if (profile == null) {
      throw const VpnRuntimeException('Не выбран сервер для переподключения.');
    }
    setState(() {
      _switchingServer = true;
      _restartingForSettings = true;
    });
    try {
      await restartVpnConnection(
        runtime: _runtime,
        profile: profile,
        mode: _selectedMode,
        routingSettings: _routingSettings,
        globalDnsSettings: _globalDnsSettings,
        localSocksAuthSettings: _localSocksAuthSettings,
        shouldReconnect: () => mounted,
      );
    } finally {
      await saving;
      if (mounted) {
        setState(() {
          _switchingServer = false;
          _restartingForSettings = false;
        });
      }
    }
  }

  Future<void> _saveRoutingSettings(VpnRoutingSettings settings) async {
    try {
      await _settingsStore.saveRoutingSettings(settings);
    } catch (_) {
      if (mounted) _showMessage('Не удалось сохранить правила маршрутизации.');
    }
  }

  Future<void> _saveGlobalDnsSettings(GlobalDnsSettings settings) async {
    try {
      await _settingsStore.saveGlobalDnsSettings(settings);
    } catch (_) {
      if (mounted) _showMessage('Не удалось сохранить настройки DNS.');
    }
  }

  Future<void> _saveLocalSocksAuthSettings(
    LocalSocksAuthSettings settings,
  ) async {
    try {
      await _settingsStore.saveLocalSocksAuthSettings(settings);
    } catch (_) {
      if (mounted) _showMessage('Не удалось сохранить настройки SOCKS5.');
    }
  }

  void _changeThemeMode(ThemeMode mode) {
    setState(() => _selectedThemeMode = mode);
    widget.onThemeModeChanged(mode);
  }

  void _openSettings() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(
          vpnMode: _selectedMode,
          currentVpnMode: () => _selectedMode,
          onVpnModeChanged: _changeMode,
          runtime: _runtime,
          themeMode: _selectedThemeMode,
          onThemeModeChanged: _changeThemeMode,
          supportsTun: _runtime.supports(VpnMode.tun),
          routingSettings: _routingSettings,
          currentRoutingSettings: () => _routingSettings,
          onRoutingSettingsChanged: _changeRoutingSettings,
          globalDnsSettings: _globalDnsSettings,
          currentGlobalDnsSettings: () => _globalDnsSettings,
          onGlobalDnsSettingsChanged: _changeGlobalDnsSettings,
          localSocksAuthSettings: _localSocksAuthSettings,
          currentLocalSocksAuthSettings: () => _localSocksAuthSettings,
          onLocalSocksAuthSettingsChanged: _changeLocalSocksAuthSettings,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<VpnRuntimeSnapshot>(
      stream: _runtime.changes,
      initialData: _runtime.snapshot,
      builder: (context, runtimeSnapshot) {
        final state = runtimeSnapshot.data ?? _runtime.snapshot;
        final phase = state.phase;
        final isBusy = phase == VpnRuntimePhase.starting ||
            phase == VpnRuntimePhase.stopping;
        final isRunning = phase == VpnRuntimePhase.running;

        final canUpdate = phase == VpnRuntimePhase.disconnected &&
            !_switchingServer &&
            !_refreshingSubscriptions;
        final colors = Theme.of(context).colorScheme;
        return Scaffold(
          body: Stack(
            children: [
              SafeArea(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 680),
                    child: switch (_selectedTab) {
                      0 => _buildConnectionView(
                          state: state,
                          isBusy: isBusy,
                          isRunning: isRunning,
                        ),
                      1 => _buildSubscriptionsView(canUpdate: canUpdate),
                      _ => _buildProfileView(canUpdate: canUpdate),
                    },
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: SizedBox(
                      height: 42,
                      child: Center(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Material(
                            color: colors.surface,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(24),
                              side: BorderSide(color: colors.outlineVariant),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _CompactNavItem(
                                    icon: Icons.home_outlined,
                                    selectedIcon: Icons.home_rounded,
                                    label: 'Главная',
                                    selected: _selectedTab == 0,
                                    onTap: () =>
                                        setState(() => _selectedTab = 0),
                                  ),
                                  const SizedBox(width: 4),
                                  _CompactNavItem(
                                    icon: Icons.credit_card_outlined,
                                    selectedIcon: Icons.credit_card_rounded,
                                    label: 'Подписки',
                                    selected: _selectedTab == 1,
                                    onTap: () =>
                                        setState(() => _selectedTab = 1),
                                  ),
                                  const SizedBox(width: 4),
                                  _CompactNavItem(
                                    icon: Icons.person_outline_rounded,
                                    selectedIcon: Icons.person_rounded,
                                    label: 'Профиль',
                                    selected: _selectedTab == 2,
                                    onTap: () =>
                                        setState(() => _selectedTab = 2),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildConnectionView({
    required VpnRuntimeSnapshot state,
    required bool isBusy,
    required bool isRunning,
  }) {
    final theme = Theme.of(context);
    final canConnect = _runtime.supports(_selectedMode);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 72),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(Icons.shield_rounded,
                    color: theme.colorScheme.primary, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Oksana VPN',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w800)),
              ),
              IconButton(
                tooltip: 'Настройки',
                onPressed: isBusy || _switchingServer ? null : _openSettings,
                icon: const Icon(Icons.settings_outlined),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              children: [
                const SizedBox(height: 8),
                _PowerControl(
                  phase: state.phase,
                  enabled: !isBusy &&
                      !_switchingServer &&
                      !_pinging &&
                      canConnect &&
                      _selectedProfile != null,
                  onPressed: _toggleConnection,
                ),
                const SizedBox(height: 12),
                Text(
                  _selectedProfile?.name ?? 'Нет выбранной конфигурации',
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  _connectionStatus(state),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: state.phase == VpnRuntimePhase.error
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _buildSelectedSubscriptionPanel(
            canRefresh: state.phase == VpnRuntimePhase.disconnected &&
                !_switchingServer &&
                !_refreshingSubscriptions &&
                !_loadingExternal,
            configurationsEnabled: !isBusy && !_switchingServer && !_pinging,
            isRunning: isRunning,
          ),
          if (state.phase == VpnRuntimePhase.error &&
              state.errorMessage != null) ...[
            const SizedBox(height: 12),
            Text(
              state.errorMessage!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }

  List<List<SubscriptionProfile>> _sortedProfileGroups() {
    final grouped = <String, List<SubscriptionProfile>>{};
    final firstGroupIndex = <String, int>{};
    for (var i = 0; i < _profiles.length; i++) {
      final profile = _profiles[i];
      firstGroupIndex.putIfAbsent(profile.groupKey, () => i);
      grouped.putIfAbsent(profile.groupKey, () => []).add(profile);
    }

    final defaultGroupProfiles = _profiles
        .where((profile) =>
            profile.groupIsDefault && profile.groupKey != 'ungrouped')
        .toList()
      ..sort((a, b) {
        final orderComparison =
            _compareGroupOrders(a.groupSortOrder, b.groupSortOrder);
        if (orderComparison != 0) return orderComparison;
        return firstGroupIndex[a.groupKey]!
            .compareTo(firstGroupIndex[b.groupKey]!);
      });
    if (defaultGroupProfiles.isNotEmpty) {
      final ungrouped = grouped.remove('ungrouped');
      if (ungrouped != null) {
        grouped[defaultGroupProfiles.first.groupKey]!.addAll(ungrouped);
      }
    }

    final groups = grouped.values.toList()
      ..sort((a, b) {
        final orderComparison = _compareGroupOrders(
          _groupMetadataProfile(a).groupSortOrder,
          _groupMetadataProfile(b).groupSortOrder,
        );
        if (orderComparison != 0) return orderComparison;
        final aDefault = a.any((profile) => profile.groupIsDefault) ||
            a.first.groupKey == 'ungrouped';
        final bDefault = b.any((profile) => profile.groupIsDefault) ||
            b.first.groupKey == 'ungrouped';
        if (aDefault != bDefault) return aDefault ? 1 : -1;
        return firstGroupIndex[a.first.groupKey]!
            .compareTo(firstGroupIndex[b.first.groupKey]!);
      });
    for (final group in groups) {
      group.sort((a, b) {
        final orderComparison = a.sortOrder.compareTo(b.sortOrder);
        if (orderComparison != 0) return orderComparison;
        return a.index.compareTo(b.index);
      });
    }
    return groups;
  }

  SubscriptionProfile _groupMetadataProfile(
    List<SubscriptionProfile> profiles,
  ) =>
      profiles.firstWhere(
        (profile) => profile.groupKey != 'ungrouped',
        orElse: () => profiles.first,
      );

  Widget _buildConfigurationList({
    required bool enabled,
    required bool isRunning,
  }) {
    final groups = _sortedProfileGroups();
    final favorites = _profiles.where(_isFavorite).toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_profiles.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Text(_primarySubscriptionError ??
                'Выберите подписку с доступными конфигурациями.'),
          ),
        if (favorites.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                splashFactory: NoSplash.splashFactory,
                mouseCursor: SystemMouseCursors.click,
                overlayColor: WidgetStateProperty.resolveWith((states) {
                  final colors = Theme.of(context).colorScheme;
                  if (states.contains(WidgetState.pressed)) {
                    return colors.primary.withValues(alpha: 0.08);
                  }
                  if (states.contains(WidgetState.hovered)) {
                    return colors.onSurface.withValues(alpha: 0.045);
                  }
                  if (states.contains(WidgetState.focused)) {
                    return colors.primary.withValues(alpha: 0.05);
                  }
                  return Colors.transparent;
                }),
                onTap: () =>
                    setState(() => _favoritesExpanded = !_favoritesExpanded),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Row(children: [
                    Icon(Icons.star_rounded,
                        size: 17, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 6),
                    Text('Избранное',
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    const Spacer(),
                    Text('${favorites.length}',
                        style: Theme.of(context).textTheme.labelSmall),
                    const SizedBox(width: 6),
                    Icon(
                      _favoritesExpanded
                          ? Icons.expand_less
                          : Icons.expand_more,
                      size: 18,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ]),
                ),
              ),
            ),
          ),
          if (_favoritesExpanded)
            ..._configurationRows(
              favorites,
              enabled: enabled,
              favoriteEnabled: !_savingFavorites,
              isRunning: isRunning,
            ),
          const SizedBox(height: 8),
          const Divider(
            height: 1,
            thickness: 1,
            color: Color(0xFFE7E7EA),
          ),
        ],
        if (groups.length == 1 && groups.single.first.groupKey == 'ungrouped')
          ..._configurationRows(
            groups.single,
            enabled: enabled,
            favoriteEnabled: !_savingFavorites,
            isRunning: isRunning,
          )
        else
          for (var i = 0; i < groups.length; i++) ...[
            if (i == 0)
              const SizedBox(height: 8)
            else ...[
              const SizedBox(height: 8),
              const Divider(
                height: 1,
                thickness: 1,
                color: Color(0xFFE7E7EA),
              ),
              const SizedBox(height: 8),
            ],
            _configurationGroup(
              groups[i],
              enabled: enabled,
              favoriteEnabled: !_savingFavorites,
              isRunning: isRunning,
            ),
          ],
      ],
    );
  }

  List<Widget> _configurationRows(
    List<SubscriptionProfile> profiles, {
    required bool enabled,
    required bool favoriteEnabled,
    required bool isRunning,
    double indent = 0,
  }) =>
      [
        for (var i = 0; i < profiles.length; i++) ...[
          SizedBox(height: i == 0 ? 8 : 4),
          Padding(
            padding: EdgeInsets.only(left: indent),
            child: _ServerOption(
              profile: profiles[i],
              selected: identical(profiles[i], _selectedProfile),
              connected: isRunning && identical(profiles[i], _selectedProfile),
              pingMs: _pingResults[profiles[i]],
              pinging: _pingingProfiles.contains(profiles[i]),
              enabled: enabled,
              favorite: _isFavorite(profiles[i]),
              favoriteEnabled: favoriteEnabled,
              onToggleFavorite: () => unawaited(_toggleFavorite(profiles[i])),
              onTap: () => _selectProfile(profiles[i]),
              onPing: () => unawaited(_pingProfile(profiles[i])),
            ),
          ),
        ],
      ];

  Widget _configurationGroup(
    List<SubscriptionProfile> profiles, {
    required bool enabled,
    required bool favoriteEnabled,
    required bool isRunning,
  }) {
    final first = _groupMetadataProfile(profiles);
    final key = first.groupKey;
    final expanded = _expandedServerGroups[key] ?? first.groupExpandedByDefault;
    final colors = Theme.of(context).colorScheme;
    final groupPinging = profiles.any(_pingingProfiles.contains);
    return Column(children: [
      LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return OverflowBox(
            alignment: Alignment.centerLeft,
            minWidth: width,
            maxWidth: width + 8,
            fit: OverflowBoxFit.deferToChild,
            child: Transform.translate(
              offset: const Offset(-8, 0),
              child: SizedBox(
                width: width + 8,
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    splashFactory: NoSplash.splashFactory,
                    mouseCursor: SystemMouseCursors.click,
                    overlayColor: WidgetStateProperty.resolveWith((states) {
                      if (states.contains(WidgetState.pressed)) {
                        return colors.primary.withValues(alpha: 0.08);
                      }
                      if (states.contains(WidgetState.hovered)) {
                        return colors.onSurface.withValues(alpha: 0.045);
                      }
                      if (states.contains(WidgetState.focused)) {
                        return colors.primary.withValues(alpha: 0.05);
                      }
                      return Colors.transparent;
                    }),
                    onTap: () =>
                        setState(() => _expandedServerGroups[key] = !expanded),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 6),
                      child: Row(children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(first.groupName,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodyMedium
                                      ?.copyWith(fontWeight: FontWeight.w600)),
                              if (first.groupDescription != null)
                                Text(first.groupDescription!,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style:
                                        Theme.of(context).textTheme.bodySmall),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Проверить серверы категории',
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints.tightFor(
                              width: 32, height: 32),
                          padding: EdgeInsets.zero,
                          onPressed: enabled && !groupPinging
                              ? () => unawaited(_pingGroupProfiles(profiles))
                              : null,
                          icon: groupPinging
                              ? const _PingLoadingIcon(size: 16)
                              : const Icon(Icons.speed_rounded, size: 18),
                        ),
                        const SizedBox(width: 6),
                        Icon(expanded ? Icons.expand_less : Icons.expand_more,
                            size: 18,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
      if (expanded)
        ..._configurationRows(
          profiles,
          enabled: enabled,
          favoriteEnabled: favoriteEnabled,
          isRunning: isRunning,
          indent: 0,
        ),
    ]);
  }

  Widget _buildSubscriptionsView({required bool canUpdate}) {
    final sets = _subscriptionSets();
    final canModify = canUpdate && !_loadingExternal;
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 20, 8, 72),
      children: [
        Row(children: [
          Expanded(
              child: Text('Подписки',
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w800))),
          IconButton(
            tooltip: 'Обновить подписки',
            onPressed: canModify ? _updateSubscriptions : null,
            icon: _refreshingSubscriptions
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh_rounded),
          ),
        ]),
        const SizedBox(height: 8),
        if (sets.isEmpty)
          Card(
              child: Padding(
            padding: const EdgeInsets.all(18),
            child: Text(_primarySubscriptionError ??
                'Добавьте подписку, чтобы загрузить конфигурации.'),
          )),
        for (final entry in sets.entries)
          _subscriptionCard(entry.key, entry.value,
              selected: entry.key == _activeSubscriptionKey,
              enabled: canModify),
        if (_subscriptionError != null)
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(_subscriptionError!,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error))),
        const SizedBox(height: 10),
        _buildExternalSubscriptionManager(canModify: canModify),
      ],
    );
  }

  Widget _subscriptionCard(
    String key,
    List<SubscriptionProfile> profiles, {
    required bool selected,
    required bool enabled,
  }) {
    final metadata = _metadataFor(key);
    final own = key == 'oksana';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: enabled ? () => unawaited(_selectSubscription(key)) : null,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(own ? Icons.shield_outlined : Icons.link_rounded,
                  color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(metadata.title ?? _subscriptionName(key),
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(own ? 'Наша подписка' : 'Сторонняя подписка',
                        style: Theme.of(context).textTheme.bodySmall),
                  ])),
              if (selected)
                Icon(Icons.check_circle_rounded,
                    color: Theme.of(context).colorScheme.primary),
              if (!selected) const Icon(Icons.chevron_right_rounded),
            ]),
            if (own ||
                metadata.uploadBytes != null ||
                metadata.downloadBytes != null ||
                metadata.totalBytes != null ||
                metadata.devicesUsed != null ||
                metadata.devicesLimit != null ||
                metadata.expiresAt != null) ...[
              const Divider(height: 20),
              _subscriptionMetadataLines(
                metadata,
                isPrimarySubscription: own,
              ),
            ],
            if (profiles.isEmpty)
              const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('Нет доступных конфигураций')),
          ]),
        ),
      ),
    );
  }

  Widget _buildSelectedSubscriptionPanel({
    required bool canRefresh,
    required bool configurationsEnabled,
    required bool isRunning,
  }) {
    final theme = Theme.of(context);
    final metadata = _metadataFor(_activeSubscriptionKey);
    String subscriptionTitle(String key) {
      if (key == 'oksana' && widget.authToken != null) {
        return 'Подписка Oksana VPN';
      }
      return _metadataFor(key).title ?? _subscriptionName(key);
    }

    final activeName = _activeSubscriptionKey == null
        ? 'Нет выбранной подписки'
        : subscriptionTitle(_activeSubscriptionKey!);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    activeName,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: _refreshingSubscriptions
                      ? 'Обновляем подписки…'
                      : 'Обновить подписки',
                  visualDensity: VisualDensity.compact,
                  constraints:
                      const BoxConstraints.tightFor(width: 36, height: 36),
                  padding: EdgeInsets.zero,
                  onPressed: _refreshingSubscriptions || !canRefresh
                      ? null
                      : _updateSubscriptions,
                  icon: _refreshingSubscriptions
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: _pingingAll
                      ? 'Проверяем все подключения…'
                      : 'Проверить доступность всех серверов через профиль',
                  visualDensity: VisualDensity.compact,
                  constraints:
                      const BoxConstraints.tightFor(width: 36, height: 36),
                  padding: EdgeInsets.zero,
                  onPressed: _profiles.isEmpty || _pingingAll || _pinging
                      ? null
                      : () => unawaited(_pingAllProfiles()),
                  icon: _pingingAll
                      ? const _PingLoadingIcon(size: 18)
                      : const Icon(Icons.speed_rounded),
                ),
                const SizedBox(width: 4),
                PopupMenuButton<String>(
                  tooltip: 'Ещё',
                  borderRadius: BorderRadius.circular(20),
                  child: const SizedBox(
                    width: 36,
                    height: 36,
                    child: Icon(Icons.more_vert_rounded, size: 20),
                  ),
                  onSelected: (value) {
                    if (value == 'subscriptions') {
                      setState(() => _selectedTab = 1);
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem<String>(
                      value: 'subscriptions',
                      child: Row(
                        children: [
                          Icon(Icons.credit_card_outlined, size: 18),
                          SizedBox(width: 10),
                          Text('Управлять подписками'),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
            if (_activeSubscriptionKey == 'oksana' ||
                metadata.updateInterval != null ||
                metadata.webPageUrl != null ||
                metadata.announceUrl != null ||
                metadata.telegramUrl != null ||
                metadata.supportUrl != null ||
                metadata.devicesLimit != null ||
                metadata.devicesUsed != null ||
                metadata.totalBytes != null ||
                metadata.expiresAt != null ||
                metadata.uploadBytes != null ||
                metadata.downloadBytes != null) ...[
              const SizedBox(height: 10),
              _subscriptionMetadataLines(
                metadata,
                isPrimarySubscription: _activeSubscriptionKey == 'oksana',
              ),
            ],
            if (_subscriptionError != null) ...[
              const SizedBox(height: 8),
              Text(_subscriptionError!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 8),
            const Divider(height: 1),
            _buildConfigurationList(
              enabled: configurationsEnabled,
              isRunning: isRunning,
            ),
          ],
        ),
      ),
    );
  }

  Widget _subscriptionMetadataLines(
    SubscriptionMetadata metadata, {
    bool isPrimarySubscription = false,
  }) {
    final hasTrafficData = metadata.uploadBytes != null ||
        metadata.downloadBytes != null ||
        metadata.totalBytes != null;
    final details = <Widget>[];
    final links = <Widget>[];
    if (metadata.expiresAt != null && metadata.expiresAt! > 0) {
      final date = DateTime.fromMillisecondsSinceEpoch(
        metadata.expiresAt! * 1000,
      ).toLocal();
      details.add(_metadataChip(
        Icons.event_available_rounded,
        'Действует до',
        '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}',
      ));
    }
    if (metadata.devicesLimit != null || metadata.devicesUsed != null) {
      details.add(_metadataChip(
        Icons.devices_rounded,
        'Устройства',
        '${metadata.devicesUsed ?? 0}/${metadata.devicesLimit ?? '∞'}',
      ));
    }
    if (metadata.refreshInterval != null) {
      details.add(_metadataChip(
        Icons.autorenew_rounded,
        'Автообновление',
        '${metadata.refreshInterval!.inHours} ч',
      ));
    } else if (metadata.updateInterval != null) {
      details.add(_metadataChip(
        Icons.autorenew_rounded,
        'Интервал обновления',
        metadata.updateInterval!,
      ));
    }
    if (metadata.webPageUrl != null) {
      links.add(_metadataLink(
        icon: Icons.language_rounded,
        label: 'Сайт',
        url: metadata.webPageUrl!,
      ));
    }
    final telegramUrl = metadata.telegramUrl ??
        (isPrimarySubscription ? 'https://t.me/OksanaVpnBot' : null);
    if (telegramUrl != null) {
      links.add(_metadataLink(
        icon: Icons.send_rounded,
        label: 'Бот',
        url: telegramUrl,
      ));
    }
    if (metadata.announceUrl != null) {
      links.add(_metadataLink(
        icon: Icons.campaign_outlined,
        label: 'Канал',
        url: metadata.announceUrl!,
      ));
    }
    if (metadata.supportUrl != null) {
      links.add(_metadataLink(
        icon: Icons.support_agent_rounded,
        label: 'Помощь',
        url: metadata.supportUrl!,
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasTrafficData) _trafficUsage(metadata),
        if (details.isNotEmpty) ...[
          if (hasTrafficData) const SizedBox(height: 6),
          Wrap(
            spacing: 14,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: details,
          ),
        ],
        if (links.isNotEmpty) ...[
          if (hasTrafficData || details.isNotEmpty) const SizedBox(height: 6),
          Wrap(
            spacing: 7,
            runSpacing: 5,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: links,
          ),
        ],
      ],
    );
  }

  Widget _trafficUsage(SubscriptionMetadata metadata) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final uploaded = metadata.uploadBytes ?? 0;
    final downloaded = metadata.downloadBytes ?? 0;
    final used = uploaded + downloaded;
    final limit = metadata.totalBytes;
    final hasLimit = limit != null && limit > 0;
    final limitLabel = hasLimit ? _formatBytes(limit!) : '∞';
    final ratio = hasLimit ? (used / limit!).clamp(0.0, 1.0).toDouble() : 0.0;

    return Tooltip(
      message:
          'Отправлено: ${_formatBytes(uploaded)}\nПолучено: ${_formatBytes(downloaded)}',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          height: 21,
          child: LayoutBuilder(
            builder: (context, constraints) => Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: colors.surfaceContainerHighest),
                if (ratio > 0)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox(
                      width: constraints.maxWidth * ratio,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: [
                              colors.onSurfaceVariant.withValues(alpha: 0.45),
                              colors.onSurfaceVariant.withValues(alpha: 0.2),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                Center(
                  child: Text(
                    '${_formatBytes(used)} / $limitLabel',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colors.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _metadataChip(IconData icon, String label, String value) {
    return Tooltip(
      message: label,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 6),
            Text(value, style: Theme.of(context).textTheme.labelMedium),
          ],
        ),
      ),
    );
  }

  Widget _metadataLink({
    required IconData icon,
    required String label,
    required String url,
  }) {
    final colors = Theme.of(context).colorScheme;
    return OutlinedButton(
      onPressed: () => unawaited(_openExternalLink(url)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 4),
          Text(
            label,
            style:
                Theme.of(context).textTheme.labelMedium?.copyWith(fontSize: 12),
          ),
        ],
      ),
      style: OutlinedButton.styleFrom(
        foregroundColor: colors.primary,
        side: BorderSide(color: colors.primary.withValues(alpha: 0.7)),
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        minimumSize: Size.zero,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes Б';
    const units = ['КБ', 'МБ', 'ГБ', 'ТБ'];
    var value = bytes / 1024;
    var unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex++;
    }
    return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[unitIndex]}';
  }

  Widget _buildExternalSubscriptionManager({required bool canModify}) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Добавить подписку',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            for (var i = 0; i < _externalUrls.length; i++)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.link_rounded),
                title: Text(
                  _externalMetadataByUrl[_externalUrls[i]]?.title ??
                      'Сторонняя подписка ${i + 1}',
                ),
                trailing: IconButton(
                  tooltip: 'Удалить подписку',
                  onPressed: !canModify || _loadingExternal
                      ? null
                      : () => unawaited(
                          _removeExternalSubscription(_externalUrls[i])),
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              ),
            TextField(
              controller: _externalUrlController,
              enabled: canModify && !_loadingExternal,
              autocorrect: false,
              keyboardType: TextInputType.url,
              textCapitalization: TextCapitalization.none,
              decoration: const InputDecoration(
                labelText: 'HTTPS-ссылка подписки',
                prefixIcon: Icon(Icons.add_link_rounded),
              ),
            ),
            if (_externalError != null) ...[
              const SizedBox(height: 8),
              Text(_externalError!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: canModify && !_loadingExternal
                  ? _addExternalSubscription
                  : null,
              icon: _loadingExternal
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add_rounded),
              label:
                  Text(_loadingExternal ? 'Загружаем…' : 'Добавить подписку'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileView({required bool canUpdate}) {
    final theme = Theme.of(context);
    final account = _accountProfile;
    final expiry =
        account?.subscriptionExpiresAt ?? _metadataExpiry(_primaryMetadata);
    final isActive = account?.hasActiveAccess ??
        (expiry != null && expiry.isAfter(DateTime.now()));
    final colors = theme.colorScheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 20, 8, 72),
      children: [
        if (widget.authToken != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Подписка',
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        tooltip: _refreshingAccount
                            ? 'Обновляем данные аккаунта…'
                            : 'Обновить данные аккаунта',
                        onPressed: _refreshingAccount ? null : _refreshAccount,
                        icon: _refreshingAccount
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh_rounded),
                      ),
                    ],
                  ),
                  if (account == null) ...[
                    if (_refreshingAccount)
                      const LinearProgressIndicator()
                    else ...[
                      Text(
                        _accountError ?? 'Данные подписки ещё не загружены.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _accountError == null
                              ? colors.onSurfaceVariant
                              : colors.error,
                        ),
                      ),
                      if (_accountError != null)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: _refreshAccount,
                            icon: const Icon(Icons.refresh_rounded),
                            label: const Text('Повторить'),
                          ),
                        ),
                    ],
                  ] else ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isActive
                            ? colors.primaryContainer
                            : colors.errorContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            isActive
                                ? Icons.check_circle_rounded
                                : Icons.error_outline_rounded,
                            color: isActive
                                ? colors.onPrimaryContainer
                                : colors.onErrorContainer,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  isActive
                                      ? 'Подписка активна'
                                      : 'Подписка не активна',
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    color: isActive
                                        ? colors.onPrimaryContainer
                                        : colors.onErrorContainer,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                Text(
                                  expiry == null
                                      ? (isActive
                                          ? 'Срок окончания не указан.'
                                          : 'Оформите или продлите подписку, чтобы получить доступ.')
                                      : '${isActive ? 'Действует до' : 'Дата окончания'} ${_formatAccountDate(expiry)}',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: isActive
                                        ? colors.onPrimaryContainer
                                        : colors.onErrorContainer,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final width = (constraints.maxWidth - 8) / 2;
                        final metrics = <(IconData, String, String)>[
                          (
                            Icons.account_balance_wallet_outlined,
                            'Баланс',
                            _formatRubles(account.balance),
                          ),
                          (
                            Icons.warning_amber_rounded,
                            'Долг',
                            _formatRubles(account.debt),
                          ),
                          (
                            Icons.percent_rounded,
                            'Скидка',
                            '${_formatNumber(account.totalDiscountPercent)}%',
                          ),
                          if (account.hasMoneyForNextSubscriptionMonth != null)
                            (
                              Icons.event_available_rounded,
                              'На следующее продление',
                              account.hasMoneyForNextSubscriptionMonth!
                                  ? 'Хватит средств'
                                  : 'Может не хватить',
                            ),
                        ];
                        return Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final metric in metrics)
                              SizedBox(
                                width: width,
                                child: _accountMetric(
                                  metric.$1,
                                  metric.$2,
                                  metric.$3,
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                    if (_hasSubscriptionTraffic(_primaryMetadata)) ...[
                      const SizedBox(height: 12),
                      const Divider(height: 1),
                      const SizedBox(height: 10),
                      Text(
                        'Использование трафика',
                        style: theme.textTheme.labelLarge,
                      ),
                      const SizedBox(height: 8),
                      _trafficUsage(_primaryMetadata),
                    ],
                    if (_primaryMetadata.devicesLimit != null ||
                        _primaryMetadata.devicesUsed != null) ...[
                      const SizedBox(height: 8),
                      _metadataChip(
                        Icons.devices_rounded,
                        'Устройства',
                        '${_primaryMetadata.devicesUsed ?? 0}/${_primaryMetadata.devicesLimit ?? '∞'}',
                      ),
                    ],
                    if (account.hasMoneyForNextSubscriptionMonth == false &&
                        isActive) ...[
                      const SizedBox(height: 10),
                      _accountNotice(
                        Icons.info_outline_rounded,
                        'На следующее продление может не хватить средств. Лучше пополнить баланс заранее.',
                      ),
                    ],
                    if (_accountError != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _accountError!,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: colors.error),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Профиль',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                if (widget.authToken == null) ...[
                  const Text(
                      'Войдите, чтобы посмотреть статус подписки и данные аккаунта.'),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: canUpdate
                        ? () =>
                            Navigator.of(context).pushReplacement<void, void>(
                              MaterialPageRoute<void>(
                                builder: (_) => SubscriptionScreen(
                                  themeMode: _selectedThemeMode,
                                  onThemeModeChanged: widget.onThemeModeChanged,
                                ),
                              ),
                            )
                        : null,
                    icon: const Icon(Icons.login_rounded),
                    label: const Text('Войти'),
                  ),
                ] else ...[
                  Text(
                    account?.name.isNotEmpty == true
                        ? account!.name
                        : widget.accountName.isEmpty
                            ? 'Вход выполнен'
                            : widget.accountName,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  if (account?.telegram != null) ...[
                    const SizedBox(height: 8),
                    _accountDetail(
                      Icons.alternate_email_rounded,
                      'Telegram',
                      account!.telegram!.startsWith('@')
                          ? account.telegram!
                          : '@${account.telegram}',
                    ),
                  ],
                  if (account?.telegramId != null) ...[
                    const SizedBox(height: 6),
                    _accountDetail(
                      Icons.tag_rounded,
                      'Telegram ID',
                      account!.telegramId!,
                    ),
                  ],
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: canUpdate ? _logout : null,
                    icon: const Icon(Icons.logout_rounded),
                    label: const Text('Выйти из аккаунта'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _accountMetric(IconData icon, String label, String value) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: colors.primary),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
                Text(
                  value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _accountDetail(IconData icon, String label, String value) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 17, color: colors.onSurfaceVariant),
        const SizedBox(width: 8),
        Text('$label: ', style: Theme.of(context).textTheme.bodySmall),
        Expanded(
          child: Text(
            value,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
        ),
      ],
    );
  }

  Widget _accountNotice(IconData icon, String message) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: colors.tertiaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: colors.onTertiaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onTertiaryContainer,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  DateTime? _metadataExpiry(SubscriptionMetadata metadata) {
    final expiresAt = metadata.expiresAt;
    if (expiresAt == null || expiresAt <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000).toLocal();
  }

  bool _hasSubscriptionTraffic(SubscriptionMetadata metadata) =>
      metadata.uploadBytes != null ||
      metadata.downloadBytes != null ||
      metadata.totalBytes != null;

  String _formatAccountDate(DateTime date) {
    const months = [
      'января',
      'февраля',
      'марта',
      'апреля',
      'мая',
      'июня',
      'июля',
      'августа',
      'сентября',
      'октября',
      'ноября',
      'декабря',
    ];
    final local = date.toLocal();
    return '${local.day} ${months[local.month - 1]} ${local.year}';
  }

  String _formatRubles(num value) {
    final amount = value % 1 == 0
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(2).replaceAll('.', ',');
    return '$amount ₽';
  }

  String _formatNumber(num value) => value % 1 == 0
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1).replaceAll('.', ',');

  String _connectionStatus(VpnRuntimeSnapshot state) {
    if (_restartingForSettings) return 'Применяем настройки…';
    if (_switchingServer) return 'Переключаем сервер…';
    return switch (state.phase) {
      VpnRuntimePhase.starting =>
        _selectedMode == VpnMode.tun ? 'Подключаем VPN…' : 'Запускаем proxy…',
      VpnRuntimePhase.running => _selectedMode == VpnMode.tun
          ? 'VPN включён'
          : state.localProxyPorts.isEmpty
              ? 'Proxy запущен'
              : 'Proxy запущен · порты ${state.localProxyPorts.join(', ')}',
      VpnRuntimePhase.stopping => 'Отключаем…',
      VpnRuntimePhase.error => 'Не удалось подключиться',
      VpnRuntimePhase.disconnected => 'Не подключено',
    };
  }
}

class _CompactNavItem extends StatefulWidget {
  const _CompactNavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_CompactNavItem> createState() => _CompactNavItemState();
}

class _CompactNavItemState extends State<_CompactNavItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final emphasized = widget.selected || _hovered;
    final foreground = widget.selected
        ? colors.primary
        : _hovered
            ? colors.onSurface
            : colors.onSurfaceVariant;

    return Semantics(
      label: widget.label,
      button: true,
      selected: widget.selected,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          onHover: (hovered) {
            if (_hovered != hovered) setState(() => _hovered = hovered);
          },
          mouseCursor: SystemMouseCursors.click,
          borderRadius: BorderRadius.circular(20),
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          hoverColor: Colors.transparent,
          focusColor: Colors.transparent,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              border: Border.all(
                color: !emphasized
                    ? Colors.transparent
                    : widget.selected
                        ? colors.primary
                        : colors.outlineVariant,
              ),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  widget.selected ? widget.selectedIcon : widget.icon,
                  size: 18,
                  color: foreground,
                ),
                const SizedBox(width: 6),
                Text(
                  widget.label,
                  maxLines: 1,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: foreground,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PowerControl extends StatelessWidget {
  const _PowerControl({
    required this.phase,
    required this.enabled,
    required this.onPressed,
  });

  final VpnRuntimePhase phase;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final running = phase == VpnRuntimePhase.running;
    final busy =
        phase == VpnRuntimePhase.starting || phase == VpnRuntimePhase.stopping;
    final active = running || phase == VpnRuntimePhase.stopping;
    final color = active ? const Color(0xFF16A36A) : colors.primary;
    final isFilled = active || phase == VpnRuntimePhase.starting;

    return SizedBox.square(
      dimension: 116,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: running ? 0.34 : 0.1),
              blurRadius: running ? 38 : 20,
              spreadRadius: running ? 3 : 0,
            ),
          ],
        ),
        child: IconButton(
          onPressed: enabled ? onPressed : null,
          icon: busy
              ? SizedBox(
                  width: 38,
                  height: 38,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: isFilled ? Colors.white : colors.primary,
                  ),
                )
              : Icon(
                  running
                      ? Icons.power_settings_new_rounded
                      : Icons.play_arrow_rounded,
                  size: 50,
                ),
          style: IconButton.styleFrom(
            fixedSize: const Size(116, 116),
            backgroundColor: isFilled ? color : Colors.transparent,
            disabledBackgroundColor:
                isFilled ? color.withValues(alpha: 0.65) : Colors.transparent,
            foregroundColor: isFilled ? Colors.white : colors.primary,
            disabledForegroundColor: isFilled
                ? Colors.white70
                : colors.primary.withValues(alpha: 0.6),
            side: BorderSide(color: color, width: 2),
            shape: const CircleBorder(),
          ),
        ),
      ),
    );
  }
}

class _PingLoadingIcon extends StatelessWidget {
  const _PingLoadingIcon({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: SizedBox.square(
          dimension: size,
          child: const CircularProgressIndicator(strokeWidth: 2),
        ),
      );
}

class _ServerOption extends StatelessWidget {
  const _ServerOption({
    required this.profile,
    required this.selected,
    required this.connected,
    required this.pingMs,
    required this.pinging,
    required this.enabled,
    required this.favorite,
    required this.favoriteEnabled,
    required this.onTap,
    required this.onPing,
    required this.onToggleFavorite,
  });

  final SubscriptionProfile profile;
  final bool selected;
  final bool connected;
  final int? pingMs;
  final bool pinging;
  final bool enabled;
  final bool favorite;
  final bool favoriteEnabled;
  final VoidCallback onTap;
  final VoidCallback onPing;
  final VoidCallback onToggleFavorite;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final leadingEmoji = _leadingEmoji(profile.name);
    final displayName = leadingEmoji == null
        ? profile.name
        : profile.name.trimLeft().characters.skip(1).toString().trimLeft();
    final title = displayName.isEmpty ? profile.name : displayName;

    return Material(
      color: selected
          ? colors.primary.withValues(alpha: 0.16)
          : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: selected
            ? BorderSide(color: colors.primary.withValues(alpha: 0.7))
            : BorderSide.none,
      ),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            children: [
              SizedBox(
                width: 24,
                child: leadingEmoji == null
                    ? Icon(
                        _metadataIcon(profile.icon, Icons.public_rounded),
                        size: 20,
                        color:
                            selected ? colors.primary : colors.onSurfaceVariant,
                      )
                    : Text(
                        leadingEmoji,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium,
                      ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                    if (profile.description != null)
                      Text(profile.description!,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant)),
                  ],
                ),
              ),
              if (connected)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    'Подключён',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: const Color(0xFF16A36A),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              if (!pinging && pingMs != null)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Text(
                    pingMs! < 0 ? '—' : '${pingMs!} мс',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color:
                          pingMs! < 0 ? colors.error : colors.onSurfaceVariant,
                    ),
                  ),
                ),
              IconButton(
                tooltip: 'Проверить доступность через профиль',
                visualDensity: VisualDensity.compact,
                onPressed: enabled && !pinging ? onPing : null,
                icon: pinging
                    ? const _PingLoadingIcon(size: 16)
                    : const Icon(Icons.speed_rounded, size: 18),
              ),
              IconButton(
                tooltip:
                    favorite ? 'Убрать из избранного' : 'Добавить в избранное',
                visualDensity: VisualDensity.compact,
                onPressed: favoriteEnabled ? onToggleFavorite : null,
                icon: Icon(
                  favorite ? Icons.star_rounded : Icons.star_outline_rounded,
                  size: 19,
                  color: favorite ? colors.primary : colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String? _leadingEmoji(String name) {
  final trimmed = name.trimLeft();
  if (trimmed.isEmpty) return null;

  final first = trimmed.characters.first;
  final codePoints = first.runes.toList(growable: false);
  final hasEmoji = codePoints.any(_isEmojiCodePoint) ||
      codePoints.contains(0x20E3); // keycap emoji
  return hasEmoji ? first : null;
}

bool _isEmojiCodePoint(int codePoint) {
  return (codePoint >= 0x1F000 && codePoint <= 0x1FAFF) ||
      (codePoint >= 0x2600 && codePoint <= 0x27FF) ||
      (codePoint >= 0x2300 && codePoint <= 0x23FF) ||
      (codePoint >= 0x2B00 && codePoint <= 0x2BFF) ||
      const {
        0x00A9,
        0x00AE,
        0x203C,
        0x2049,
        0x2122,
        0x2139,
        0x3030,
        0x303D,
        0x3297,
        0x3299,
      }.contains(codePoint);
}

IconData _metadataIcon(String? value, IconData fallback) => switch (value) {
      'bolt' || 'automatic' => Icons.bolt_rounded,
      'wifi' => Icons.wifi_rounded,
      'cellular' || 'signal' => Icons.signal_cellular_alt_rounded,
      'layers' || 'servers' => Icons.layers_outlined,
      'link' || 'bypass' => Icons.link_rounded,
      'chat' || 'messengers' => Icons.chat_bubble_outline_rounded,
      'shield' => Icons.shield_outlined,
      _ => fallback,
    };
