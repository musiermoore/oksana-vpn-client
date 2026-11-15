import 'dart:async';
import 'dart:io';

import '../models/local_socks_auth_settings.dart';
import '../models/subscription_profile.dart';
import '../models/vpn_routing_settings.dart';
import 'macos_daemon_tunnel_runtime.dart';
import 'macos_proxy_runtime.dart';
import 'vpn_runtime.dart';

class MacosVpnRuntime implements VpnRuntime, VpnConnectivityProbe {
  final MacosProxyRuntime _proxy = MacosProxyRuntime();
  final MacosDaemonTunnelRuntime _tunnel = MacosDaemonTunnelRuntime();
  final StreamController<VpnRuntimeSnapshot> _changes =
      StreamController<VpnRuntimeSnapshot>.broadcast();
  late final StreamSubscription<VpnRuntimeSnapshot> _initialTunnelChanges;

  VpnRuntime? _active;
  StreamSubscription<VpnRuntimeSnapshot>? _activeChanges;
  VpnRuntimeSnapshot _snapshot =
      const VpnRuntimeSnapshot(phase: VpnRuntimePhase.disconnected);
  bool _disposed = false;

  MacosVpnRuntime() {
    _initialTunnelChanges = _tunnel.changes.listen((value) {
      if (_active != null && !identical(_active, _tunnel)) return;
      if (value.phase == VpnRuntimePhase.disconnected) {
        _active = null;
      } else {
        _active = _tunnel;
      }
      _snapshot = value;
      _publish();
    });
  }

  @override
  VpnRuntimeSnapshot get snapshot => _snapshot;

  @override
  Stream<VpnRuntimeSnapshot> get changes => _changes.stream;

  @override
  bool supports(VpnMode mode) =>
      Platform.isMacOS && (_proxy.supports(mode) || _tunnel.supports(mode));

  @override
  Future<int> probeConnectivity(
    SubscriptionProfile profile,
    Uri testUri,
  ) async {
    final probeRuntime = MacosProxyRuntime();
    try {
      return await probeRuntime.probeConnectivity(profile, testUri);
    } finally {
      probeRuntime.dispose();
    }
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
    if (routingSettings.enabled &&
        routingSettings.activeTemplate.rules
            .any((rule) => rule.hasProcessTarget)) {
      throw const VpnRuntimeException(
        'Xray не поддерживает маршрутизацию по процессам в текущей версии macOS-клиента. Используйте правила по сайтам, IP и портам.',
      );
    }

    final runtime = switch (mode) {
      VpnMode.proxy => _proxy,
      VpnMode.tun => _tunnel,
    };
    if (!runtime.supports(mode)) {
      throw const VpnRuntimeException('Этот режим VPN сейчас недоступен.');
    }

    await _activeChanges?.cancel();
    _active = runtime;
    _snapshot = runtime.snapshot;
    _activeChanges = runtime.changes.listen((value) {
      _snapshot = value;
      _publish();
    });
    _publish();
    await runtime.connect(
      profile,
      mode,
      routingSettings: routingSettings,
      globalDnsSettings: globalDnsSettings,
      localSocksAuthSettings: localSocksAuthSettings,
    );
    _snapshot = runtime.snapshot;
    _publish();
  }

  @override
  Future<void> disconnect() async {
    final runtime = _active;
    if (runtime == null) return;
    await runtime.disconnect();
    _snapshot = runtime.snapshot;
    _publish();
  }

  void _publish() {
    if (!_disposed && !_changes.isClosed) _changes.add(_snapshot);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_initialTunnelChanges.cancel());
    unawaited(_activeChanges?.cancel());
    _proxy.dispose();
    _tunnel.dispose();
    unawaited(_changes.close());
  }
}
