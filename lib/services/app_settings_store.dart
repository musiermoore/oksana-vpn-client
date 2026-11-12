import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../vpn/vpn_runtime.dart';

class AppSettingsStore {
  const AppSettingsStore();

  static const _themeModeKey = 'app_theme_mode';
  static const _vpnModeKey = 'vpn_mode';
  static const _storage = FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );

  Future<ThemeMode?> readThemeMode() async {
    final value = await _storage.read(key: _themeModeKey);
    return switch (value) {
      'system' => ThemeMode.system,
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => null,
    };
  }

  Future<void> saveThemeMode(ThemeMode mode) =>
      _storage.write(key: _themeModeKey, value: mode.name);

  Future<VpnMode?> readVpnMode() async {
    final value = await _storage.read(key: _vpnModeKey);
    return switch (value) {
      'proxy' => VpnMode.proxy,
      'tun' => VpnMode.tun,
      _ => null,
    };
  }

  Future<void> saveVpnMode(VpnMode mode) =>
      _storage.write(key: _vpnModeKey, value: mode.name);
}
