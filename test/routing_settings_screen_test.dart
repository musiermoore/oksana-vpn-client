import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oksana_vpn_desktop/models/vpn_routing_settings.dart';
import 'package:oksana_vpn_desktop/screens/routing_settings_screen.dart';

void main() {
  const first = VpnRoutingRule(
    type: RoutingTargetType.domain,
    value: 'one.example',
    action: RoutingAction.direct,
  );
  const second = VpnRoutingRule(
    type: RoutingTargetType.domain,
    value: 'two.example',
    action: RoutingAction.proxy,
  );
  const structured = VpnRoutingRule(
    type: RoutingTargetType.domain,
    value: 'domain:example.com · 443 · tcp',
    action: RoutingAction.proxy,
    label: 'Импортированное правило',
    domains: ['domain:example.com'],
    ports: ['443'],
    networks: ['tcp'],
  );
  const settings = VpnRoutingSettings(
    enabled: true,
    activeTemplateId: 'one',
    templates: [
      RoutingTemplate(
          id: 'one', name: 'Мои правила', rules: [first, second, structured]),
    ],
  );

  Future<void> openEditor(
      WidgetTester tester, ValueChanged<VpnRoutingSettings?> onClosed) async {
    tester.view.physicalSize = const Size(450, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
            builder: (context) => TextButton(
                  onPressed: () async {
                    final result =
                        await Navigator.of(context).push<VpnRoutingSettings>(
                      MaterialPageRoute(
                          builder: (_) =>
                              const RoutingSettingsScreen(settings: settings)),
                    );
                    onClosed(result);
                  },
                  child: const Text('Открыть'),
                )),
      ),
    ));
    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
  }

  Future<void> openTemplateDetail(WidgetTester tester) async {
    await tester.tap(find.text('Мои правила'));
    await tester.pumpAndSettle();
    expect(find.text('Шаблоны'), findsOneWidget);
    await tester.tap(find.byTooltip('Действия с шаблоном'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Редактировать'));
    await tester.pumpAndSettle();
  }

  testWidgets('edit, reorder and guard unsaved changes', (tester) async {
    VpnRoutingSettings? saved;
    await openEditor(tester, (value) => saved = value);
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Сохранено'))
            .onPressed,
        isNull);
    await openTemplateDetail(tester);
    expect(find.text('Блокировать · 0'), findsOneWidget);
    expect(find.text('Через VPN · 2'), findsOneWidget);
    expect(find.text('Напрямую · 1'), findsOneWidget);
    expect(find.byIcon(Icons.drag_indicator_rounded), findsNWidgets(3));

    await tester.tap(find.text('two.example'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).last, 'changed.example');
    await tester.tap(find.text('Применить'));
    await tester.pumpAndSettle();
    expect(find.text('changed.example'), findsOneWidget);

    final changedRow = find.ancestor(
        of: find.text('changed.example'), matching: find.byType(ListTile));
    final dragHandle = find.descendant(
      of: changedRow,
      matching: find.byIcon(Icons.drag_indicator_rounded),
    );
    final dragOffset = tester.getCenter(find.text('Импортированное правило')) -
        tester.getCenter(dragHandle);
    await tester.drag(dragHandle, dragOffset);
    await tester.pumpAndSettle();

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Сохранить изменения'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Не сохранены изменения'), findsOneWidget);
    await tester.tap(find.text('Остаться'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сохранить изменения'));
    await tester.pumpAndSettle();
    expect(saved, isNotNull);
    final proxyRules = saved!.activeTemplate.rules
        .where((rule) => rule.action == RoutingAction.proxy)
        .toList();
    expect(proxyRules[0].label, 'Импортированное правило');
    expect(proxyRules[1].value, 'changed.example');
  });

  testWidgets('editing imported conditions preserves other fields',
      (tester) async {
    VpnRoutingSettings? saved;
    await openEditor(tester, (value) => saved = value);
    await openTemplateDetail(tester);
    await tester.ensureVisible(find.text('Импортированное правило'));
    await tester.tap(find.text('Импортированное правило'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'domain:changed.example');
    await tester.tap(find.text('Применить'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('К шаблонам'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сохранить изменения'));
    await tester.pumpAndSettle();
    final rule = saved!.activeTemplate.rules.last;
    expect(rule.domains, ['domain:changed.example']);
    expect(rule.ports, ['443']);
    expect(rule.networks, ['tcp']);
    expect(rule.action, RoutingAction.proxy);
  });

  testWidgets('shows DNS provider choices for both traffic paths',
      (tester) async {
    await openEditor(tester, (_) {});
    await openTemplateDetail(tester);
    await tester.tap(find.text('DNS и FakeDNS'));
    await tester.pumpAndSettle();

    expect(find.text('DNS через VPN'), findsOneWidget);
    expect(find.text('DNS для прямого подключения'), findsOneWidget);
    expect(
      find.byType(DropdownButtonFormField<RoutingDnsProvider>),
      findsNWidgets(2),
    );

    final dropdowns = find.byType(DropdownButtonFormField<RoutingDnsProvider>);
    await tester.tap(dropdowns.first);
    await tester.pumpAndSettle();
    for (final provider in ['Google', 'Cloudflare', 'Quad9', 'AdGuard']) {
      expect(find.text(provider), findsOneWidget);
    }
    await tester.tap(find.text('Google'));
    await tester.pumpAndSettle();
    expect(find.textContaining('https://dns.google/dns-query'), findsOneWidget);

    await tester.ensureVisible(dropdowns.last);
    await tester.tap(dropdowns.last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('AdGuard'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('https://dns.adguard-dns.com/dns-query'),
      findsOneWidget,
    );
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
  });
}
