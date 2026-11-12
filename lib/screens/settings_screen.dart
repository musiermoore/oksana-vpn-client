import 'package:flutter/material.dart';

import '../vpn/vpn_runtime.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.vpnMode,
    required this.onVpnModeChanged,
    required this.vpnModeEnabled,
    required this.themeMode,
    required this.onThemeModeChanged,
    required this.supportsTun,
  });

  final VpnMode vpnMode;
  final ValueChanged<VpnMode> onVpnModeChanged;
  final bool vpnModeEnabled;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final bool supportsTun;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late VpnMode _vpnMode = widget.vpnMode;
  late ThemeMode _themeMode = widget.themeMode;

  void _selectVpnMode(VpnMode mode) {
    setState(() => _vpnMode = mode);
    widget.onVpnModeChanged(mode);
  }

  void _selectThemeMode(ThemeMode mode) {
    setState(() => _themeMode = mode);
    widget.onThemeModeChanged(mode);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
            children: [
              Text(
                'Подключение',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Card(
                child: Column(
                  children: [
                    _VpnModeTile(
                      mode: VpnMode.proxy,
                      selectedMode: _vpnMode,
                      enabled: widget.vpnModeEnabled,
                      onChanged: _selectVpnMode,
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    _VpnModeTile(
                      mode: VpnMode.tun,
                      selectedMode: _vpnMode,
                      enabled: widget.vpnModeEnabled && widget.supportsTun,
                      onChanged: _selectVpnMode,
                    ),
                  ],
                ),
              ),
              if (!widget.vpnModeEnabled) ...[
                const SizedBox(height: 4),
                Text(
                  'Отключите VPN, чтобы изменить режим подключения.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 24),
              Text(
                'Внешний вид',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Card(
                child: Column(
                  children: [
                    _ThemeModeTile(
                      mode: ThemeMode.system,
                      selectedMode: _themeMode,
                      onChanged: _selectThemeMode,
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    _ThemeModeTile(
                      mode: ThemeMode.light,
                      selectedMode: _themeMode,
                      onChanged: _selectThemeMode,
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    _ThemeModeTile(
                      mode: ThemeMode.dark,
                      selectedMode: _themeMode,
                      onChanged: _selectThemeMode,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VpnModeTile extends StatelessWidget {
  const _VpnModeTile({
    required this.mode,
    required this.selectedMode,
    required this.enabled,
    required this.onChanged,
  });

  final VpnMode mode;
  final VpnMode selectedMode;
  final bool enabled;
  final ValueChanged<VpnMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final isProxy = mode == VpnMode.proxy;
    return _SettingsOptionTile(
      title: isProxy ? 'Proxy' : 'TUN',
      description: isProxy
          ? 'Подключение через локальные SOCKS/HTTP порты.'
          : 'Маршрутизирует системный трафик через VPN.',
      selected: mode == selectedMode,
      enabled: enabled,
      onTap: () => onChanged(mode),
    );
  }
}

class _ThemeModeTile extends StatelessWidget {
  const _ThemeModeTile({
    required this.mode,
    required this.selectedMode,
    required this.onChanged,
  });

  final ThemeMode mode;
  final ThemeMode selectedMode;
  final ValueChanged<ThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final (title, description) = switch (mode) {
      ThemeMode.system => ('Как в системе', 'Следовать настройкам macOS.'),
      ThemeMode.light => ('Светлая', 'Использовать светлую тему.'),
      ThemeMode.dark => ('Тёмная', 'Использовать тёмную тему.'),
    };
    return _SettingsOptionTile(
      title: title,
      description: description,
      selected: mode == selectedMode,
      onTap: () => onChanged(mode),
    );
  }
}

class _SettingsOptionTile extends StatelessWidget {
  const _SettingsOptionTile({
    required this.title,
    required this.description,
    required this.selected,
    required this.onTap,
    this.enabled = true,
  });

  final String title;
  final String description;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      enabled: enabled,
      onTap: enabled && !selected ? onTap : null,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Icon(
        selected
            ? Icons.radio_button_checked_rounded
            : Icons.radio_button_unchecked_rounded,
        color: selected ? colors.primary : colors.onSurfaceVariant,
      ),
      title: Text(title),
      subtitle: Text(description),
    );
  }
}
