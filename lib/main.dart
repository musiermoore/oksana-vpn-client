import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'models/subscription_metadata.dart';
import 'models/subscription_profile.dart';
import 'screens/vpn_home_screen.dart';
import 'screens/subscription_screen.dart';
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
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  final _authApi = AuthApi();
  final _authStore = const AuthStore();
  final Set<String> _handledTickets = {};
  bool _ready = false;
  bool _authenticating = false;

  @override
  void initState() {
    super.initState();
    _deepLinkChannel.setMethodCallHandler(_handleNativeCall);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ready = true;
      unawaited(_deepLinkChannel.invokeMethod<void>('ready'));
    });
  }

  @override
  void dispose() {
    _deepLinkChannel.setMethodCallHandler(null);
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
            authToken: token,
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
      themeMode: ThemeMode.system,
      home: const SubscriptionScreen(),
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
