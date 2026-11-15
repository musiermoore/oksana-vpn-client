import 'dart:async';
import 'dart:io';

import 'package:oksana_vpn_desktop/models/local_socks_auth_settings.dart';
import 'package:oksana_vpn_desktop/models/subscription_profile.dart';
import 'package:oksana_vpn_desktop/models/vpn_routing_settings.dart';
import 'package:oksana_vpn_desktop/vpn/vpn_connection_restarter.dart';
import 'package:oksana_vpn_desktop/vpn/vpn_runtime.dart';

void expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}

class FakeRuntime implements VpnRuntime {
  VpnRuntimeSnapshot state =
      const VpnRuntimeSnapshot(phase: VpnRuntimePhase.running);
  final events = <String>[];
  bool failDisconnect = false;
  bool remainRunning = false;
  bool failConnect = false;
  SubscriptionProfile? connectedProfile;
  VpnMode? connectedMode;
  VpnRoutingSettings? connectedSettings;
  GlobalDnsSettings? connectedGlobalDnsSettings;

  @override
  VpnRuntimeSnapshot get snapshot => state;

  @override
  Stream<VpnRuntimeSnapshot> get changes => const Stream.empty();

  @override
  bool supports(VpnMode mode) => true;

  @override
  Future<void> disconnect() async {
    events.add('stop');
    if (failDisconnect) throw const VpnRuntimeException('stop failed');
    state = VpnRuntimeSnapshot(
      phase:
          remainRunning ? VpnRuntimePhase.error : VpnRuntimePhase.disconnected,
      errorMessage: remainRunning ? 'still running' : null,
    );
  }

  @override
  Future<void> connect(
    SubscriptionProfile profile,
    VpnMode mode, {
    VpnRoutingSettings routingSettings = const VpnRoutingSettings(),
    GlobalDnsSettings globalDnsSettings = const GlobalDnsSettings(),
    LocalSocksAuthSettings localSocksAuthSettings =
        const LocalSocksAuthSettings(),
  }) async {
    events.add('start');
    expect(state.phase == VpnRuntimePhase.disconnected, 'start before stop');
    connectedProfile = profile;
    connectedMode = mode;
    connectedSettings = routingSettings;
    connectedGlobalDnsSettings = globalDnsSettings;
    if (failConnect) throw const VpnRuntimeException('start failed');
    state = const VpnRuntimeSnapshot(phase: VpnRuntimePhase.running);
  }

  @override
  void dispose() {}
}

Future<void> main() async {
  const profile = SubscriptionProfile(configuration: {}, index: 1);
  const settings = VpnRoutingSettings(enabled: true);
  final runtime = FakeRuntime();
  await restartVpnConnection(
    runtime: runtime,
    profile: profile,
    mode: VpnMode.tun,
    routingSettings: settings,
    globalDnsSettings:
        const GlobalDnsSettings(provider: RoutingDnsProvider.google),
  );
  expect(runtime.events.join(',') == 'stop,start', 'wrong operation order');
  expect(identical(runtime.connectedProfile, profile), 'profile changed');
  expect(runtime.connectedMode == VpnMode.tun, 'mode changed');
  expect(identical(runtime.connectedSettings, settings), 'settings changed');
  expect(
    runtime.connectedGlobalDnsSettings?.provider == RoutingDnsProvider.google,
    'global DNS settings changed',
  );
  expect(runtime.snapshot.phase == VpnRuntimePhase.running, 'not running');

  for (final failure in ['exception', 'status', 'start']) {
    final failing = FakeRuntime()
      ..failDisconnect = failure == 'exception'
      ..remainRunning = failure == 'status'
      ..failConnect = failure == 'start';
    var failed = false;
    try {
      await restartVpnConnection(
        runtime: failing,
        profile: profile,
        mode: VpnMode.proxy,
        routingSettings: settings,
      );
    } on VpnRuntimeException {
      failed = true;
    }
    expect(failed, '$failure error was not propagated');
    if (failure != 'start') {
      expect(failing.events.join(',') == 'stop', 'started after stop failure');
    }
  }

  final cancelled = FakeRuntime();
  await restartVpnConnection(
    runtime: cancelled,
    profile: profile,
    mode: VpnMode.tun,
    routingSettings: settings,
    shouldReconnect: () => false,
  );
  expect(cancelled.events.join(',') == 'stop', 'started after disposal');
  stdout.writeln('VPN reconnection checks passed.');
}
