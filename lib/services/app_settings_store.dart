import 'package:flutter/material.dart';

import '../vpn/vpn_runtime.dart';
import 'secure_app_state_store.dart';

class AppSettingsStore {
  const AppSettingsStore();

  static const _themeModeKey = 'app_theme_mode';
  static const _vpnModeKey = 'vpn_mode';
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
}
