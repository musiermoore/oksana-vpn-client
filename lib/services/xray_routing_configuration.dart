import '../models/vpn_routing_settings.dart';
import '../vpn/vpn_runtime.dart';
import 'xray_dns_configuration.dart';

class XrayRoutingConfiguration {
  const XrayRoutingConfiguration._();

  static void apply(
    Map<String, dynamic> configuration,
    VpnRoutingSettings settings, {
    required List<String> inboundTags,
  }) {
    if (!settings.enabled || inboundTags.isEmpty) return;

    final outbounds = (configuration['outbounds'] as List)
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    final usedTags = outbounds
        .map((outbound) => outbound['tag'])
        .whereType<String>()
        .toSet();
    for (var index = 0; index < outbounds.length; index++) {
      final tag = outbounds[index]['tag'];
      if (tag is! String || tag.isEmpty) {
        var generatedTag = 'oksana-outbound-${index + 1}';
        var suffix = 2;
        while (usedTags.contains(generatedTag)) {
          generatedTag = 'oksana-outbound-${index + 1}-${suffix++}';
        }
        outbounds[index]['tag'] = generatedTag;
        usedTags.add(generatedTag);
      }
    }

    final directOutbound = outbounds.cast<Map<String, dynamic>?>().firstWhere(
          (outbound) => outbound?['protocol'] == 'freedom',
          orElse: () => null,
        );
    final directTag = directOutbound?['tag'] is String
        ? directOutbound!['tag'] as String
        : _appendDirectOutbound(outbounds, usedTags);

    final vpnOutbound = outbounds.cast<Map<String, dynamic>?>().firstWhere(
          (outbound) =>
              outbound != null &&
              outbound['protocol'] != 'freedom' &&
              outbound['protocol'] != 'blackhole' &&
              outbound['protocol'] != 'dns' &&
              outbound['protocol'] != 'loopback',
          orElse: () => null,
        );
    final vpnTag = vpnOutbound?['tag'];
    if (vpnTag is! String || vpnTag.isEmpty) {
      throw const VpnRuntimeException(
        'В профиле не найден VPN-маршрут для выбранных правил.',
      );
    }

    final blockOutbound = outbounds.cast<Map<String, dynamic>?>().firstWhere(
          (outbound) => outbound?['protocol'] == 'blackhole',
          orElse: () => null,
        );
    final blockTag = blockOutbound?['tag'] is String
        ? blockOutbound!['tag'] as String
        : _appendBlockOutbound(outbounds, usedTags);
    configuration['outbounds'] = outbounds;

    final template = settings.activeTemplate;
    final dnsRoutingRules = <Map<String, dynamic>>[];
    if (XrayDnsConfiguration.controlsDns(template)) {
      configuration['dns'] = XrayDnsConfiguration.buildDns(
        template,
        profileDns: configuration['dns'],
      );
      final fakeDns = XrayDnsConfiguration.fakeDnsObject(
        template,
        profileFakeDns: configuration['fakedns'],
      );
      if (fakeDns == null) {
        configuration.remove('fakedns');
      } else {
        configuration['fakedns'] = fakeDns;
      }
    }
    if (XrayDnsConfiguration.needsInterception(template)) {
      final dnsTag = _appendDnsOutbound(outbounds, usedTags);
      configuration['outbounds'] = outbounds;
      dnsRoutingRules.add({
        'type': 'field',
        'inboundTag': inboundTags,
        'network': 'tcp,udp',
        'port': '53',
        'outboundTag': dnsTag,
      });
    }

    final routing = configuration['routing'] is Map
        ? Map<String, dynamic>.from(configuration['routing'] as Map)
        : <String, dynamic>{};
    if (routing['script'] is String &&
        (routing['script'] as String).trim().isNotEmpty) {
      throw const VpnRuntimeException(
        'В профиле используется сценарий маршрутизации, который нельзя объединить с правилами приложения.',
      );
    }

    final profileRules = routing['rules'] is List
        ? (routing['rules'] as List)
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .where((rule) => !_isUnconditionalRule(rule))
            .toList()
        : <Map<String, dynamic>>[];

    final targetForAction = {
      RoutingAction.direct: directTag,
      RoutingAction.proxy: vpnTag,
      RoutingAction.block: blockTag,
    };
    final dnsResolverRules =
        XrayDnsConfiguration.resolverRoutingRules(template, targetForAction);
    routing['rules'] = <Map<String, dynamic>>[
      ...dnsRoutingRules,
      ...dnsResolverRules,
      for (final rule in template.rules)
        _toXrayRule(rule, targetForAction[rule.action]!, inboundTags),
      ...profileRules,
      {
        'type': 'field',
        'inboundTag': inboundTags,
        'network': 'tcp,udp',
        'outboundTag': targetForAction[template.defaultAction]!,
      },
    ];
    if (template.domainStrategy != null) {
      routing['domainStrategy'] = template.domainStrategy;
    }
    configuration['routing'] = routing;
  }

  static String _appendDirectOutbound(
    List<Map<String, dynamic>> outbounds,
    Set<String> usedTags,
  ) {
    var tag = 'oksana-direct';
    var suffix = 2;
    while (usedTags.contains(tag)) {
      tag = 'oksana-direct-${suffix++}';
    }
    outbounds.add({
      'tag': tag,
      'protocol': 'freedom',
      'settings': <String, dynamic>{},
    });
    return tag;
  }

  static String _appendBlockOutbound(
    List<Map<String, dynamic>> outbounds,
    Set<String> usedTags,
  ) {
    var tag = 'oksana-block';
    var suffix = 2;
    while (usedTags.contains(tag)) {
      tag = 'oksana-block-${suffix++}';
    }
    outbounds.add({
      'tag': tag,
      'protocol': 'blackhole',
      'settings': <String, dynamic>{},
    });
    return tag;
  }

  static String _appendDnsOutbound(
    List<Map<String, dynamic>> outbounds,
    Set<String> usedTags,
  ) {
    var tag = 'oksana-dns';
    var suffix = 2;
    while (usedTags.contains(tag)) {
      tag = 'oksana-dns-${suffix++}';
    }
    usedTags.add(tag);
    outbounds.add({
      'tag': tag,
      'protocol': 'dns',
      'settings': <String, dynamic>{},
    });
    return tag;
  }

  static Map<String, dynamic> _toXrayRule(
    VpnRoutingRule rule,
    String outboundTag,
    List<String> inboundTags,
  ) {
    final hasStructuredConditions = rule.domains.isNotEmpty ||
        rule.ips.isNotEmpty ||
        rule.ports.isNotEmpty ||
        rule.networks.isNotEmpty ||
        rule.protocols.isNotEmpty ||
        rule.processes.isNotEmpty;
    final domains = rule.domains.isNotEmpty
        ? rule.domains
        : !hasStructuredConditions && rule.type == RoutingTargetType.domain
            ? [rule.value]
            : const <String>[];
    final ips = rule.ips.isNotEmpty
        ? rule.ips
        : !hasStructuredConditions && rule.type == RoutingTargetType.ip
            ? [rule.value]
            : const <String>[];
    final ports = rule.ports.isNotEmpty
        ? rule.ports
        : !hasStructuredConditions && rule.type == RoutingTargetType.port
            ? [rule.value]
            : const <String>[];
    final processes = rule.processes.isNotEmpty
        ? rule.processes
        : !hasStructuredConditions && rule.type == RoutingTargetType.process
            ? [rule.value]
            : const <String>[];
    return <String, dynamic>{
      'type': 'field',
      'inboundTag': inboundTags,
      'outboundTag': outboundTag,
      if (domains.isNotEmpty)
        'domain': domains
            .map((domain) =>
                RegExp(r'^(domain|full|keyword|regexp|geosite|dotless|ext):')
                        .hasMatch(domain)
                    ? domain
                    : 'domain:$domain')
            .toList(),
      if (ips.isNotEmpty) 'ip': ips,
      if (ports.isNotEmpty) 'port': ports.join(','),
      if (rule.networks.isNotEmpty) 'network': rule.networks.join(','),
      if (rule.protocols.isNotEmpty) 'protocol': rule.protocols,
      if (processes.isNotEmpty) 'process': processes,
    };
  }

  static bool _isUnconditionalRule(Map<String, dynamic> rule) {
    const matchFields = {
      'domain',
      'ip',
      'port',
      'sourcePort',
      'localPort',
      'network',
      'sourceIP',
      'localIP',
      'user',
      'protocol',
      'attrs',
      'process',
      'vlessRoute',
    };
    return !rule.keys.any(matchFields.contains);
  }
}
