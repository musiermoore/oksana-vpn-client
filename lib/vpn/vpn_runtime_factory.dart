import 'dart:io';

import 'macos_vpn_runtime.dart';
import 'vpn_runtime.dart';

VpnRuntime createVpnRuntime() {
  if (Platform.isMacOS) return MacosVpnRuntime();

  throw UnsupportedError('Для этой платформы VPN runtime ещё не реализован.');
}
