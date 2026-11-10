import 'dart:async';

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../models/subscription_profile.dart';
import '../vpn/vpn_runtime.dart';
import '../vpn/vpn_runtime_factory.dart';
import '../widgets/brand_header.dart';

class VpnHomeScreen extends StatefulWidget {
  const VpnHomeScreen({super.key, required this.profiles});

  final List<SubscriptionProfile> profiles;

  @override
  State<VpnHomeScreen> createState() => _VpnHomeScreenState();
}

class _VpnHomeScreenState extends State<VpnHomeScreen> {
  late final VpnRuntime _runtime = createVpnRuntime();
  late SubscriptionProfile _selectedProfile;
  VpnMode _selectedMode = VpnMode.tun;

  @override
  void initState() {
    super.initState();
    _selectedProfile = widget.profiles.first;
  }

  @override
  void dispose() {
    _runtime.dispose();
    super.dispose();
  }

  Future<void> _toggleConnection() async {
    if (_runtime.snapshot.phase == VpnRuntimePhase.running) {
      await _runtime.disconnect();
      return;
    }

    try {
      await _runtime.connect(_selectedProfile, _selectedMode);
    } on VpnRuntimeException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return StreamBuilder<VpnRuntimeSnapshot>(
      stream: _runtime.changes,
      initialData: _runtime.snapshot,
      builder: (context, runtimeSnapshot) {
        final runtimeState = runtimeSnapshot.data ?? _runtime.snapshot;
        final phase = runtimeState.phase;
        final isBusy = phase == VpnRuntimePhase.starting ||
            phase == VpnRuntimePhase.stopping;
        final isRunning = phase == VpnRuntimePhase.running;
        final isError = phase == VpnRuntimePhase.error;

        return Scaffold(
          appBar: AppBar(
            leading: IconButton(
              tooltip: 'Изменить UUID',
              onPressed: isBusy ? null : () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            title: const Text('Подключение'),
            centerTitle: false,
            backgroundColor: Colors.transparent,
          ),
          body: SafeArea(
            top: false,
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(32, 12, 32, 32),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const BrandHeader(
                        title: 'Oksana VPN',
                        description: 'Выберите сервер и режим подключения.',
                      ),
                      const SizedBox(height: 28),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(22),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text('Сервер',
                                  style: theme.textTheme.titleSmall
                                      ?.copyWith(fontWeight: FontWeight.w700)),
                              const SizedBox(height: 10),
                              DropdownButtonFormField<SubscriptionProfile>(
                                initialValue: _selectedProfile,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  prefixIcon: Icon(Icons.public_rounded),
                                ),
                                items: widget.profiles.map((profile) {
                                  return DropdownMenuItem(
                                    value: profile,
                                    child: Text(profile.name,
                                        overflow: TextOverflow.ellipsis),
                                  );
                                }).toList(),
                                onChanged: isRunning || isBusy
                                    ? null
                                    : (profile) {
                                        if (profile != null) {
                                          setState(
                                              () => _selectedProfile = profile);
                                        }
                                      },
                              ),
                              const SizedBox(height: 24),
                              Text('Режим',
                                  style: theme.textTheme.titleSmall
                                      ?.copyWith(fontWeight: FontWeight.w700)),
                              const SizedBox(height: 10),
                              SegmentedButton<VpnMode>(
                                segments: [
                                  const ButtonSegment(
                                    value: VpnMode.proxy,
                                    icon: Icon(Icons.swap_horiz_rounded),
                                    label: Text('Proxy'),
                                  ),
                                  ButtonSegment(
                                    value: VpnMode.tun,
                                    icon: Icon(Icons.route_rounded),
                                    label: Text('TUN'),
                                    enabled: _runtime.supports(VpnMode.tun),
                                  ),
                                ],
                                selected: {_selectedMode},
                                onSelectionChanged: isRunning || isBusy
                                    ? null
                                    : (selection) => setState(
                                        () => _selectedMode = selection.first),
                              ),
                              const SizedBox(height: 16),
                              _ModeNote(
                                icon: _selectedMode == VpnMode.tun
                                    ? Icons.route_rounded
                                    : Icons.info_outline_rounded,
                                text: _selectedMode == VpnMode.tun
                                    ? 'macOS направит системный IP-трафик через VPN. Для установки системного расширения может потребоваться подтверждение в настройках macOS.'
                                    : 'Proxy открывает локальные SOCKS/HTTP порты. Трафик пойдёт через VPN только в программах, использующих системный прокси.',
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      _StatusCard(
                        phase: phase,
                        errorMessage: runtimeState.errorMessage,
                        ports: runtimeState.localProxyPorts,
                        mode: _selectedMode,
                      ),
                      const SizedBox(height: 18),
                      FilledButton.icon(
                        onPressed: isBusy || !_runtime.supports(_selectedMode)
                            ? null
                            : _toggleConnection,
                        icon: isBusy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : Icon(isRunning
                                ? Icons.stop_rounded
                                : Icons.power_settings_new_rounded),
                        label: Text(_buttonLabel(phase)),
                        style: FilledButton.styleFrom(
                          backgroundColor: isRunning
                              ? const Color(0xFFEF4444)
                              : AppTheme.primary,
                        ),
                      ),
                      if (isError && runtimeState.errorMessage != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          runtimeState.errorMessage!,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: colors.error),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  String _buttonLabel(VpnRuntimePhase phase) {
    return switch (phase) {
      VpnRuntimePhase.starting => _selectedMode == VpnMode.tun
          ? 'Подключаем туннель…'
          : 'Запускаем proxy…',
      VpnRuntimePhase.running =>
        _selectedMode == VpnMode.tun ? 'Отключить VPN' : 'Отключить proxy',
      VpnRuntimePhase.stopping => 'Останавливаем…',
      VpnRuntimePhase.error => 'Повторить запуск',
      VpnRuntimePhase.disconnected =>
        _selectedMode == VpnMode.tun ? 'Включить VPN' : 'Включить proxy',
    };
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.phase,
    required this.errorMessage,
    required this.ports,
    required this.mode,
  });

  final VpnRuntimePhase phase;
  final String? errorMessage;
  final List<int> ports;
  final VpnMode mode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running = phase == VpnRuntimePhase.running;
    final starting = phase == VpnRuntimePhase.starting;
    final error = phase == VpnRuntimePhase.error;
    final color = error
        ? theme.colorScheme.error
        : running
            ? const Color(0xFF16A36A)
            : AppTheme.primary;
    final title = errorMessage != null
        ? 'Нужна проверка'
        : starting
            ? (mode == VpnMode.tun
                ? 'Подключение VPN-туннеля'
                : 'Запуск локального proxy')
            : running
                ? (mode == VpnMode.tun
                    ? 'VPN-туннель подключён'
                    : 'Локальный proxy запущен')
                : (mode == VpnMode.tun ? 'VPN выключен' : 'Proxy выключен');

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(
                error ? Icons.error_outline_rounded : Icons.shield_rounded,
                color: color,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(
                    running && mode == VpnMode.proxy && ports.isNotEmpty
                        ? 'Локальные порты: ${ports.join(', ')}'
                        : 'Подключение появится здесь.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (running)
              const Icon(Icons.check_circle_rounded, color: Color(0xFF16A36A)),
          ],
        ),
      ),
    );
  }
}

class _ModeNote extends StatelessWidget {
  const _ModeNote({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 17, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
