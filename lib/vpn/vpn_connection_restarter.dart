import '../models/subscription_profile.dart';
import '../models/local_socks_auth_settings.dart';
import '../models/vpn_routing_settings.dart';
import 'vpn_runtime.dart';

Future<void> restartVpnConnection({
  required VpnRuntime runtime,
  required SubscriptionProfile profile,
  required VpnMode mode,
  required VpnRoutingSettings routingSettings,
  GlobalDnsSettings globalDnsSettings = const GlobalDnsSettings(),
  LocalSocksAuthSettings localSocksAuthSettings =
      const LocalSocksAuthSettings(),
  bool Function()? shouldReconnect,
}) async {
  await runtime.disconnect();
  if (runtime.snapshot.phase != VpnRuntimePhase.disconnected) {
    throw VpnRuntimeException(
      runtime.snapshot.errorMessage ?? 'Не удалось отключить VPN.',
    );
  }
  if (shouldReconnect != null && !shouldReconnect()) return;
  await runtime.connect(
    profile,
    mode,
    routingSettings: routingSettings,
    globalDnsSettings: globalDnsSettings,
    localSocksAuthSettings: localSocksAuthSettings,
  );
}
