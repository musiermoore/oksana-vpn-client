import 'dart:async';

import '../models/subscription_profile.dart';

enum VpnMode { proxy, tun }

enum VpnRuntimePhase { disconnected, starting, running, stopping, error }

class VpnRuntimeSnapshot {
  const VpnRuntimeSnapshot({
    required this.phase,
    this.errorMessage,
    this.localProxyPorts = const [],
  });

  final VpnRuntimePhase phase;
  final String? errorMessage;
  final List<int> localProxyPorts;
}

abstract interface class VpnRuntime {
  VpnRuntimeSnapshot get snapshot;
  Stream<VpnRuntimeSnapshot> get changes;
  bool supports(VpnMode mode);

  Future<void> connect(SubscriptionProfile profile, VpnMode mode);
  Future<void> disconnect();
  void dispose();
}

abstract interface class VpnConnectivityProbe {
  Future<int> probeConnectivity(SubscriptionProfile profile, Uri testUri);
}

class VpnRuntimeException implements Exception {
  const VpnRuntimeException(this.message);

  final String message;

  @override
  String toString() => message;
}
