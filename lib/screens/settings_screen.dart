import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_theme.dart';
import '../models/local_socks_auth_settings.dart';
import '../models/vpn_routing_settings.dart';
import '../vpn/vpn_runtime.dart';
import 'appearance_settings_screen.dart';
import 'routing_settings_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.vpnMode,
    required this.currentVpnMode,
    required this.onVpnModeChanged,
    required this.runtime,
    required this.themeMode,
    required this.onThemeModeChanged,
    required this.supportsTun,
    required this.routingSettings,
    required this.currentRoutingSettings,
    required this.onRoutingSettingsChanged,
    required this.globalDnsSettings,
    required this.currentGlobalDnsSettings,
    required this.onGlobalDnsSettingsChanged,
    required this.localSocksAuthSettings,
    required this.currentLocalSocksAuthSettings,
    required this.onLocalSocksAuthSettingsChanged,
  });

  final VpnMode vpnMode;
  final VpnMode Function() currentVpnMode;
  final Future<void> Function(VpnMode) onVpnModeChanged;
  final VpnRuntime runtime;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final bool supportsTun;
  final VpnRoutingSettings routingSettings;
  final VpnRoutingSettings Function() currentRoutingSettings;
  final Future<void> Function(VpnRoutingSettings) onRoutingSettingsChanged;
  final GlobalDnsSettings globalDnsSettings;
  final GlobalDnsSettings Function() currentGlobalDnsSettings;
  final Future<void> Function(GlobalDnsSettings) onGlobalDnsSettingsChanged;
  final LocalSocksAuthSettings localSocksAuthSettings;
  final LocalSocksAuthSettings Function() currentLocalSocksAuthSettings;
  final Future<void> Function(LocalSocksAuthSettings)
      onLocalSocksAuthSettingsChanged;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late VpnMode _vpnMode = widget.vpnMode;
  late ThemeMode _themeMode = widget.themeMode;
  late VpnRoutingSettings _routingSettings = widget.routingSettings;
  late GlobalDnsSettings _globalDnsSettings = widget.globalDnsSettings;
  late LocalSocksAuthSettings _localSocksAuthSettings =
      widget.localSocksAuthSettings;
  late LocalSocksAuthSettings _savedLocalSocksAuthSettings =
      widget.localSocksAuthSettings;
  bool _showSocksPassword = false;
  bool _applying = false;

  bool get _localSocksAuthHasChanges =>
      _localSocksAuthSettings.encode() != _savedLocalSocksAuthSettings.encode();

  Future<void> _selectVpnMode(VpnMode mode) async {
    if (_applying || mode == _vpnMode) return;
    setState(() => _vpnMode = mode);
    await _applyChanges(() => widget.onVpnModeChanged(mode));
  }

  void _selectThemeMode(ThemeMode mode) {
    setState(() => _themeMode = mode);
    widget.onThemeModeChanged(mode);
  }

  Future<void> _openAppearanceSettings() async {
    final mode = await Navigator.of(context).push<ThemeMode>(
      MaterialPageRoute<ThemeMode>(
        builder: (_) => AppearanceSettingsScreen(themeMode: _themeMode),
      ),
    );
    if (mode == null || !mounted || mode == _themeMode) return;
    _selectThemeMode(mode);
  }

  Future<void> _openRoutingSettings() async {
    if (_applying || !widget.supportsTun) return;
    final settings = await Navigator.of(context).push<VpnRoutingSettings>(
      MaterialPageRoute<VpnRoutingSettings>(
        builder: (_) => RoutingSettingsScreen(settings: _routingSettings),
      ),
    );
    if (settings == null || !mounted) return;
    setState(() => _routingSettings = settings);
    await _applyChanges(() => widget.onRoutingSettingsChanged(settings));
  }

  Future<void> _openGlobalDnsSettings() async {
    if (_applying || !widget.supportsTun) return;
    final settings = await showDialog<GlobalDnsSettings>(
      context: context,
      builder: (_) => _GlobalDnsSettingsDialog(settings: _globalDnsSettings),
    );
    if (settings == null ||
        !mounted ||
        settings.encode() == _globalDnsSettings.encode()) {
      return;
    }
    setState(() => _globalDnsSettings = settings);
    await _applyChanges(() => widget.onGlobalDnsSettingsChanged(settings));
  }

  void _updateLocalSocksAuth(LocalSocksAuthSettings settings) {
    setState(() => _localSocksAuthSettings = settings);
  }

  Future<void> _saveLocalSocksAuthSettings() async {
    final settings = _localSocksAuthSettings;
    if (settings.enabled && settings.validationError != null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(settings.validationError!)),
        );
      return;
    }

    setState(() => _localSocksAuthSettings = settings);
    await _applyChanges(
      () => widget.onLocalSocksAuthSettingsChanged(settings),
    );
    if (mounted &&
        widget.currentLocalSocksAuthSettings().encode() == settings.encode()) {
      setState(() => _savedLocalSocksAuthSettings = settings);
    }
  }

  Future<void> _copyCredential(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('Данные скопированы в буфер обмена.')),
      );
  }

  Future<void> _applyChanges(Future<void> Function() action) async {
    setState(() => _applying = true);
    try {
      await action();
    } on VpnRuntimeException catch (error) {
      if (mounted) {
        _syncSettings();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message)),
        );
      }
    } catch (_) {
      if (mounted) {
        _syncSettings();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось применить настройки.')),
        );
      }
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  void _syncSettings() {
    setState(() {
      _vpnMode = widget.currentVpnMode();
      _routingSettings = widget.currentRoutingSettings();
      _globalDnsSettings = widget.currentGlobalDnsSettings();
      _localSocksAuthSettings = widget.currentLocalSocksAuthSettings();
      _savedLocalSocksAuthSettings = _localSocksAuthSettings;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final segmentedStyle = AppTheme.selectionControlStyle(colors);
    return StreamBuilder<VpnRuntimeSnapshot>(
      stream: widget.runtime.changes,
      initialData: widget.runtime.snapshot,
      builder: (context, snapshot) {
        final phase = snapshot.data?.phase ?? widget.runtime.snapshot.phase;
        final canChange = !_applying &&
            phase != VpnRuntimePhase.starting &&
            phase != VpnRuntimePhase.stopping;
        return Scaffold(
          appBar: AppBar(
            backgroundColor: theme.scaffoldBackgroundColor,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(1),
              child: Divider(
                height: 1,
                thickness: 1,
                color: theme.dividerColor,
              ),
            ),
            centerTitle: false,
            leadingWidth: 48,
            titleSpacing: 0,
            title: Text(
              'Настройки',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ),
          body: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                children: [
                  Text(
                    'Режим подключения',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<VpnMode>(
                    showSelectedIcon: false,
                    segments: [
                      const ButtonSegment(
                          value: VpnMode.proxy, label: Text('Proxy')),
                      ButtonSegment(
                          value: VpnMode.tun,
                          label: const Text('TUN'),
                          enabled: widget.supportsTun),
                    ],
                    selected: {_vpnMode},
                    onSelectionChanged: canChange
                        ? (value) => _selectVpnMode(value.first)
                        : null,
                    style: segmentedStyle,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _vpnMode == VpnMode.tun
                        ? 'Маршрутизирует системный трафик через VPN.'
                        : 'Локальный SOCKS/HTTP-прокси для настроенных приложений.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  if (!canChange) ...[
                    const SizedBox(height: 4),
                    Text(
                      _applying
                          ? 'Применяем настройки подключения…'
                          : 'Дождитесь завершения подключения.',
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
                    clipBehavior: Clip.antiAlias,
                    child: ListTile(
                      onTap: _openAppearanceSettings,
                      leading: Icon(Icons.palette_outlined,
                          color: theme.colorScheme.primary),
                      title: const Text('Тема приложения'),
                      subtitle: Text(_themeModeLabel(_themeMode)),
                      trailing: const Icon(Icons.chevron_right_rounded),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Маршрутизация',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Card(
                    clipBehavior: Clip.antiAlias,
                    child: ListTile(
                      enabled: canChange && widget.supportsTun,
                      onTap: canChange && widget.supportsTun
                          ? _openRoutingSettings
                          : null,
                      leading: Icon(
                        Icons.alt_route_rounded,
                        color: widget.supportsTun
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      title: const Text('Правила маршрутизации'),
                      subtitle: Text(_routingSummary),
                      trailing: const Icon(Icons.chevron_right_rounded),
                    ),
                  ),
                  if (!widget.supportsTun) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Маршрутизация доступна в режиме TUN на поддерживаемом Mac.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  Text(
                    'DNS',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Card(
                    clipBehavior: Clip.antiAlias,
                    child: ListTile(
                      enabled: canChange && widget.supportsTun,
                      onTap: canChange && widget.supportsTun
                          ? _openGlobalDnsSettings
                          : null,
                      leading: Icon(Icons.dns_rounded,
                          color: widget.supportsTun
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurfaceVariant),
                      title: const Text('Системный DNS'),
                      subtitle: Text(
                        _globalDnsSettingsLabel(_globalDnsSettings),
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Применяется в режиме TUN. Если маршрутизация включена, DNS её активного шаблона имеет приоритет.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Локальный SOCKS5',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  _buildLocalSocksAuthCard(theme, canChange, phase),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildLocalSocksAuthCard(
    ThemeData theme,
    bool canChange,
    VpnRuntimePhase phase,
  ) {
    final colors = theme.colorScheme;
    final validationError = _localSocksAuthSettings.validationError;
    final willRestart = _vpnMode == VpnMode.proxy &&
        phase == VpnRuntimePhase.running &&
        _localSocksAuthHasChanges;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile.adaptive(
            value: _localSocksAuthSettings.enabled,
            onChanged: canChange
                ? (enabled) => _updateLocalSocksAuth(
                      _localSocksAuthSettings.copyWith(enabled: enabled),
                    )
                : null,
            title: const Text('Требовать логин и пароль'),
            subtitle: Text(_vpnMode == VpnMode.proxy
                ? 'Адрес 127.0.0.1, порт показан на главном экране. Логин и пароль проверяют доступ, но не шифруют соединение.'
                : 'Настройка будет применяться в режиме Proxy.'),
          ),
          if (_localSocksAuthSettings.enabled) ...[
            Divider(height: 1, color: theme.dividerColor),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  TextFormField(
                    initialValue: _localSocksAuthSettings.username,
                    enabled: canChange,
                    onChanged: (username) => _updateLocalSocksAuth(
                      _localSocksAuthSettings.copyWith(username: username),
                    ),
                    decoration: InputDecoration(
                      labelText: 'Имя пользователя',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        tooltip: 'Скопировать имя пользователя',
                        onPressed: _localSocksAuthSettings.username.isEmpty
                            ? null
                            : () => _copyCredential(
                                  _localSocksAuthSettings.username,
                                ),
                        icon: const Icon(Icons.copy_rounded),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    initialValue: _localSocksAuthSettings.password,
                    enabled: canChange,
                    obscureText: !_showSocksPassword,
                    onChanged: (password) => _updateLocalSocksAuth(
                      _localSocksAuthSettings.copyWith(password: password),
                    ),
                    decoration: InputDecoration(
                      labelText: 'Пароль',
                      border: const OutlineInputBorder(),
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: _showSocksPassword
                                ? 'Скрыть пароль'
                                : 'Показать пароль',
                            onPressed: canChange
                                ? () => setState(() =>
                                    _showSocksPassword = !_showSocksPassword)
                                : null,
                            icon: Icon(_showSocksPassword
                                ? Icons.visibility_off_rounded
                                : Icons.visibility_rounded),
                          ),
                          IconButton(
                            tooltip: 'Скопировать пароль',
                            onPressed: _localSocksAuthSettings.password.isEmpty
                                ? null
                                : () => _copyCredential(
                                      _localSocksAuthSettings.password,
                                    ),
                            icon: const Icon(Icons.copy_rounded),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (validationError != null) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        validationError,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: colors.error),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
          if (_localSocksAuthHasChanges)
            Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                _localSocksAuthSettings.enabled ? 0 : 8,
                16,
                16,
              ),
              child: Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: canChange ? _saveLocalSocksAuthSettings : null,
                  icon: Icon(willRestart
                      ? Icons.restart_alt_rounded
                      : Icons.save_rounded),
                  label: Text(
                      willRestart ? 'Сохранить и переподключить' : 'Сохранить'),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String get _routingSummary {
    if (!widget.supportsTun) return 'Доступно только в режиме TUN.';
    final name = _routingSettings.activeTemplate.name;
    return '${_routingSettings.enabled ? 'Включены' : 'Выключены'} · $name';
  }

  String _themeModeLabel(ThemeMode mode) => switch (mode) {
        ThemeMode.system => 'Следовать настройкам системы',
        ThemeMode.light => 'Светлая тема',
        ThemeMode.dark => 'Тёмная тема',
      };
}

String _globalDnsProviderLabel(RoutingDnsProvider provider) =>
    switch (provider) {
      RoutingDnsProvider.internal => 'Внутренний',
      RoutingDnsProvider.google => 'Google',
      RoutingDnsProvider.cloudflare => 'Cloudflare',
      RoutingDnsProvider.cloudflareGoogle => 'Cloudflare + Google',
      RoutingDnsProvider.quad9 => 'Quad9',
      RoutingDnsProvider.adguard => 'AdGuard',
      RoutingDnsProvider.custom => 'Свой DNS',
    };

String _globalDnsSettingsLabel(GlobalDnsSettings settings) =>
    _globalDnsProviderLabel(settings.provider);

class _GlobalDnsSettingsDialog extends StatefulWidget {
  const _GlobalDnsSettingsDialog({required this.settings});

  final GlobalDnsSettings settings;

  @override
  State<_GlobalDnsSettingsDialog> createState() =>
      _GlobalDnsSettingsDialogState();
}

class _GlobalDnsSettingsDialogState extends State<_GlobalDnsSettingsDialog> {
  final _formKey = GlobalKey<FormState>();
  late RoutingDnsProvider _provider = widget.settings.provider;
  late final _serverController = TextEditingController(
    text: widget.settings.customServer,
  );
  late final _bootstrapController = TextEditingController(
    text: widget.settings.customBootstrapIp,
  );

  @override
  void dispose() {
    _serverController.dispose();
    _bootstrapController.dispose();
    super.dispose();
  }

  void _selectProvider(RoutingDnsProvider provider) {
    final previousProvider = _provider;
    final preset = RoutingDnsProviderPreset.forProvider(provider);
    if (preset != null) {
      _serverController.text = preset.server;
      _bootstrapController.text = preset.bootstrapIp;
    } else if (provider == RoutingDnsProvider.custom &&
        previousProvider != RoutingDnsProvider.custom) {
      final previousPreset =
          RoutingDnsProviderPreset.forProvider(previousProvider);
      if (previousPreset != null) {
        _serverController.text = previousPreset.server;
        _bootstrapController.text = previousPreset.bootstrapIp;
      }
    }
    setState(() => _provider = provider);
  }

  String? _validateServer(String? raw) {
    final value = raw?.trim() ?? '';
    if (value.isEmpty) return 'Укажите IP-адрес или HTTPS-ссылку DoH.';
    if (InternetAddress.tryParse(value) != null) return null;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return 'Укажите IP-адрес или корректную HTTPS-ссылку DoH.';
    }
    return null;
  }

  String? _validateBootstrapIp(String? raw) {
    final value = raw?.trim() ?? '';
    if (value.isEmpty) {
      final uri = Uri.tryParse(_serverController.text.trim());
      if (uri != null && InternetAddress.tryParse(uri.host) == null) {
        return 'Для DoH-ссылки с доменом укажите IP для первого подключения.';
      }
      return null;
    }
    if (InternetAddress.tryParse(value) == null) {
      return 'Укажите корректный IP-адрес.';
    }
    return null;
  }

  void _submit() {
    if (_provider == RoutingDnsProvider.custom &&
        !_formKey.currentState!.validate()) {
      return;
    }
    Navigator.of(context).pop(GlobalDnsSettings(
      provider: _provider,
      customServer: _provider == RoutingDnsProvider.custom
          ? _serverController.text.trim()
          : null,
      customBootstrapIp: _provider == RoutingDnsProvider.custom
          ? _bootstrapController.text.trim()
          : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final preset = RoutingDnsProviderPreset.forProvider(_provider);
    final presetSettings = GlobalDnsSettings(provider: _provider);
    return AlertDialog(
      title: const Text('Системный DNS для TUN'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Этот DNS используется для всего системного трафика в режиме TUN. Если маршрутизация включена, DNS её активного шаблона имеет приоритет.',
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<RoutingDnsProvider>(
                  initialValue: _provider,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Провайдер DNS',
                    border: OutlineInputBorder(),
                  ),
                  items: RoutingDnsProvider.values
                      .map((provider) => DropdownMenuItem(
                            value: provider,
                            child: Text(_globalDnsProviderLabel(provider)),
                          ))
                      .toList(growable: false),
                  onChanged: (provider) {
                    if (provider != null) _selectProvider(provider);
                  },
                ),
                if (preset != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    presetSettings.upstreams
                        .map((upstream) =>
                            '${upstream.server}\nДля системного DNS используется ${upstream.bootstrapIp}.')
                        .join('\n\n'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (presetSettings.usesCloudflareAndGoogle) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Xray использует Cloudflare первым, а Google — как резерв, если не получит подходящий ответ.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ] else if (_provider == RoutingDnsProvider.custom) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _serverController,
                    decoration: const InputDecoration(
                      labelText: 'IP-адрес или HTTPS-ссылка DoH',
                      hintText: 'https://dns.example/dns-query или 9.9.9.9',
                    ),
                    validator: _validateServer,
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _bootstrapController,
                    decoration: const InputDecoration(
                      labelText: 'IP для первого подключения',
                      hintText: 'Например, 9.9.9.9',
                    ),
                    validator: _validateBootstrapIp,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Сохранить')),
      ],
    );
  }
}
