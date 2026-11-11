import 'dart:async';

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
  bool _restoring = true;
  bool _loading = false;
  bool _showUuid = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _restoreSavedUuid();
  }

  Future<void> _restoreSavedUuid() async {
    try {
      final uuid = await _subscriptionStore.readUuid();
      if (!mounted) return;
      if (uuid == null || _uuidController.text.isNotEmpty) {
        setState(() => _restoring = false);
        return;
      }

      _uuidController.value = TextEditingValue(
        text: uuid,
        selection: TextSelection.collapsed(offset: uuid.length),
      );
      setState(() => _restoring = false);
      await _loadSubscription(uuid: uuid, saveUuid: false);
    } catch (_) {
      if (mounted) {
        setState(() {
          _restoring = false;
          _error = 'Не удалось восстановить сохранённый код подписки.';
        });
      }
    }
  }

  @override
  void dispose() {
    _uuidController.dispose();
    _api.close();
    super.dispose();
  }

  Future<void> _loadSubscription({String? uuid, bool saveUuid = true}) async {
    FocusScope.of(context).unfocus();
    String? storageWarning;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final value = (uuid ?? _uuidController.text).trim();
      final profiles = await _api.fetchProfiles(value);
      if (saveUuid && SubscriptionApi.isValidUuid(value)) {
        try {
          await _subscriptionStore.saveUuid(value);
        } catch (_) {
          storageWarning =
              'Код не удалось сохранить на устройстве. Подписка всё равно будет загружена.';
        }
      }

      if (!mounted) return;
      if (storageWarning != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(storageWarning)),
        );
      }

      unawaited(
        Navigator.of(context).pushReplacement<void, void>(
          MaterialPageRoute<void>(
            builder: (_) => VpnHomeScreen(
              profiles: profiles,
              subscriptionUuid: value,
            ),
          ),
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
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Подписка',
                                    style:
                                        theme.textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'О хранении кода',
                                  onPressed: _showUuidInfo,
                                  icon: const Icon(Icons.info_outline_rounded),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: _uuidController,
                              enabled: !_loading,
                              autocorrect: false,
                              enableSuggestions: false,
                              obscureText: !_showUuid,
                              keyboardType: TextInputType.text,
                              textCapitalization: TextCapitalization.none,
                              onSubmitted: (_) async {
                                if (!_loading) await _loadSubscription();
                              },
                              decoration: InputDecoration(
                                labelText: 'UUID подписки',
                                prefixIcon: const Icon(Icons.key_rounded),
                                suffixIcon: IconButton(
                                  tooltip:
                                      _showUuid ? 'Скрыть код' : 'Показать код',
                                  onPressed: () =>
                                      setState(() => _showUuid = !_showUuid),
                                  icon: Icon(_showUuid
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
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showUuidInfo() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Код подписки'),
        content: const Text('Код подписки сохраняется на устройстве.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Понятно'),
          ),
        ],
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
