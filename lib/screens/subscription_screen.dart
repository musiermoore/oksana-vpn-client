import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/subscription_metadata.dart';
import '../models/subscription_profile.dart';
import '../services/auth_api.dart';
import '../services/auth_store.dart';
import '../services/subscription_api.dart';
import '../widgets/brand_header.dart';
import 'vpn_home_screen.dart';

class SubscriptionScreen extends StatefulWidget {
  const SubscriptionScreen({super.key});

  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

class _SubscriptionScreenState extends State<SubscriptionScreen> {
  static const _deepLinkChannel = MethodChannel('oksanavpn/deep_links');
  final _loginController = TextEditingController();
  final _passwordController = TextEditingController();
  final _authApi = AuthApi();
  final _api = SubscriptionApi();
  final _authStore = const AuthStore();
  bool _restoring = true;
  bool _loading = false;
  bool _showPassword = false;
  bool _openingTelegram = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  Future<void> _restoreSession() async {
    try {
      final token = await _authStore.readToken();
      if (!mounted) return;
      if (token == null || token.isEmpty) {
        setState(() => _restoring = false);
        return;
      }
      setState(() => _loading = true);
      await _continueWithToken(token);
    } catch (_) {
      if (mounted) {
        try {
          await _authStore.clear();
        } catch (_) {
          // Continue to the sign-in form if Keychain is temporarily unavailable.
        }
        setState(() {
          _restoring = false;
          _loading = false;
          _error = 'Сессия не восстановлена. Войдите снова.';
        });
      }
    }
  }

  @override
  void dispose() {
    _loginController.dispose();
    _passwordController.dispose();
    _authApi.close();
    _api.close();
    super.dispose();
  }

  Future<void> _login() async {
    FocusScope.of(context).unfocus();
    if (_loginController.text.trim().isEmpty ||
        _passwordController.text.isEmpty) {
      setState(() => _error = 'Введите логин и пароль.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final token =
          await _authApi.login(_loginController.text, _passwordController.text);
      await _continueWithToken(token, persist: true);
    } on AuthApiException catch (error) {
      if (mounted) {
        setState(() => _error = error.message);
      }
    } on SubscriptionApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Не удалось безопасно сохранить сессию.');
      }
    } finally {
      if (mounted && _restoring) setState(() => _restoring = false);
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _startTelegramLogin() async {
    if (_loading || _openingTelegram) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _openingTelegram = true;
      _error = null;
    });
    try {
      final opened = await _deepLinkChannel.invokeMethod<bool>(
        'openTelegramLogin',
        'https://public.oksana1984.ru/login?desktop=1',
      );
      if (opened != true) {
        throw PlatformException(code: 'browser_unavailable');
      }
    } on PlatformException {
      if (mounted) {
        setState(
            () => _error = 'Не удалось открыть страницу входа в браузере.');
      }
    } finally {
      if (mounted) setState(() => _openingTelegram = false);
    }
  }

  void _openSubscriptionsWithoutLogin() {
    Navigator.of(context).pushReplacement<void, void>(
      MaterialPageRoute<void>(
        builder: (_) => const VpnHomeScreen(
          profiles: [],
          accountName: '',
          initialTab: 0,
        ),
      ),
    );
  }

  Future<void> _continueWithToken(String token, {bool persist = false}) async {
    final profile = await _authApi.fetchProfile(token);
    var profiles = <SubscriptionProfile>[];
    var primaryMetadata = const SubscriptionMetadata();
    String? primarySubscriptionError;
    try {
      final loaded = await _api.fetchProfiles(profile.uuid);
      profiles = loaded.profiles;
      primaryMetadata = loaded.metadata;
    } on SubscriptionApiException catch (error) {
      primarySubscriptionError = error.message;
    }
    if (!mounted) return;
    if (persist) await _authStore.saveToken(token);
    if (!mounted) return;
    _restoring = false;
    unawaited(Navigator.of(context).pushReplacement<void, void>(
      MaterialPageRoute<void>(
        builder: (_) => VpnHomeScreen(
          profiles: profiles,
          accountName: profile.name,
          authToken: token,
          primarySubscriptionError: primarySubscriptionError,
          primaryMetadata: primaryMetadata,
        ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const BrandHeader(
                    title: 'Oksana VPN',
                  ),
                  const SizedBox(height: 34),
                  if (_restoring || _loading)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: Column(
                          children: [
                            const SizedBox(
                              width: 26,
                              height: 26,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2.5),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              _restoring
                                  ? 'Проверяем подписку…'
                                  : 'Загружаем подписку…',
                              style: theme.textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Вход',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              controller: _loginController,
                              enabled: !_loading,
                              autocorrect: false,
                              textInputAction: TextInputAction.next,
                              decoration: InputDecoration(
                                labelText: 'Логин',
                                prefixIcon:
                                    const Icon(Icons.person_outline_rounded),
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _passwordController,
                              enabled: !_loading,
                              obscureText: !_showPassword,
                              onSubmitted: (_) {
                                if (!_loading) unawaited(_login());
                              },
                              decoration: InputDecoration(
                                labelText: 'Пароль',
                                prefixIcon:
                                    const Icon(Icons.lock_outline_rounded),
                                suffixIcon: IconButton(
                                  tooltip: _showPassword
                                      ? 'Скрыть пароль'
                                      : 'Показать пароль',
                                  onPressed: () => setState(
                                      () => _showPassword = !_showPassword),
                                  icon: Icon(_showPassword
                                      ? Icons.visibility_off_rounded
                                      : Icons.visibility_rounded),
                                ),
                              ),
                            ),
                            if (_error != null) ...[
                              const SizedBox(height: 14),
                              _InlineMessage(message: _error!),
                            ],
                            const SizedBox(height: 18),
                            FilledButton.icon(
                              onPressed:
                                  _loading || _openingTelegram ? null : _login,
                              icon: _loading
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2, color: Colors.white),
                                    )
                                  : const Icon(Icons.login_rounded),
                              label: Text(_loading ? 'Входим…' : 'Войти'),
                            ),
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                              onPressed: _loading || _openingTelegram
                                  ? null
                                  : _startTelegramLogin,
                              icon: _openingTelegram
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  : const Icon(Icons.send_rounded),
                              label: Text(_openingTelegram
                                  ? 'Открываем Telegram-вход…'
                                  : 'Войти через Telegram'),
                            ),
                            const SizedBox(height: 8),
                            TextButton.icon(
                              onPressed: _loading || _openingTelegram
                                  ? null
                                  : _openSubscriptionsWithoutLogin,
                              icon: const Icon(Icons.person_off_outlined),
                              label: const Text('Открыть подписки без входа'),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InlineMessage extends StatelessWidget {
  const _InlineMessage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: dark ? const Color(0x33FF7272) : const Color(0xFFFFF0F0),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline_rounded,
              color: Color(0xFFEF4444), size: 18),
          const SizedBox(width: 9),
          Expanded(
              child:
                  Text(message, style: Theme.of(context).textTheme.bodySmall)),
        ],
      ),
    );
  }
}
