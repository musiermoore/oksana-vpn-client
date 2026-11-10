import 'package:flutter/material.dart';

import '../services/subscription_api.dart';
import '../services/subscription_store.dart';
import '../widgets/brand_header.dart';
import 'vpn_home_screen.dart';

class SubscriptionScreen extends StatefulWidget {
  const SubscriptionScreen({super.key});

  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

class _SubscriptionScreenState extends State<SubscriptionScreen> {
  final _uuidController = TextEditingController();
  final _api = SubscriptionApi();
  final _subscriptionStore = const SubscriptionStore();
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _restoreSavedUuid();
  }

  Future<void> _restoreSavedUuid() async {
    try {
      final uuid = await _subscriptionStore.readUuid();
      if (!mounted || uuid == null || _uuidController.text.isNotEmpty) return;

      _uuidController.value = TextEditingValue(
        text: uuid,
        selection: TextSelection.collapsed(offset: uuid.length),
      );
    } catch (_) {
      if (mounted) {
        setState(
            () => _error = 'Не удалось прочитать UUID из Связки ключей macOS.');
      }
    }
  }

  @override
  void dispose() {
    _uuidController.dispose();
    _api.close();
    super.dispose();
  }

  Future<void> _loadSubscription() async {
    FocusScope.of(context).unfocus();
    String? storageWarning;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final uuid = _uuidController.text.trim();
      if (SubscriptionApi.isValidUuid(uuid)) {
        try {
          await _subscriptionStore.saveUuid(uuid);
        } catch (_) {
          storageWarning =
              'UUID не удалось сохранить в Связке ключей macOS. Подписка всё равно будет загружена.';
        }
      }

      final profiles = await _api.fetchProfiles(uuid);
      if (!mounted) return;
      if (storageWarning != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(storageWarning)),
        );
      }

      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => VpnHomeScreen(profiles: profiles),
        ),
      );
    } on SubscriptionApiException catch (error) {
      if (mounted) {
        setState(() {
          _error = storageWarning == null
              ? error.message
              : '${error.message}\n$storageWarning';
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const BrandHeader(
                    title: 'Oksana VPN',
                    description: 'Безопасное подключение к вашей подписке.',
                  ),
                  const SizedBox(height: 34),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text('Подключите подписку',
                              style: theme.textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 8),
                          Text(
                            'Введите UUID подписки, чтобы загрузить доступные серверы.',
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                          const SizedBox(height: 22),
                          TextField(
                            controller: _uuidController,
                            enabled: !_loading,
                            autocorrect: false,
                            enableSuggestions: false,
                            keyboardType: TextInputType.text,
                            textCapitalization: TextCapitalization.none,
                            onSubmitted: (_) async {
                              if (!_loading) await _loadSubscription();
                            },
                            decoration: const InputDecoration(
                              labelText: 'UUID подписки',
                              hintText: 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx',
                              prefixIcon: Icon(Icons.key_rounded),
                            ),
                          ),
                          if (_error != null) ...[
                            const SizedBox(height: 14),
                            _InlineMessage(message: _error!),
                          ],
                          const SizedBox(height: 18),
                          FilledButton.icon(
                            onPressed: _loading ? null : _loadSubscription,
                            icon: _loading
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white),
                                  )
                                : const Icon(Icons.arrow_forward_rounded),
                            label: Text(_loading
                                ? 'Загружаем подписку…'
                                : 'Продолжить'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.lock_outline_rounded,
                          size: 15, color: colors.onSurfaceVariant),
                      const SizedBox(width: 7),
                      Text(
                        'После нажатия «Продолжить» UUID сохранится в Связке ключей macOS',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ],
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
