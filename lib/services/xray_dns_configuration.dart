import 'dart:io';

import '../models/vpn_routing_settings.dart';

class XrayDnsConfiguration {
  const XrayDnsConfiguration._();

  static const remoteServerTag = 'oksana-remote-dns';
  static const domesticServerTag = 'oksana-domestic-dns';

  static const _defaultFakeDns = <Object?>[
    {'ipPool': '198.18.0.0/15', 'poolSize': 32768},
    {'ipPool': '2001:2::/48', 'poolSize': 32768},
  ];

  static bool controlsDns(RoutingTemplate template) =>
      template.dnsSettings?.hasSettings == true ||
      template.xrayDnsConfig != null ||
      template.fakeDnsEnabled != null ||
      template.xrayFakeDnsConfig != null ||
      template.dnsRoutes.isNotEmpty;

  static Map<String, dynamic> buildDns(
    RoutingTemplate template, {
    Object? profileDns,
  }) {
    final profile = profileDns is Map
        ? Map<String, dynamic>.from(profileDns)
        : <String, dynamic>{};
    final templateDns = template.xrayDnsConfig;
    final dns = templateDns != null
        ? Map<String, dynamic>.from(templateDns)
        : Map<String, dynamic>.from(profile);

    if (templateDns == null && template.dnsSettings?.hasSettings == true) {
      final oldServers = profile['servers'] is List
          ? List<dynamic>.from(profile['servers'] as List)
          : <dynamic>[];
      dns['servers'] = _buildServers(
        template,
        template.dnsSettings!,
        oldServers,
      );
      final hosts = <String, dynamic>{};
      if (profile['hosts'] is Map) {
        hosts.addAll(Map<String, dynamic>.from(profile['hosts'] as Map));
      }
      hosts.addAll(template.dnsSettings!.hosts);
      _addBootstrapHost(
        hosts,
        template.dnsSettings!.remoteServer,
        template.dnsSettings!.remoteBootstrapIp,
      );
      _addBootstrapHost(
        hosts,
        template.dnsSettings!.domesticServer,
        template.dnsSettings!.domesticBootstrapIp,
      );
      if (hosts.isNotEmpty) dns['hosts'] = hosts;
    }

    final currentServers = dns['servers'] is List
        ? List<dynamic>.from(dns['servers'] as List)
        : <dynamic>[];
    final hasFakeServer = _containsFakeDns(currentServers);
    if (template.usesFakeDns && !hasFakeServer) {
      final fakeServer = _fakeDnsServer(template);
      if (fakeServer != null) currentServers.insert(0, fakeServer);
    } else if (template.fakeDnsEnabled == false && hasFakeServer) {
      currentServers.removeWhere(_isFakeDnsServer);
    }
    if (currentServers.isNotEmpty || dns.containsKey('servers')) {
      dns['servers'] = currentServers;
    }

    if (template.usesFakeDns && !dns.containsKey('servers')) {
      final fakeServer = _fakeDnsServer(template);
      if (fakeServer != null) dns['servers'] = [fakeServer];
    }
    return dns;
  }

  static Object? fakeDnsObject(
    RoutingTemplate template, {
    Object? profileFakeDns,
  }) {
    if (template.fakeDnsEnabled == false) return null;
    if (template.xrayFakeDnsConfig != null) return template.xrayFakeDnsConfig;
    if (template.usesFakeDns) return profileFakeDns ?? _defaultFakeDns;
    return profileFakeDns;
  }

  static bool needsInterception(RoutingTemplate template) =>
      controlsDns(template);

  static List<Map<String, dynamic>> resolverRoutingRules(
    RoutingTemplate template,
    Map<RoutingAction, String> targetForAction,
  ) {
    final dns = template.dnsSettings;
    final rules = <Map<String, dynamic>>[
      for (final route in template.dnsRoutes)
        {
          'type': 'field',
          'inboundTag': [route.inboundTag],
          'outboundTag': targetForAction[route.action],
        },
    ];
    if (dns == null) return rules;
    final proxyDomains = domainsForAction(template, RoutingAction.proxy);
    final directDomains = domainsForAction(template, RoutingAction.direct);
    if (_hasProvider(dns.remoteProvider, dns.remoteServer) &&
        (template.defaultAction == RoutingAction.proxy ||
            proxyDomains.isNotEmpty ||
            _fallbackAction(template, dns) == RoutingAction.proxy)) {
      rules.add({
        'type': 'field',
        'inboundTag': [remoteServerTag],
        'outboundTag': targetForAction[RoutingAction.proxy],
      });
    }
    if (_hasProvider(dns.domesticProvider, dns.domesticServer) &&
        (template.defaultAction == RoutingAction.direct ||
            directDomains.isNotEmpty ||
            _fallbackAction(template, dns) == RoutingAction.direct)) {
      rules.add({
        'type': 'field',
        'inboundTag': [domesticServerTag],
        'outboundTag': targetForAction[RoutingAction.direct],
      });
    }
    return rules;
  }

  static List<String> domainsForAction(
    RoutingTemplate template,
    RoutingAction action,
  ) {
    final domains = <String>{};
    for (final rule in template.rules.where((rule) => rule.action == action)) {
      final values = rule.domains.isNotEmpty
          ? rule.domains
          : rule.type == RoutingTargetType.domain
              ? [rule.value]
              : const <String>[];
      for (final value in values) {
        final trimmed = value.trim();
        if (trimmed.isEmpty) continue;
        domains.add(
            RegExp(r'^(domain|full|keyword|regexp|geosite|dotless|ext):')
                    .hasMatch(trimmed)
                ? trimmed
                : 'domain:$trimmed');
      }
    }
    return domains.toList(growable: false);
  }

  static List<dynamic> _buildServers(
    RoutingTemplate template,
    RoutingDnsSettings settings,
    List<dynamic> previousServers,
  ) {
    final result = <dynamic>[];
    final proxyDomains = domainsForAction(template, RoutingAction.proxy);
    final directDomains = domainsForAction(template, RoutingAction.direct);

    if (template.usesFakeDns) {
      if (template.defaultAction == RoutingAction.proxy) {
        result.add('fakedns');
      } else if (proxyDomains.isNotEmpty) {
        result.add({'address': 'fakedns', 'domains': proxyDomains});
      }
    }

    void addActionServer({
      required RoutingAction action,
      required RoutingDnsProvider? provider,
      required String? server,
      required String tag,
      required List<String> domains,
    }) {
      if (provider == RoutingDnsProvider.internal) {
        for (final previous in previousServers) {
          if (_isFakeDnsServer(previous)) continue;
          final entry = previous is String
              ? <String, Object?>{'address': previous}
              : previous is Map
                  ? Map<String, Object?>.from(previous)
                  : null;
          if (entry == null || entry['address'] is! String) continue;
          entry['tag'] = tag;
          if (action != template.defaultAction) {
            if (domains.isEmpty) continue;
            entry
              ..['domains'] = domains
              ..['skipFallback'] = true;
          }
          result.add(entry);
        }
        return;
      }
      if (server == null) return;
      final entry = <String, Object?>{
        'address': server,
        'tag': tag,
      };
      if (action == template.defaultAction) {
        result.add(entry);
      } else if (domains.isNotEmpty) {
        entry
          ..['domains'] = domains
          ..['skipFallback'] = true;
        result.add(entry);
      }
    }

    addActionServer(
      action: RoutingAction.proxy,
      provider: settings.remoteProvider,
      server: settings.remoteServer,
      tag: remoteServerTag,
      domains: proxyDomains,
    );
    addActionServer(
      action: RoutingAction.direct,
      provider: settings.domesticProvider,
      server: settings.domesticServer,
      tag: domesticServerTag,
      domains: directDomains,
    );

    if (!result.any((server) =>
        !_isFakeDnsServer(server) &&
        !(server is Map && server['skipFallback'] == true))) {
      final action = _fallbackAction(template, settings);
      if (action != null) {
        final provider = action == RoutingAction.direct
            ? settings.domesticProvider
            : settings.remoteProvider;
        final fallback = action == RoutingAction.direct
            ? settings.domesticServer
            : settings.remoteServer;
        final tag = action == RoutingAction.direct
            ? domesticServerTag
            : remoteServerTag;
        addActionServer(
          action: action,
          provider: provider,
          server: fallback,
          tag: tag,
          domains:
              action == RoutingAction.direct ? directDomains : proxyDomains,
        );
      }
    }

    final preserveExistingFake = template.fakeDnsEnabled == null &&
        previousServers.any(_isFakeDnsServer);
    if (preserveExistingFake) {
      for (final server in previousServers.where(_isFakeDnsServer)) {
        if (!_containsFakeDns(result)) result.insert(0, server);
      }
    }
    final hasInternalProvider =
        settings.remoteProvider == RoutingDnsProvider.internal ||
            settings.domesticProvider == RoutingDnsProvider.internal;
    if (!hasInternalProvider) {
      for (final server in previousServers) {
        if (_isFakeDnsServer(server)) continue;
        if (!result.contains(server)) result.add(server);
      }
    }
    return result;
  }

  static Object? _fakeDnsServer(RoutingTemplate template) {
    if (template.defaultAction == RoutingAction.proxy) return 'fakedns';
    final proxyDomains = domainsForAction(template, RoutingAction.proxy);
    if (proxyDomains.isEmpty) return null;
    return {'address': 'fakedns', 'domains': proxyDomains};
  }

  static RoutingAction? _fallbackAction(
    RoutingTemplate template,
    RoutingDnsSettings settings,
  ) {
    if (template.defaultAction == RoutingAction.direct &&
        _hasProvider(settings.domesticProvider, settings.domesticServer)) {
      return RoutingAction.direct;
    }
    if (template.defaultAction == RoutingAction.proxy &&
        _hasProvider(settings.remoteProvider, settings.remoteServer)) {
      return RoutingAction.proxy;
    }
    if (_hasProvider(settings.remoteProvider, settings.remoteServer)) {
      return RoutingAction.proxy;
    }
    if (_hasProvider(settings.domesticProvider, settings.domesticServer)) {
      return RoutingAction.direct;
    }
    return null;
  }

  static bool _hasProvider(
    RoutingDnsProvider? provider,
    String? server,
  ) =>
      provider == RoutingDnsProvider.internal || server != null;

  static bool _containsFakeDns(List<dynamic> servers) =>
      servers.any(_isFakeDnsServer);

  static bool _isFakeDnsServer(Object? server) =>
      server == 'fakedns' || (server is Map && server['address'] == 'fakedns');

  static void _addBootstrapHost(
    Map<String, dynamic> hosts,
    String? server,
    String? bootstrapIp,
  ) {
    if (server == null || bootstrapIp == null) return;
    final uri = Uri.tryParse(server);
    if (uri != null &&
        uri.hasAuthority &&
        uri.host.isNotEmpty &&
        InternetAddress.tryParse(uri.host) == null) {
      hosts.putIfAbsent(uri.host, () => bootstrapIp);
    }
  }
}
