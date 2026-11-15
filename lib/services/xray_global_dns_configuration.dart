import '../models/vpn_routing_settings.dart';
import '../vpn/vpn_runtime.dart';

class XrayGlobalDnsConfiguration {
  const XrayGlobalDnsConfiguration._();

  static const _dnsServerTag = 'oksana-global-dns';

  static void apply(
    Map<String, dynamic> configuration,
    GlobalDnsSettings settings, {
    required VpnRoutingSettings routingSettings,
    required List<String> inboundTags,
  }) {
    if (!settings.enabled || inboundTags.isEmpty) return;

    final template = routingSettings.activeTemplate;
    if (routingSettings.enabled &&
        (template.xrayDnsConfig != null ||
            template.dnsSettings?.hasSettings == true)) {
      return;
    }

    final upstreams = settings.upstreams;
    if (upstreams.isEmpty) {
      throw const VpnRuntimeException('Не указан адрес глобального DNS.');
    }

    final dns = configuration['dns'] is Map
        ? Map<String, dynamic>.from(configuration['dns'] as Map)
        : <String, dynamic>{};
    final existingServers = dns['servers'] is List
        ? List<dynamic>.from(dns['servers'] as List)
        : <dynamic>[];
    final fakeDnsServers = existingServers.where(_isFakeDns).toList();
    dns['servers'] = [
      ...fakeDnsServers,
      ...upstreams.map((upstream) => {
            'address': upstream.server,
            'tag': _dnsServerTag,
          }),
    ];
    if (settings.usesCloudflareAndGoogle) {
      dns
        ..['disableFallback'] = false
        ..['disableFallbackIfMatch'] = false
        ..['enableParallelQuery'] = false;
    }

    final hosts = dns['hosts'] is Map
        ? Map<String, dynamic>.from(dns['hosts'] as Map)
        : <String, dynamic>{};
    for (final upstream in upstreams) {
      _addBootstrapHost(hosts, upstream);
    }
    if (hosts.isNotEmpty) dns['hosts'] = hosts;
    configuration['dns'] = dns;

    final outbounds = (configuration['outbounds'] as List)
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    final usedTags = outbounds
        .map((outbound) => outbound['tag'])
        .whereType<String>()
        .toSet();
    final proxyIndex = outbounds.indexWhere((outbound) =>
        outbound['protocol'] != 'freedom' &&
        outbound['protocol'] != 'blackhole' &&
        outbound['protocol'] != 'dns' &&
        outbound['protocol'] != 'loopback');
    if (proxyIndex < 0) {
      throw const VpnRuntimeException(
        'В профиле не найден VPN-маршрут для глобального DNS.',
      );
    }
    var proxyTag = outbounds[proxyIndex]['tag'];
    if (proxyTag is! String || proxyTag.isEmpty) {
      proxyTag = _uniqueTag('oksana-global-proxy', usedTags);
      outbounds[proxyIndex]['tag'] = proxyTag;
      usedTags.add(proxyTag);
    }

    var dnsOutbound = outbounds.cast<Map<String, dynamic>?>().firstWhere(
          (outbound) => outbound?['protocol'] == 'dns',
          orElse: () => null,
        );
    if (dnsOutbound == null) {
      final tag = _uniqueTag('oksana-global-dns-out', usedTags);
      dnsOutbound = {
        'tag': tag,
        'protocol': 'dns',
        'settings': <String, dynamic>{},
      };
      outbounds.add(dnsOutbound);
      usedTags.add(tag);
    } else {
      final tag = dnsOutbound['tag'];
      if (tag is! String || tag.isEmpty) {
        final newTag = _uniqueTag('oksana-global-dns-out', usedTags);
        dnsOutbound['tag'] = newTag;
        usedTags.add(newTag);
      }
    }
    configuration['outbounds'] = outbounds;

    final routing = configuration['routing'] is Map
        ? Map<String, dynamic>.from(configuration['routing'] as Map)
        : <String, dynamic>{};
    final rules = routing['rules'] is List
        ? (routing['rules'] as List).whereType<Map>().toList()
        : <Map>[];
    final dnsTag = dnsOutbound['tag'] as String;
    final interceptsDns = rules.any((rule) =>
        _isDnsInterceptionRule(rule) && rule['outboundTag'] == dnsTag);
    final prefix = <Map<String, dynamic>>[
      if (!interceptsDns)
        {
          'type': 'field',
          'inboundTag': inboundTags,
          'network': 'tcp,udp',
          'port': '53',
          'outboundTag': dnsTag,
        },
      {
        'type': 'field',
        'inboundTag': [_dnsServerTag],
        'outboundTag': proxyTag,
      },
    ];
    routing['rules'] = [
      ...prefix,
      ...rules.map((rule) => Map<String, dynamic>.from(rule)),
    ];
    configuration['routing'] = routing;
  }

  static bool _isFakeDns(Object? server) =>
      server == 'fakedns' || (server is Map && server['address'] == 'fakedns');

  static void _addBootstrapHost(
    Map<String, dynamic> hosts,
    GlobalDnsUpstream upstream,
  ) {
    final bootstrapIp = upstream.bootstrapIp;
    final uri = Uri.tryParse(upstream.server);
    if (bootstrapIp != null &&
        uri != null &&
        uri.hasAuthority &&
        uri.host.isNotEmpty &&
        !uri.host.contains(':') &&
        !RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(uri.host)) {
      hosts.putIfAbsent(uri.host, () => bootstrapIp);
    }
  }

  static bool _isDnsInterceptionRule(Map rule) {
    final port = rule['port'];
    final network = rule['network'];
    return (port == 53 || port == '53') &&
        (network == 'tcp,udp' || network == 'udp,tcp' || network == 'udp');
  }

  static String _uniqueTag(String base, Set<String> usedTags) {
    var candidate = base;
    var suffix = 2;
    while (usedTags.contains(candidate)) {
      candidate = '$base-${suffix++}';
    }
    return candidate;
  }
}
