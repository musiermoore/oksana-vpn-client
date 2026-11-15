import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:oksana_vpn_desktop/models/vpn_routing_settings.dart';
import 'package:oksana_vpn_desktop/services/routing_template_importer.dart';

void main() {
  test('imports custom GeoIP and GeoSite URLs and persists them', () {
    final imported = RoutingTemplateImporter.parse(jsonEncode({
      'Name': 'Routing with custom geodata',
      'GlobalProxy': 'true',
      'Geoipurl': 'https://example.com/geoip.dat',
      'Geositeurl': 'https://example.com/geosite.dat',
      'RouteOrder': 'block-proxy-direct',
      'DirectSites': ['geosite:private'],
      'DirectIp': [],
      'ProxySites': [],
      'ProxyIp': [],
      'BlockSites': [],
      'BlockIp': [],
    }));

    expect(imported.template.geoipUrl, 'https://example.com/geoip.dat');
    expect(imported.template.geositeUrl, 'https://example.com/geosite.dat');
    expect(imported.template.rules.single.action, RoutingAction.direct);
    expect(imported.warnings, isEmpty);

    final settings = VpnRoutingSettings(
      enabled: true,
      activeTemplateId: imported.template.id,
      templates: [imported.template],
    );
    final restored = VpnRoutingSettings.decode(settings.encode());
    expect(restored.activeTemplate.geoipUrl, imported.template.geoipUrl);
    expect(restored.activeTemplate.geositeUrl, imported.template.geositeUrl);
  });

  test('imports Xray geodata asset URLs', () {
    final imported = RoutingTemplateImporter.parse(jsonEncode({
      'routing': {
        'rules': [
          {
            'type': 'field',
            'domain': ['geosite:private'],
            'outboundTag': 'direct'
          },
        ],
      },
      'geodata': {
        'assets': [
          {'url': 'https://example.com/ip.dat', 'file': 'geoip.dat'},
          {'url': 'https://example.com/site.dat', 'file': 'geosite.dat'},
        ],
      },
    }));

    expect(imported.template.geoipUrl, 'https://example.com/ip.dat');
    expect(imported.template.geositeUrl, 'https://example.com/site.dat');
    expect(imported.warnings, isEmpty);
  });

  test('rejects insecure geodata URLs with an import warning', () {
    final imported = RoutingTemplateImporter.parse(jsonEncode({
      'GlobalProxy': 'true',
      'Geoipurl': 'http://example.com/geoip.dat',
      'DirectSites': [],
      'DirectIp': [],
      'ProxySites': [],
      'ProxyIp': [],
      'BlockSites': [],
      'BlockIp': [],
    }));

    expect(imported.template.geoipUrl, isNull);
    expect(imported.warnings, contains(contains('только HTTPS')));
  });
}
