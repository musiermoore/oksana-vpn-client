import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oksana_vpn_desktop/models/local_socks_auth_settings.dart';
import 'package:oksana_vpn_desktop/models/subscription_profile.dart';
import 'package:oksana_vpn_desktop/models/vpn_routing_settings.dart';
import 'package:oksana_vpn_desktop/screens/settings_screen.dart';
import 'package:oksana_vpn_desktop/vpn/vpn_runtime.dart';

void main() {
  testWidgets('selects and saves a global DNS provider', (tester) async {
    tester.view.physicalSize = const Size(450, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var currentDns = const GlobalDnsSettings();
    GlobalDnsSettings? savedDns;
    await tester.pumpWidget(MaterialApp(
      home: SettingsScreen(
        vpnMode: VpnMode.tun,
        currentVpnMode: () => VpnMode.tun,
        onVpnModeChanged: (_) async {},
        runtime: _FakeRuntime(),
        themeMode: ThemeMode.system,
        onThemeModeChanged: (_) {},
        supportsTun: true,
        routingSettings: const VpnRoutingSettings(),
        currentRoutingSettings: () => const VpnRoutingSettings(),
        onRoutingSettingsChanged: (_) async {},
        globalDnsSettings: currentDns,
        currentGlobalDnsSettings: () => currentDns,
        onGlobalDnsSettingsChanged: (settings) async {
          currentDns = settings;
          savedDns = settings;
        },
        localSocksAuthSettings: const LocalSocksAuthSettings(),
        currentLocalSocksAuthSettings: () => const LocalSocksAuthSettings(),
        onLocalSocksAuthSettingsChanged: (_) async {},
      ),
    ));

    await tester.ensureVisible(find.text('Системный DNS'));
    await tester.tap(find.text('Системный DNS'));
    await tester.pumpAndSettle();
    expect(find.text('Системный DNS для TUN'), findsOneWidget);

    await tester.tap(find.byType(DropdownButtonFormField<RoutingDnsProvider>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cloudflare'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('https://cloudflare-dns.com/dns-query'),
      findsOneWidget,
    );

    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(savedDns?.provider, RoutingDnsProvider.cloudflare);
  });
}

class _FakeRuntime implements VpnRuntime {
  @override
  VpnRuntimeSnapshot get snapshot =>
      const VpnRuntimeSnapshot(phase: VpnRuntimePhase.disconnected);

  @override
  Stream<VpnRuntimeSnapshot> get changes => const Stream.empty();

  @override
  bool supports(VpnMode mode) => true;

  @override
  Future<void> connect(
    SubscriptionProfile profile,
    VpnMode mode, {
    VpnRoutingSettings routingSettings = const VpnRoutingSettings(),
    GlobalDnsSettings globalDnsSettings = const GlobalDnsSettings(),
    LocalSocksAuthSettings localSocksAuthSettings =
        const LocalSocksAuthSettings(),
  }) async {}

  @override
  Future<void> disconnect() async {}

  @override
  void dispose() {}
}
