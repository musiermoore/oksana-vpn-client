import 'dart:async';
import 'dart:io';

import '../models/profile_ping_mode.dart';
import '../models/subscription_profile.dart';
import '../vpn/vpn_runtime.dart';

class ProfilePingService {
  const ProfilePingService._();

  static Future<int> measure({
    required SubscriptionProfile profile,
    required ProfilePingMode mode,
    required VpnRuntime runtime,
    required Uri httpTestUri,
  }) async {
    switch (mode) {
      case ProfilePingMode.http:
        if (runtime is! VpnConnectivityProbe) return -1;
        return (runtime as VpnConnectivityProbe)
            .probeConnectivity(profile, httpTestUri);
      case ProfilePingMode.tcp:
        return _measureTcp(profile);
      case ProfilePingMode.icmp:
        return _measureIcmp(profile);
    }
  }

  static Future<int> _measureTcp(SubscriptionProfile profile) async {
    final endpoint = profile.endpoint;
    if (endpoint == null) return -1;

    final stopwatch = Stopwatch()..start();
    Socket? socket;
    try {
      socket = await Socket.connect(
        endpoint.key,
        endpoint.value,
        timeout: const Duration(seconds: 4),
      );
      stopwatch.stop();
      return stopwatch.elapsedMilliseconds;
    } on SocketException {
      return -1;
    } on TimeoutException {
      return -1;
    } finally {
      socket?.destroy();
    }
  }

  static Future<int> _measureIcmp(SubscriptionProfile profile) async {
    final endpoint = profile.endpoint;
    if (endpoint == null) return -1;

    final arguments = Platform.isWindows
        ? ['-n', '1', '-w', '3000', endpoint.key]
        : Platform.isMacOS
            ? ['-n', '-c', '1', '-W', '3000', endpoint.key]
            : ['-n', '-c', '1', '-W', '3', endpoint.key];
    try {
      final result = await Process.run('ping', arguments)
          .timeout(const Duration(seconds: 5));
      if (result.exitCode != 0) return -1;
      final output = '${result.stdout}\n${result.stderr}';
      final match = RegExp(
        r'(?:time|время)[=<]\s*([\d]+(?:[.,][\d]+)?)\s*(?:ms|мс)',
        caseSensitive: false,
      ).firstMatch(output);
      final milliseconds = match == null
          ? null
          : double.tryParse(match.group(1)!.replaceAll(',', '.'));
      if (milliseconds == null) return -1;
      return milliseconds < 1 ? 1 : milliseconds.round();
    } on ProcessException {
      return -1;
    } on TimeoutException {
      return -1;
    }
  }
}
