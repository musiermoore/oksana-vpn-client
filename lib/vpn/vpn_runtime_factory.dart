import 'dart:io';

import 'macos_vpn_runtime.dart';
import 'windows_vpn_runtime.dart';
import 'vpn_runtime.dart';

VpnRuntime createVpnRuntime() {
  if (Platform.isMacOS) return MacosVpnRuntime();
  if (Platform.isWindows) return WindowsVpnRuntime();

  throw UnsupportedError('VPN пока недоступен на этом устройстве.');
}
