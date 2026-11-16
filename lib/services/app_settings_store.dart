import 'package:flutter/material.dart';

import '../models/local_socks_auth_settings.dart';
import '../models/profile_ping_mode.dart';
import '../models/vpn_routing_settings.dart';
import '../vpn/vpn_runtime.dart';
import 'secure_app_state_store.dart';

class AppSettingsStore {
  const AppSettingsStore();

  static const _themeModeKey = 'app_theme_mode';
  static const _vpnModeKey = 'vpn_mode';
  static const _vpnRoutingSettingsKey = 'vpn_routing_settings';
  static const _globalDnsSettingsKey = 'global_dns_settings';
  static const _localSocksAuthSettingsKey = 'local_socks_auth_settings';
  static const _profilePingModeKey = 'profile_ping_mode';

  Future<ProfilePingMode?> readProfilePingMode() async {
    final value = await SecureAppStateStore.read(_profilePingModeKey);
    return switch (value) {
      'http' => ProfilePingMode.http,
      'tcp' => ProfilePingMode.tcp,
      'icmp' => ProfilePingMode.icmp,
      _ => null,
    };
  }

  Future<void> saveProfilePingMode(ProfilePingMode mode) =>
      SecureAppStateStore.write(_profilePingModeKey, mode.name);
  Future<ThemeMode?> readThemeMode() async {
    final value = await SecureAppStateStore.read(_themeModeKey);
    return switch (value) {
      'system' => ThemeMode.system,
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => null,
    };
  }

  Future<void> saveThemeMode(ThemeMode mode) =>
      SecureAppStateStore.write(_themeModeKey, mode.name);

  Future<VpnMode?> readVpnMode() async {
    final value = await SecureAppStateStore.read(_vpnModeKey);
    return switch (value) {
      'proxy' => VpnMode.proxy,
      'tun' => VpnMode.tun,
      _ => null,
    };
  }

  Future<void> saveVpnMode(VpnMode mode) =>
      SecureAppStateStore.write(_vpnModeKey, mode.name);

  Future<VpnRoutingSettings> readRoutingSettings() async {
    final value = await SecureAppStateStore.read(_vpnRoutingSettingsKey);
    if (value == null || value.isEmpty) return const VpnRoutingSettings();
    return VpnRoutingSettings.decode(value);
  }

  Future<void> saveRoutingSettings(VpnRoutingSettings settings) =>
      SecureAppStateStore.write(_vpnRoutingSettingsKey, settings.encode());

  Future<GlobalDnsSettings> readGlobalDnsSettings() async {
    final value = await SecureAppStateStore.read(_globalDnsSettingsKey);
    if (value == null || value.isEmpty) return const GlobalDnsSettings();
    try {
      return GlobalDnsSettings.decode(value);
    } on FormatException {
      return const GlobalDnsSettings();
    }
  }

  Future<void> saveGlobalDnsSettings(GlobalDnsSettings settings) =>
      SecureAppStateStore.write(_globalDnsSettingsKey, settings.encode());

  Future<LocalSocksAuthSettings> readLocalSocksAuthSettings() async {
    final value = await SecureAppStateStore.read(_localSocksAuthSettingsKey);
    if (value != null && value.isNotEmpty) {
      final settings = LocalSocksAuthSettings.decode(value);
      if (settings.username == 'oksana') {
        final migrated = settings.copyWith(
          username: LocalSocksAuthSettings.createRandomUsername(),
        );
        await saveLocalSocksAuthSettings(migrated);
        return migrated;
      }
      return settings;
    }

    // Keep existing Proxy users working after upgrading. Fresh installs get
    // a private generated password, stored alongside other Keychain settings.
    final initialSettings = await readVpnMode() == VpnMode.proxy
        ? const LocalSocksAuthSettings()
        : LocalSocksAuthSettings.createSecureDefault();
    await saveLocalSocksAuthSettings(initialSettings);
    return initialSettings;
  }

  Future<void> saveLocalSocksAuthSettings(LocalSocksAuthSettings settings) =>
      SecureAppStateStore.write(_localSocksAuthSettingsKey, settings.encode());
}
