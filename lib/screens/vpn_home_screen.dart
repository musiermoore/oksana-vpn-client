import 'dart:async';

import 'package:characters/characters.dart';
import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../models/subscription_profile.dart';
import '../services/subscription_api.dart';
import '../services/subscription_store.dart';
import '../vpn/vpn_runtime.dart';
import '../vpn/vpn_runtime_factory.dart';

class VpnHomeScreen extends StatefulWidget {
  const VpnHomeScreen({
    super.key,
    required this.profiles,
    required this.subscriptionUuid,
  });

  final List<SubscriptionProfile> profiles;
  final String subscriptionUuid;

  @override
  State<VpnHomeScreen> createState() => _VpnHomeScreenState();
}

class _VpnHomeScreenState extends State<VpnHomeScreen> {
  late final VpnRuntime _runtime = createVpnRuntime();
  late final TextEditingController _uuidController =
      TextEditingController(text: widget.subscriptionUuid);
  final _subscriptionApi = SubscriptionApi();
  final _subscriptionStore = const SubscriptionStore();

  late List<SubscriptionProfile> _profiles = List.of(widget.profiles);
  late SubscriptionProfile _selectedProfile = _profiles.first;
  VpnMode _selectedMode = VpnMode.tun;
  int _selectedTab = 0;
  bool _switchingServer = false;
  bool _updatingSubscription = false;
  bool _showUuid = false;
  bool _serversExpanded = true;
  final Map<String, bool> _expandedServerGroups = {};
  String? _subscriptionError;

  @override
  void dispose() {
    _runtime.dispose();
    _subscriptionApi.close();
    _uuidController.dispose();
    super.dispose();
  }

  Future<void> _toggleConnection() async {
    try {
      if (_runtime.snapshot.phase == VpnRuntimePhase.running) {
        await _runtime.disconnect();
      } else {
        await _runtime.connect(_selectedProfile, _selectedMode);
      }
    } on VpnRuntimeException catch (error) {
      _showMessage(error.message);
    }
  }

  Future<void> _selectProfile(SubscriptionProfile profile) async {
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
      await _runtime.connect(profile, _selectedMode);
    } on VpnRuntimeException catch (error) {
      _showMessage(error.message);
    } finally {
      if (mounted) setState(() => _switchingServer = false);
    }
  }

  Future<void> _updateSubscription() async {
    if (_updatingSubscription ||
        _runtime.snapshot.phase != VpnRuntimePhase.disconnected) {
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _updatingSubscription = true;
      _subscriptionError = null;
    });

    try {
      final uuid = _uuidController.text.trim();
      final profiles = await _subscriptionApi.fetchProfiles(uuid);
      String? storageWarning;
      try {
        await _subscriptionStore.saveUuid(uuid);
      } catch (_) {
        storageWarning = 'Код не удалось сохранить на устройстве.';
      }
      if (!mounted) return;

      setState(() {
        _profiles = profiles;
        _selectedProfile = profiles.first;
      });
      if (storageWarning != null) _showMessage(storageWarning);
      setState(() => _selectedTab = 0);
    } on SubscriptionApiException catch (error) {
      if (mounted) setState(() => _subscriptionError = error.message);
    } finally {
      if (mounted) setState(() => _updatingSubscription = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _changeMode(VpnMode mode) {
    if (_runtime.snapshot.phase == VpnRuntimePhase.running ||
        _runtime.snapshot.phase == VpnRuntimePhase.starting ||
        _runtime.snapshot.phase == VpnRuntimePhase.stopping ||
        mode == _selectedMode) {
      return;
    }

    if (!_runtime.supports(mode)) {
      _showMessage('Режим TUN недоступен на этом устройстве.');
      return;
    }
    setState(() => _selectedMode = mode);
    final hint = mode == VpnMode.tun
        ? 'Весь системный трафик пойдёт через VPN. Может потребоваться разрешение на изменение сетевых настроек.'
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

        return Scaffold(
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: _selectedTab == 0
                    ? _buildConnectionView(
                        state: state,
                        isBusy: isBusy,
                        isRunning: isRunning,
                      )
                    : _buildProfileView(
                        canUpdate: phase == VpnRuntimePhase.disconnected &&
                            !_switchingServer,
                      ),
              ),
            ),
          ),
          bottomNavigationBar: NavigationBar(
            height: 64,
            selectedIndex: _selectedTab,
            onDestinationSelected: (index) =>
                setState(() => _selectedTab = index),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.power_settings_new_rounded),
                selectedIcon: Icon(Icons.power_settings_new_rounded),
                label: 'Подключение',
              ),
              NavigationDestination(
                icon: Icon(Icons.person_outline_rounded),
                selectedIcon: Icon(Icons.person_rounded),
                label: 'Профиль',
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
    final profilesByGroup = <String, List<SubscriptionProfile>>{};
    for (final profile in _profiles) {
      profilesByGroup.putIfAbsent(profile.groupKey, () => []).add(profile);
    }
    final ungroupedProfiles = profilesByGroup.remove('ungrouped');

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: SizedBox(
              width: 260,
              child: SegmentedButton<VpnMode>(
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                ),
                segments: [
                  const ButtonSegment(
                    value: VpnMode.proxy,
                    label: Text('Proxy'),
                  ),
                  ButtonSegment(
                    value: VpnMode.tun,
                    label: const Text('TUN'),
                    enabled: _runtime.supports(VpnMode.tun),
                  ),
                ],
                selected: {_selectedMode},
                onSelectionChanged: isRunning || isBusy
                    ? null
                    : (selection) => _changeMode(selection.first),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.center,
            child: _PowerControl(
              phase: state.phase,
              enabled: !isBusy && !_switchingServer && canConnect,
              onPressed: _toggleConnection,
            ),
          ),
          const SizedBox(height: 8),
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
          const SizedBox(height: 26),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Material(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => setState(
                          () => _serversExpanded = !_serversExpanded,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 8,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Серверы · ${_profiles.length}',
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              Icon(
                                _serversExpanded
                                    ? Icons.keyboard_arrow_up_rounded
                                    : Icons.keyboard_arrow_down_rounded,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (_serversExpanded) ...[
                    for (final profiles in profilesByGroup.values) ...[
                      _ServerGroupHeader(
                        name: profiles.first.groupName,
                        count: profiles.length,
                        expanded:
                            _expandedServerGroups[profiles.first.groupKey] ??
                                true,
                        onTap: () => setState(() {
                          final key = profiles.first.groupKey;
                          _expandedServerGroups[key] =
                              !(_expandedServerGroups[key] ?? true);
                        }),
                      ),
                      if (_expandedServerGroups[profiles.first.groupKey] ??
                          true) ...[
                        const SizedBox(height: 4),
                        for (final profile in profiles)
                          _ServerOption(
                            profile: profile,
                            selected: identical(profile, _selectedProfile),
                            connected: isRunning &&
                                identical(profile, _selectedProfile),
                            enabled: !isBusy && !_switchingServer,
                            onTap: () => _selectProfile(profile),
                          ),
                      ],
                    ],
                    if (ungroupedProfiles != null) ...[
                      _ServerGroupHeader(
                        name: 'Без группы',
                        count: ungroupedProfiles.length,
                        expanded: _expandedServerGroups['ungrouped'] ?? true,
                        onTap: () => setState(() {
                          _expandedServerGroups['ungrouped'] =
                              !(_expandedServerGroups['ungrouped'] ?? true);
                        }),
                      ),
                      if (_expandedServerGroups['ungrouped'] ?? true) ...[
                        const SizedBox(height: 4),
                        for (final profile in ungroupedProfiles)
                          _ServerOption(
                            profile: profile,
                            selected: identical(profile, _selectedProfile),
                            connected: isRunning &&
                                identical(profile, _selectedProfile),
                            enabled: !isBusy && !_switchingServer,
                            onTap: () => _selectProfile(profile),
                          ),
                      ],
                    ],
                  ],
                ],
              ),
            ),
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

  Widget _buildProfileView({required bool canUpdate}) {
    final theme = Theme.of(context);
    final canSubmit = canUpdate && !_updatingSubscription;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 28),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
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
                    tooltip: 'О хранении кода',
                    onPressed: _showUuidInfo,
                    icon: const Icon(Icons.info_outline_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _uuidController,
                enabled: !_updatingSubscription,
                autocorrect: false,
                enableSuggestions: false,
                obscureText: !_showUuid,
                keyboardType: TextInputType.text,
                textCapitalization: TextCapitalization.none,
                onSubmitted: (_) {
                  if (canSubmit) unawaited(_updateSubscription());
                },
                decoration: InputDecoration(
                  labelText: 'UUID подписки',
                  prefixIcon: const Icon(Icons.key_rounded),
                  suffixIcon: IconButton(
                    tooltip: _showUuid ? 'Скрыть код' : 'Показать код',
                    onPressed: () => setState(() => _showUuid = !_showUuid),
                    icon: Icon(_showUuid
                        ? Icons.visibility_off_rounded
                        : Icons.visibility_rounded),
                  ),
                ),
              ),
              if (_subscriptionError != null) ...[
                const SizedBox(height: 12),
                Text(
                  _subscriptionError!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ],
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: canSubmit ? _updateSubscription : null,
                icon: _updatingSubscription
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.sync_rounded),
                label: Text(
                    _updatingSubscription ? 'Загружаем…' : 'Обновить подписку'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _connectionStatus(VpnRuntimeSnapshot state) {
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
    final running = phase == VpnRuntimePhase.running;
    final busy =
        phase == VpnRuntimePhase.starting || phase == VpnRuntimePhase.stopping;
    final active = running || phase == VpnRuntimePhase.stopping;
    final color = active ? const Color(0xFF16A36A) : AppTheme.primary;
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
                    color: isFilled ? Colors.white : AppTheme.primary,
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
            foregroundColor: isFilled ? Colors.white : AppTheme.primary,
            disabledForegroundColor: isFilled
                ? Colors.white70
                : AppTheme.primary.withValues(alpha: 0.6),
            side: BorderSide(color: color, width: 2),
            shape: const CircleBorder(),
          ),
        ),
      ),
    );
  }
}

class _ServerGroupHeader extends StatelessWidget {
  const _ServerGroupHeader({
    required this.name,
    required this.count,
    required this.expanded,
    required this.onTap,
  });

  final String name;
  final int count;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '$name · $count',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Icon(
                  expanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ServerOption extends StatelessWidget {
  const _ServerOption({
    required this.profile,
    required this.selected,
    required this.connected,
    required this.enabled,
    required this.onTap,
  });

  final SubscriptionProfile profile;
  final bool selected;
  final bool connected;
  final bool enabled;
  final VoidCallback onTap;

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
          ? colors.primary.withValues(alpha: 0.08)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: [
              SizedBox(
                width: 24,
                child: leadingEmoji == null
                    ? Icon(
                        Icons.public_rounded,
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
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
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
              Icon(
                selected
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 20,
                color: selected ? colors.primary : colors.outline,
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
