import 'package:flutter_test/flutter_test.dart';
import 'package:oksana_vpn_desktop/models/vpn_routing_settings.dart';
import 'package:oksana_vpn_desktop/services/xray_routing_configuration.dart';

void main() {
  test('scopes app rules to the inbound selected by the runtime', () {
    final configuration = <String, dynamic>{
      'inbounds': const [],
      'outbounds': [
        {'tag': 'proxy', 'protocol': 'vless'},
        {'tag': 'direct', 'protocol': 'freedom'},
      ],
      'routing': {
        'rules': [
          {
            'type': 'field',
            'domain': ['domain:profile.example'],
            'outboundTag': 'proxy',
          },
        ],
      },
    };
    final settings = VpnRoutingSettings(
      enabled: true,
      activeTemplateId: 'custom',
      templates: const [
        RoutingTemplate(
          id: 'custom',
          name: 'Custom',
          defaultAction: RoutingAction.proxy,
          rules: [
            VpnRoutingRule(
              type: RoutingTargetType.domain,
              value: 'example.com',
              action: RoutingAction.direct,
            ),
          ],
        ),
      ],
    );

    XrayRoutingConfiguration.apply(
      configuration,
      settings,
      inboundTags: const ['local-socks', 'local-http'],
    );

    final rules = (configuration['routing'] as Map)['rules'] as List;
    expect(rules, hasLength(3));
    expect(rules[0]['domain'], ['domain:example.com']);
    expect(rules[0]['inboundTag'], ['local-socks', 'local-http']);
    expect(rules[0]['outboundTag'], 'direct');
    expect(rules[1]['domain'], ['domain:profile.example']);
    expect(rules[2]['inboundTag'], ['local-socks', 'local-http']);
    expect(rules[2]['network'], 'tcp,udp');
    expect(rules[2]['outboundTag'], 'proxy');
  });

  test('adds tags to outbounds before using them in routing rules', () {
    final configuration = <String, dynamic>{
      'outbounds': [
        {'protocol': 'vless'},
        {'protocol': 'freedom'},
      ],
    };
    final settings = VpnRoutingSettings(
      enabled: true,
      templates: const [
        RoutingTemplate(id: 'empty', name: 'Empty'),
      ],
      activeTemplateId: 'empty',
    );

    XrayRoutingConfiguration.apply(
      configuration,
      settings,
      inboundTags: const ['oksana-tun'],
    );

    final outbounds = configuration['outbounds'] as List;
    expect(outbounds[0]['tag'], isA<String>());
    expect(outbounds[1]['tag'], isA<String>());
    final rules = (configuration['routing'] as Map)['rules'] as List;
    expect(rules.single['inboundTag'], ['oksana-tun']);
  });
}
