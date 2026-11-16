import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'models/subscription_metadata.dart';
import 'models/subscription_profile.dart';
import 'screens/subscription_screen.dart';
import 'screens/vpn_home_screen.dart';
import 'services/app_settings_store.dart';
import 'services/auth_api.dart';
import 'services/auth_store.dart';
import 'services/subscription_api.dart';

void main() {
  runApp(const OksanaVpnApp());
}

class OksanaVpnApp extends StatefulWidget {
  const OksanaVpnApp({super.key});

  @override
  State<OksanaVpnApp> createState() => _OksanaVpnAppState();
}

class _OksanaVpnAppState extends State<OksanaVpnApp> {
  static const _deepLinkChannel = MethodChannel('oksanavpn/deep_links');
  static const _windowsThemeChannel = MethodChannel('oksanavpn/vpn_runtime');
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  final _authApi = AuthApi();
  final _authStore = const AuthStore();
  final _settingsStore = const AppSettingsStore();
  final Set<String> _handledTickets = {};
  ThemeMode _themeMode = ThemeMode.system;
  Brightness _windowsSystemBrightness = Brightness.light;
  bool _ready = false;
  bool _authenticating = false;

  @override
  void initState() {
    super.initState();
    _deepLinkChannel.setMethodCallHandler(_handleNativeCall);
    if (Platform.isWindows) {
      _windowsSystemBrightness =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
      _windowsThemeChannel.setMethodCallHandler(_handleWindowsThemeCall);
      unawaited(_readWindowsSystemBrightness());
    }
    unawaited(_restoreThemeMode());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ready = true;
      unawaited(_deepLinkChannel.invokeMethod<void>('ready'));
    });
  }

  Future<void> _restoreThemeMode() async {
    try {
      final savedMode = await _settingsStore.readThemeMode();
      if (savedMode != null && mounted) setState(() => _themeMode = savedMode);
    } catch (_) {
      // Keep the system theme if preferences are unavailable.
    }
  }

  void _setThemeMode(ThemeMode mode) {
    setState(() => _themeMode = mode);
    unawaited(_saveThemeMode(mode));
  }

  ThemeMode get _effectiveThemeMode {
    if (!Platform.isWindows || _themeMode != ThemeMode.system) {
      return _themeMode;
    }
    return _windowsSystemBrightness == Brightness.dark
        ? ThemeMode.dark
        : ThemeMode.light;
  }

  Future<void> _readWindowsSystemBrightness() async {
    try {
      _applyWindowsSystemBrightness(
        await _windowsThemeChannel.invokeMethod<String>('getSystemBrightness'),
      );
    } on PlatformException {
      // Leave Flutter's default system brightness in place if unavailable.
    } on MissingPluginException {
      // Non-Windows runners do not register the Windows theme method.
    }
  }

  Future<void> _handleWindowsThemeCall(MethodCall call) async {
    if (call.method == 'systemThemeChanged') {
      _applyWindowsSystemBrightness(call.arguments);
    }
  }

  void _applyWindowsSystemBrightness(Object? value) {
    final brightness = switch (value) {
      'dark' => Brightness.dark,
      'light' => Brightness.light,
      _ => null,
    };
    if (brightness == null || brightness == _windowsSystemBrightness) return;
    if (mounted) setState(() => _windowsSystemBrightness = brightness);
  }

  Future<void> _saveThemeMode(ThemeMode mode) async {
    try {
      await _settingsStore.saveThemeMode(mode);
    } catch (_) {
      // Keep the selected theme for this session if storage is unavailable.
    }
  }

  @override
  void dispose() {
    _deepLinkChannel.setMethodCallHandler(null);
    if (Platform.isWindows) {
      _windowsThemeChannel.setMethodCallHandler(null);
    }
    _authApi.close();
    super.dispose();
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method != 'onDeepLink' || call.arguments is! String) return;
    if (!_ready) return;
    await _completeTelegramLogin(call.arguments as String);
  }

  String? _ticketFromDeepLink(String link) {
    final uri = Uri.tryParse(link);
    if (uri == null ||
        uri.scheme != 'oksanavpn' ||
        uri.host != 'auth' ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.pathSegments.length != 1) {
      return null;
    }
    try {
      final encoded = uri.pathSegments.single;
      final ticket =
          utf8.decode(base64Url.decode(base64Url.normalize(encoded)));
      if (!RegExp(r'^[A-Za-z0-9_-]{32,128}$').hasMatch(ticket)) return null;
      return ticket;
    } on FormatException {
      return null;
    }
  }

  Future<void> _completeTelegramLogin(String link) async {
    final ticket = _ticketFromDeepLink(link);
    if (ticket == null) {
      _showDeepLinkError(
          'Ссылка входа некорректна. Запустите вход через Telegram ещё раз.');
      return;
    }
    if (!_handledTickets.add(ticket)) return;

    setState(() => _authenticating = true);
    final api = SubscriptionApi();
    try {
      final token = await _authApi.exchangeTelegramTicket(ticket);
      final profile = await _authApi.fetchProfile(token);
      var profiles = <SubscriptionProfile>[];
      var primaryMetadata = const SubscriptionMetadata();
      String? primarySubscriptionError;
      try {
        final loaded = await api.fetchProfiles(profile.uuid);
        profiles = loaded.profiles;
        primaryMetadata = loaded.metadata;
      } on SubscriptionApiException catch (error) {
        primarySubscriptionError = error.message;
      }
      await _authStore.saveToken(token);
      if (!mounted) return;
      _navigatorKey.currentState?.pushAndRemoveUntil<void>(
        MaterialPageRoute<void>(
          builder: (_) => VpnHomeScreen(
            profiles: profiles,
            accountName: profile.name,
            themeMode: _themeMode,
            onThemeModeChanged: _setThemeMode,
            authToken: token,
            accountProfile: profile,
            primarySubscriptionError: primarySubscriptionError,
            primaryMetadata: primaryMetadata,
          ),
        ),
        (_) => false,
      );
    } on AuthApiException catch (error) {
      _showDeepLinkError(error.message);
    } on SubscriptionApiException catch (error) {
      _showDeepLinkError(error.message);
    } catch (_) {
      _showDeepLinkError('Не удалось безопасно сохранить сессию.');
    } finally {
      api.close();
      if (mounted) setState(() => _authenticating = false);
    }
  }

  void _showDeepLinkError(String message) {
    _messengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Oksana VPN',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      scaffoldMessengerKey: _messengerKey,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: _effectiveThemeMode,
      home: SubscriptionScreen(
        themeMode: _themeMode,
        onThemeModeChanged: _setThemeMode,
      ),
      builder: (context, child) => Stack(
        children: [
          if (child != null) child,
          if (_authenticating)
            Positioned.fill(
              child: ColoredBox(
                color:
                    Theme.of(context).colorScheme.scrim.withValues(alpha: 0.35),
                child: Center(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 16),
                          Text('Завершаем вход через Telegram…',
                              style: Theme.of(context).textTheme.bodyMedium),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
