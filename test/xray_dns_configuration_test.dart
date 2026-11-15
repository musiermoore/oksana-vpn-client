import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:oksana_vpn_desktop/models/vpn_routing_settings.dart';
import 'package:oksana_vpn_desktop/services/routing_template_importer.dart';
import 'package:oksana_vpn_desktop/services/xray_global_dns_configuration.dart';
import 'package:oksana_vpn_desktop/services/xray_routing_configuration.dart';

void main() {
  test('imports DNS endpoints, hosts, and FakeDNS from a routing template', () {
    final imported = RoutingTemplateImporter.parse(jsonEncode({
      'Name': 'DNS template',
      'GlobalProxy': 'true',
      'RemoteDNSType': 'DoH',
      'RemoteDNSDomain': 'https://dns.example/dns-query',
      'RemoteDNSIP': '9.9.9.9',
      'DomesticDNSType': 'DoU',
      'DomesticDNSIP': '10.0.0.1',
      'DnsHosts': {'dns.example': '9.9.9.9'},
      'FakeDNS': 'true',
      'DirectSites': ['domain:local.example'],
      'DirectIp': [],
      'ProxySites': ['geosite:proxy-list'],
      'ProxyIp': [],
      'BlockSites': [],
      'BlockIp': [],
    }));

    final dns = imported.template.dnsSettings!;
    expect(dns.remoteServer, 'https://dns.example/dns-query');
    expect(dns.remoteBootstrapIp, '9.9.9.9');
    expect(dns.domesticServer, '10.0.0.1');
    expect(dns.hosts, {'dns.example': '9.9.9.9'});
    expect(imported.template.usesFakeDns, isTrue);
    expect(imported.warnings, isEmpty);

    final stored = VpnRoutingSettings(
      enabled: true,
      activeTemplateId: 'dns',
      templates: [imported.template.copyWith(id: 'dns')],
    );
    final restored = VpnRoutingSettings.decode(stored.encode()).activeTemplate;
    expect(restored.dnsSettings?.remoteServer, dns.remoteServer);
    expect(restored.dnsSettings?.hosts, dns.hosts);
    expect(restored.usesFakeDns, isTrue);

    final exported = jsonDecode(
      RoutingTemplateImporter.exportXrayJson(imported.template),
    ) as Map<String, dynamic>;
    final exportedRules = (exported['rules'] as List).whereType<Map>();
    final remoteResolverRule = exportedRules.singleWhere(
      (rule) =>
          rule['inboundTag'] is List &&
          (rule['inboundTag'] as List).contains('oksana-remote-dns'),
    );
    expect(remoteResolverRule['outboundTag'], 'proxy');
  });

  test('adds DNS routing, FakeDNS pools, resolver hosts, and interception', () {
    final configuration = <String, dynamic>{
      'outbounds': [
        {'tag': 'proxy', 'protocol': 'vless'},
        {'tag': 'direct', 'protocol': 'freedom'},
      ],
    };
    const template = RoutingTemplate(
      id: 'dns',
      name: 'DNS',
      defaultAction: RoutingAction.proxy,
      fakeDnsEnabled: true,
      dnsSettings: RoutingDnsSettings(
        remoteServer: 'https://dns.example/dns-query',
        remoteBootstrapIp: '9.9.9.9',
        domesticServer: '10.0.0.1',
      ),
      rules: [
        VpnRoutingRule(
          type: RoutingTargetType.domain,
          value: 'local.example',
          domains: ['domain:local.example'],
          action: RoutingAction.direct,
        ),
      ],
    );
    final settings = VpnRoutingSettings(
      enabled: true,
      activeTemplateId: 'dns',
      templates: const [template],
    );

    XrayRoutingConfiguration.apply(
      configuration,
      settings,
      inboundTags: const ['oksana-tun'],
    );

    final dns = configuration['dns'] as Map;
    final servers = dns['servers'] as List;
    expect(servers.first, 'fakedns');
    final directDns = servers.whereType<Map>().singleWhere(
          (server) => server['address'] == '10.0.0.1',
        );
    expect(directDns['domains'], ['domain:local.example']);
    expect(directDns['skipFallback'], isTrue);
    expect(dns['hosts'], {'dns.example': '9.9.9.9'});
    expect(configuration['fakedns'], [
      {'ipPool': '198.18.0.0/15', 'poolSize': 32768},
      {'ipPool': '2001:2::/48', 'poolSize': 32768},
    ]);

    final outbounds = configuration['outbounds'] as List;
    final dnsOutbound = outbounds.whereType<Map>().singleWhere(
          (outbound) => outbound['protocol'] == 'dns',
        );
    final rules = (configuration['routing'] as Map)['rules'] as List;
    expect(rules.first['port'], '53');
    expect(rules.first['network'], 'tcp,udp');
    expect(rules.first['inboundTag'], ['oksana-tun']);
    expect(rules.first['outboundTag'], dnsOutbound['tag']);
    expect(rules[1]['inboundTag'], ['oksana-remote-dns']);
    expect(rules[1]['outboundTag'], 'proxy');
    expect(rules[2]['inboundTag'], ['oksana-domestic-dns']);
    expect(rules[2]['outboundTag'], 'direct');
  });

  test('preserves Xray DNS and FakeDNS settings through JSON export', () {
    const rawDns = {
      'servers': [
        'fakedns',
        {'address': '1.1.1.1', 'tag': 'remote-resolver'},
      ],
      'queryStrategy': 'UseIPv4',
    };
    const rawFakeDns = {'ipPool': '198.18.0.0/16', 'poolSize': 65535};
    final imported = RoutingTemplateImporter.parse(jsonEncode({
      'name': 'Imported Xray DNS',
      'dns': rawDns,
      'fakedns': rawFakeDns,
      'routing': {
        'rules': [
          {
            'type': 'field',
            'inboundTag': ['remote-resolver'],
            'outboundTag': 'proxy',
          },
          {'type': 'field', 'network': 'tcp,udp', 'outboundTag': 'proxy'},
        ],
      },
    }));

    final exported = jsonDecode(
      RoutingTemplateImporter.exportXrayJson(imported.template),
    ) as Map<String, dynamic>;
    expect(exported['dns'], rawDns);
    expect(exported['fakedns'], rawFakeDns);
    expect(imported.template.usesFakeDns, isTrue);
    expect(imported.template.dnsRoutes.single.inboundTag, 'remote-resolver');
    expect(imported.template.dnsRoutes.single.action, RoutingAction.proxy);

    final configuration = <String, dynamic>{
      'outbounds': [
        {'tag': 'proxy', 'protocol': 'vless'},
        {'tag': 'direct', 'protocol': 'freedom'},
      ],
    };
    XrayRoutingConfiguration.apply(
      configuration,
      VpnRoutingSettings(
        enabled: true,
        activeTemplateId: imported.template.id,
        templates: [imported.template],
      ),
      inboundTags: const ['oksana-tun'],
    );
    final routingRules = (configuration['routing'] as Map)['rules'] as List;
    expect(routingRules[1]['inboundTag'], ['remote-resolver']);
    expect(routingRules[1]['outboundTag'], 'proxy');
  });

  test('intercepts DNS for configured resolvers even when FakeDNS is off', () {
    final configuration = <String, dynamic>{
      'outbounds': [
        {'tag': 'proxy', 'protocol': 'vless'},
        {'tag': 'direct', 'protocol': 'freedom'},
      ],
    };
    final settings = VpnRoutingSettings(
      enabled: true,
      activeTemplateId: 'dns',
      templates: const [
        RoutingTemplate(
          id: 'dns',
          name: 'DNS only',
          fakeDnsEnabled: false,
          dnsSettings: RoutingDnsSettings(remoteServer: '1.1.1.1'),
        ),
      ],
    );

    XrayRoutingConfiguration.apply(
      configuration,
      settings,
      inboundTags: const ['local-socks'],
    );

    expect(configuration.containsKey('fakedns'), isFalse);
    final outbounds = configuration['outbounds'] as List;
    final dnsOutbound = outbounds.whereType<Map>().singleWhere(
          (outbound) => outbound['protocol'] == 'dns',
        );
    final rules = (configuration['routing'] as Map)['rules'] as List;
    expect(rules.first['port'], '53');
    expect(rules.first['outboundTag'], dnsOutbound['tag']);
  });

  test('persists DNS providers and routes profile DNS by rule action', () {
    const template = RoutingTemplate(
      id: 'provider-dns',
      name: 'Provider DNS',
      defaultAction: RoutingAction.proxy,
      fakeDnsEnabled: false,
      dnsSettings: RoutingDnsSettings(
        remoteProvider: RoutingDnsProvider.internal,
        domesticProvider: RoutingDnsProvider.internal,
      ),
      rules: [
        VpnRoutingRule(
          type: RoutingTargetType.domain,
          value: 'local.example',
          domains: ['domain:local.example'],
          action: RoutingAction.direct,
        ),
      ],
    );
    final stored = VpnRoutingSettings(
      enabled: true,
      activeTemplateId: template.id,
      templates: const [template],
    );
    final restored = VpnRoutingSettings.decode(stored.encode()).activeTemplate;
    expect(
      restored.dnsSettings?.remoteProvider,
      RoutingDnsProvider.internal,
    );
    expect(
      restored.dnsSettings?.domesticProvider,
      RoutingDnsProvider.internal,
    );

    final configuration = <String, dynamic>{
      'dns': {
        'servers': [
          {'address': '9.9.9.9'},
          {'address': '1.1.1.1'},
        ],
      },
      'outbounds': [
        {'tag': 'proxy', 'protocol': 'vless'},
        {'tag': 'direct', 'protocol': 'freedom'},
      ],
    };
    XrayRoutingConfiguration.apply(
      configuration,
      stored,
      inboundTags: const ['oksana-tun'],
    );

    final servers = (configuration['dns'] as Map)['servers'] as List;
    final remoteServers = servers.whereType<Map>().where(
          (server) => server['tag'] == 'oksana-remote-dns',
        );
    final domesticServers = servers.whereType<Map>().where(
          (server) => server['tag'] == 'oksana-domestic-dns',
        );
    expect(remoteServers.map((server) => server['address']).toSet(), {
      '9.9.9.9',
      '1.1.1.1',
    });
    expect(domesticServers.map((server) => server['address']).toSet(), {
      '9.9.9.9',
      '1.1.1.1',
    });
    expect(
      domesticServers.every((server) =>
          (server['domains'] as List).contains('domain:local.example') &&
          server['skipFallback'] == true),
      isTrue,
    );

    final rules = (configuration['routing'] as Map)['rules'] as List;
    expect(rules[1]['inboundTag'], ['oksana-remote-dns']);
    expect(rules[1]['outboundTag'], 'proxy');
    expect(rules[2]['inboundTag'], ['oksana-domestic-dns']);
    expect(rules[2]['outboundTag'], 'direct');
  });

  test('applies global DNS to TUN and keeps FakeDNS entries', () {
    final configuration = <String, dynamic>{
      'dns': {
        'servers': [
          'fakedns',
          {'address': '1.1.1.1'},
        ],
        'hosts': {'local.example': '192.168.1.10'},
      },
      'outbounds': [
        {'protocol': 'freedom', 'tag': 'direct'},
        {'protocol': 'vless', 'tag': 'proxy'},
      ],
      'routing': {
        'rules': [
          {'type': 'field', 'port': '443', 'outboundTag': 'proxy'},
        ],
      },
    };
    const globalDns = GlobalDnsSettings(provider: RoutingDnsProvider.google);

    XrayGlobalDnsConfiguration.apply(
      configuration,
      globalDns,
      routingSettings: const VpnRoutingSettings(),
      inboundTags: const ['oksana-tun'],
    );

    final dns = configuration['dns'] as Map;
    expect(dns['servers'], [
      'fakedns',
      {
        'address': 'https://dns.google/dns-query',
        'tag': 'oksana-global-dns',
      },
    ]);
    expect(dns['hosts'], {
      'local.example': '192.168.1.10',
      'dns.google': '8.8.8.8',
    });
    final rules = (configuration['routing'] as Map)['rules'] as List;
    expect(rules[0]['port'], '53');
    expect(rules[0]['outboundTag'], 'oksana-global-dns-out');
    expect(rules[1]['inboundTag'], ['oksana-global-dns']);
    expect(rules[1]['outboundTag'], 'proxy');
    expect(rules[2]['port'], '443');
  });

  test('active template DNS settings override global DNS', () {
    final configuration = <String, dynamic>{
      'dns': {
        'servers': [
          {'address': 'profile-dns'},
        ],
      },
      'outbounds': [
        {'protocol': 'vless', 'tag': 'proxy'},
      ],
    };
    final routing = VpnRoutingSettings(
      enabled: true,
      activeTemplateId: 'custom',
      templates: const [
        RoutingTemplate(
          id: 'custom',
          name: 'Custom DNS',
          dnsSettings: RoutingDnsSettings(remoteServer: 'profile-dns'),
        ),
      ],
    );

    XrayGlobalDnsConfiguration.apply(
      configuration,
      const GlobalDnsSettings(provider: RoutingDnsProvider.google),
      routingSettings: routing,
      inboundTags: const ['oksana-tun'],
    );

    expect(
      (configuration['dns'] as Map)['servers'],
      [
        {'address': 'profile-dns'},
      ],
    );
    expect(configuration.containsKey('routing'), isFalse);
  });

  test('global DNS settings persist the provider and custom endpoint', () {
    const settings = GlobalDnsSettings(
      provider: RoutingDnsProvider.custom,
      customServer: 'https://resolver.example/dns-query',
      customBootstrapIp: '203.0.113.7',
    );

    final restored = GlobalDnsSettings.decode(settings.encode());
    expect(restored.provider, RoutingDnsProvider.custom);
    expect(restored.server, 'https://resolver.example/dns-query');
    expect(restored.bootstrapIp, '203.0.113.7');
    expect(
      GlobalDnsSettings.decode('{"provider":"google"}').server,
      RoutingDnsProviderPreset.forProvider(RoutingDnsProvider.google)!.server,
    );
  });
}
