import 'dart:convert';

enum VpnRoutingMode {
  vpnExceptListed,
  vpnOnlyListed,
}

enum RoutingAction {
  direct,
  proxy,
  block,
}

enum RoutingTargetType {
  domain,
  ip,
  port,
}

enum RoutingDnsProvider {
  internal,
  google,
  cloudflare,
  quad9,
  adguard,
  custom,
}

class RoutingDnsProviderPreset {
  const RoutingDnsProviderPreset(this.server, this.bootstrapIp);

  final String server;
  final String bootstrapIp;

  static RoutingDnsProviderPreset? forProvider(RoutingDnsProvider provider) =>
      switch (provider) {
        RoutingDnsProvider.google => const RoutingDnsProviderPreset(
            'https://dns.google/dns-query',
            '8.8.8.8',
          ),
        RoutingDnsProvider.cloudflare => const RoutingDnsProviderPreset(
            'https://cloudflare-dns.com/dns-query',
            '1.1.1.1',
          ),
        RoutingDnsProvider.quad9 => const RoutingDnsProviderPreset(
            'https://dns.quad9.net/dns-query',
            '9.9.9.9',
          ),
        RoutingDnsProvider.adguard => const RoutingDnsProviderPreset(
            'https://dns.adguard-dns.com/dns-query',
            '94.140.14.14',
          ),
        RoutingDnsProvider.internal || RoutingDnsProvider.custom => null,
      };
}

class GlobalDnsSettings {
  const GlobalDnsSettings({
    this.provider = RoutingDnsProvider.internal,
    this.customServer,
    this.customBootstrapIp,
  });

  final RoutingDnsProvider provider;
  final String? customServer;
  final String? customBootstrapIp;

  bool get enabled => provider != RoutingDnsProvider.internal;

  String? get server => provider == RoutingDnsProvider.custom
      ? customServer
      : RoutingDnsProviderPreset.forProvider(provider)?.server;

  String? get bootstrapIp => provider == RoutingDnsProvider.custom
      ? customBootstrapIp
      : RoutingDnsProviderPreset.forProvider(provider)?.bootstrapIp;

  String encode() => jsonEncode({
        'provider': provider.name,
        if (customServer != null) 'customServer': customServer,
        if (customBootstrapIp != null) 'customBootstrapIp': customBootstrapIp,
      });

  static GlobalDnsSettings decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return const GlobalDnsSettings();
    final provider =
        _enumValue(RoutingDnsProvider.values, decoded['provider']) ??
            RoutingDnsProvider.internal;
    String? readString(String key) {
      final value = decoded[key];
      return value is String && value.trim().isNotEmpty ? value.trim() : null;
    }

    return GlobalDnsSettings(
      provider: provider,
      customServer: readString('customServer'),
      customBootstrapIp: readString('customBootstrapIp'),
    );
  }
}

class VpnRoutingRule {
  const VpnRoutingRule({
    required this.type,
    required this.value,
    this.action = RoutingAction.direct,
    this.label,
    this.domains = const [],
    this.ips = const [],
    this.ports = const [],
    this.networks = const [],
    this.protocols = const [],
  });

  final RoutingTargetType type;
  final String value;
  final RoutingAction action;
  final String? label;

  /// Xray rules can combine these conditions with AND semantics. Keeping them
  /// together lets imported rules retain that behavior.
  final List<String> domains;
  final List<String> ips;
  final List<String> ports;
  final List<String> networks;
  final List<String> protocols;

  bool get hasDomainTarget =>
      domains.isNotEmpty || type == RoutingTargetType.domain;

  String get displayValue {
    final terms = <String>[
      ...domains,
      ...ips,
      ...ports.map((port) => 'порт $port'),
      ...networks.map((network) => 'сеть $network'),
      ...protocols.map((protocol) => 'протокол $protocol'),
    ];
    if (terms.isNotEmpty) return terms.join(' · ');
    return value;
  }

  Map<String, Object?> toJson() => {
        'type': type.name,
        'value': value,
        'action': action.name,
        if (label != null) 'label': label,
        if (domains.isNotEmpty) 'domains': domains,
        if (ips.isNotEmpty) 'ips': ips,
        if (ports.isNotEmpty) 'ports': ports,
        if (networks.isNotEmpty) 'networks': networks,
        if (protocols.isNotEmpty) 'protocols': protocols,
      };

  static VpnRoutingRule? fromJson(Object? value) {
    if (value is! Map) return null;
    final typeName = value['type'];
    final text = value['value'];
    final types =
        RoutingTargetType.values.where((item) => item.name == typeName);
    if (types.isEmpty || text is! String || text.trim().isEmpty) return null;

    final action = _enumValue(RoutingAction.values, value['action']) ??
        RoutingAction.direct;
    return VpnRoutingRule(
      type: types.first,
      value: text.trim(),
      action: action,
      label: value['label'] is String ? value['label'] as String : null,
      domains: _stringList(value['domains']),
      ips: _stringList(value['ips']),
      ports: _stringList(value['ports']),
      networks: _stringList(value['networks']),
      protocols: _stringList(value['protocols']),
    );
  }
}

class RoutingDnsSettings {
  const RoutingDnsSettings({
    this.remoteProvider,
    this.remoteServer,
    this.remoteBootstrapIp,
    this.domesticProvider,
    this.domesticServer,
    this.domesticBootstrapIp,
    this.hosts = const {},
  });

  final RoutingDnsProvider? remoteProvider;

  /// An Xray DNS address: an IP address for UDP or an HTTPS URL for DoH.
  final String? remoteServer;
  final String? remoteBootstrapIp;
  final RoutingDnsProvider? domesticProvider;
  final String? domesticServer;
  final String? domesticBootstrapIp;
  final Map<String, String> hosts;

  bool get hasSettings =>
      remoteProvider != null ||
      remoteServer != null ||
      remoteBootstrapIp != null ||
      domesticProvider != null ||
      domesticServer != null ||
      domesticBootstrapIp != null ||
      hosts.isNotEmpty;

  Map<String, Object?> toJson() => {
        if (remoteProvider != null) 'remoteProvider': remoteProvider!.name,
        if (remoteServer != null) 'remoteServer': remoteServer,
        if (remoteBootstrapIp != null) 'remoteBootstrapIp': remoteBootstrapIp,
        if (domesticProvider != null)
          'domesticProvider': domesticProvider!.name,
        if (domesticServer != null) 'domesticServer': domesticServer,
        if (domesticBootstrapIp != null)
          'domesticBootstrapIp': domesticBootstrapIp,
        if (hosts.isNotEmpty) 'hosts': hosts,
      };

  static RoutingDnsSettings? fromJson(Object? value) {
    if (value is! Map) return null;
    final hosts = <String, String>{};
    final rawHosts = value['hosts'];
    if (rawHosts is Map) {
      for (final entry in rawHosts.entries) {
        if (entry.key is String && entry.value is String) {
          final domain = (entry.key as String).trim();
          final address = (entry.value as String).trim();
          if (domain.isNotEmpty && address.isNotEmpty) hosts[domain] = address;
        }
      }
    }
    String? readString(String key) {
      final raw = value[key];
      return raw is String && raw.trim().isNotEmpty ? raw.trim() : null;
    }

    final settings = RoutingDnsSettings(
      remoteProvider:
          _enumValue(RoutingDnsProvider.values, value['remoteProvider']),
      remoteServer: readString('remoteServer'),
      remoteBootstrapIp: readString('remoteBootstrapIp'),
      domesticProvider:
          _enumValue(RoutingDnsProvider.values, value['domesticProvider']),
      domesticServer: readString('domesticServer'),
      domesticBootstrapIp: readString('domesticBootstrapIp'),
      hosts: hosts,
    );
    return settings.hasSettings ? settings : null;
  }
}

class RoutingDnsRoute {
  const RoutingDnsRoute({required this.inboundTag, required this.action});

  final String inboundTag;
  final RoutingAction action;

  Map<String, Object?> toJson() => {
        'inboundTag': inboundTag,
        'action': action.name,
      };

  static RoutingDnsRoute? fromJson(Object? value) {
    if (value is! Map ||
        value['inboundTag'] is! String ||
        (value['inboundTag'] as String).trim().isEmpty) {
      return null;
    }
    final action = _enumValue(RoutingAction.values, value['action']);
    if (action == null) return null;
    return RoutingDnsRoute(
      inboundTag: (value['inboundTag'] as String).trim(),
      action: action,
    );
  }
}

class RoutingTemplate {
  const RoutingTemplate({
    required this.id,
    required this.name,
    this.defaultAction = RoutingAction.proxy,
    this.domainStrategy,
    this.geoipUrl,
    this.geositeUrl,
    this.dnsSettings,
    this.xrayDnsConfig,
    this.fakeDnsEnabled,
    this.xrayFakeDnsConfig,
    this.dnsRoutes = const [],
    this.rules = const [],
  });

  final String id;
  final String name;
  final RoutingAction defaultAction;
  final String? domainStrategy;
  final String? geoipUrl;
  final String? geositeUrl;
  final RoutingDnsSettings? dnsSettings;
  final Map<String, dynamic>? xrayDnsConfig;

  /// Null preserves the imported Xray setting; true/false overrides it.
  final bool? fakeDnsEnabled;
  final Object? xrayFakeDnsConfig;
  final List<RoutingDnsRoute> dnsRoutes;
  final List<VpnRoutingRule> rules;

  bool get usesFakeDns {
    if (fakeDnsEnabled != null) return fakeDnsEnabled!;
    if (xrayFakeDnsConfig != null) return true;
    final servers = xrayDnsConfig?['servers'];
    return servers is List &&
        servers.any((server) =>
            server == 'fakedns' ||
            (server is Map && server['address'] == 'fakedns'));
  }

  RoutingTemplate copyWith({
    String? id,
    String? name,
    RoutingAction? defaultAction,
    String? domainStrategy,
    bool clearDomainStrategy = false,
    String? geoipUrl,
    bool clearGeoipUrl = false,
    String? geositeUrl,
    bool clearGeositeUrl = false,
    RoutingDnsSettings? dnsSettings,
    bool clearDnsSettings = false,
    Map<String, dynamic>? xrayDnsConfig,
    bool clearXrayDnsConfig = false,
    bool? fakeDnsEnabled,
    Object? xrayFakeDnsConfig,
    bool clearXrayFakeDnsConfig = false,
    List<RoutingDnsRoute>? dnsRoutes,
    List<VpnRoutingRule>? rules,
  }) =>
      RoutingTemplate(
        id: id ?? this.id,
        name: name ?? this.name,
        defaultAction: defaultAction ?? this.defaultAction,
        domainStrategy:
            clearDomainStrategy ? null : domainStrategy ?? this.domainStrategy,
        geoipUrl: clearGeoipUrl ? null : geoipUrl ?? this.geoipUrl,
        geositeUrl: clearGeositeUrl ? null : geositeUrl ?? this.geositeUrl,
        dnsSettings: clearDnsSettings ? null : dnsSettings ?? this.dnsSettings,
        xrayDnsConfig:
            clearXrayDnsConfig ? null : xrayDnsConfig ?? this.xrayDnsConfig,
        fakeDnsEnabled: fakeDnsEnabled ?? this.fakeDnsEnabled,
        xrayFakeDnsConfig: clearXrayFakeDnsConfig
            ? null
            : xrayFakeDnsConfig ?? this.xrayFakeDnsConfig,
        dnsRoutes: dnsRoutes ?? this.dnsRoutes,
        rules: rules ?? this.rules,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'defaultAction': defaultAction.name,
        if (domainStrategy != null) 'domainStrategy': domainStrategy,
        if (geoipUrl != null) 'geoipUrl': geoipUrl,
        if (geositeUrl != null) 'geositeUrl': geositeUrl,
        if (dnsSettings != null) 'dnsSettings': dnsSettings!.toJson(),
        if (xrayDnsConfig != null) 'xrayDnsConfig': xrayDnsConfig,
        if (fakeDnsEnabled != null) 'fakeDnsEnabled': fakeDnsEnabled,
        if (xrayFakeDnsConfig != null) 'xrayFakeDnsConfig': xrayFakeDnsConfig,
        if (dnsRoutes.isNotEmpty)
          'dnsRoutes': dnsRoutes.map((route) => route.toJson()).toList(),
        'rules': rules.map((rule) => rule.toJson()).toList(),
      };

  static RoutingTemplate? fromJson(Object? value) {
    if (value is! Map) return null;
    final rawId = value['id'];
    final rawName = value['name'];
    if (rawId is! String || rawName is! String) return null;
    final rawRules = value['rules'];
    final rules = rawRules is List
        ? rawRules
            .map(VpnRoutingRule.fromJson)
            .whereType<VpnRoutingRule>()
            .toList()
        : const <VpnRoutingRule>[];
    final strategy = value['domainStrategy'];
    final rawDns = value['xrayDnsConfig'];
    final rawFakeDns = value['xrayFakeDnsConfig'];
    final rawDnsRoutes = value['dnsRoutes'];
    final dnsRoutes = rawDnsRoutes is List
        ? rawDnsRoutes
            .map(RoutingDnsRoute.fromJson)
            .whereType<RoutingDnsRoute>()
            .toList()
        : const <RoutingDnsRoute>[];
    return RoutingTemplate(
      id: rawId,
      name: rawName,
      defaultAction: _enumValue(RoutingAction.values, value['defaultAction']) ??
          RoutingAction.proxy,
      domainStrategy: strategy is String ? strategy : null,
      geoipUrl:
          value['geoipUrl'] is String ? value['geoipUrl'] as String : null,
      geositeUrl:
          value['geositeUrl'] is String ? value['geositeUrl'] as String : null,
      dnsSettings: RoutingDnsSettings.fromJson(value['dnsSettings']),
      xrayDnsConfig: rawDns is Map ? Map<String, dynamic>.from(rawDns) : null,
      fakeDnsEnabled: value['fakeDnsEnabled'] is bool
          ? value['fakeDnsEnabled'] as bool
          : null,
      xrayFakeDnsConfig:
          rawFakeDns is Map || rawFakeDns is List ? rawFakeDns : null,
      dnsRoutes: dnsRoutes,
      rules: rules,
    );
  }
}

class VpnRoutingSettings {
  const VpnRoutingSettings({
    this.enabled = false,
    VpnRoutingMode mode = VpnRoutingMode.vpnExceptListed,
    List<VpnRoutingRule> rules = const [],
    this.templates = const [],
    this.activeTemplateId,
  })  : _legacyMode = mode,
        _legacyRules = rules;

  final bool enabled;
  final List<RoutingTemplate> templates;
  final String? activeTemplateId;
  final VpnRoutingMode _legacyMode;
  final List<VpnRoutingRule> _legacyRules;

  RoutingTemplate get activeTemplate {
    if (templates.isNotEmpty) {
      return templates.firstWhere(
        (template) => template.id == activeTemplateId,
        orElse: () => templates.first,
      );
    }
    final defaultAction = _legacyMode == VpnRoutingMode.vpnExceptListed
        ? RoutingAction.proxy
        : RoutingAction.direct;
    final listedAction = _legacyMode == VpnRoutingMode.vpnExceptListed
        ? RoutingAction.direct
        : RoutingAction.proxy;
    return RoutingTemplate(
      id: 'manual',
      name: 'Мои правила',
      defaultAction: defaultAction,
      rules: _legacyRules
          .map((rule) => VpnRoutingRule(
                type: rule.type,
                value: rule.value,
                action: rule.action == RoutingAction.direct &&
                        _legacyMode == VpnRoutingMode.vpnOnlyListed
                    ? listedAction
                    : rule.action,
              ))
          .toList(growable: false),
    );
  }

  // Compatibility getters for the previous single-list settings page.
  VpnRoutingMode get mode =>
      activeTemplate.defaultAction == RoutingAction.direct
          ? VpnRoutingMode.vpnOnlyListed
          : VpnRoutingMode.vpnExceptListed;

  List<VpnRoutingRule> get rules => activeTemplate.rules;

  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'activeTemplateId': activeTemplateId,
        'templates': templates.map((template) => template.toJson()).toList(),
      };

  String encode() => jsonEncode(toJson());

  static VpnRoutingSettings decode(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map) return const VpnRoutingSettings();
      final enabled = decoded['enabled'] == true;
      final rawTemplates = decoded['templates'];
      if (rawTemplates is List) {
        final templates = rawTemplates
            .map(RoutingTemplate.fromJson)
            .whereType<RoutingTemplate>()
            .toList(growable: false);
        final activeId = decoded['activeTemplateId'];
        return VpnRoutingSettings(
          enabled: enabled,
          templates: templates,
          activeTemplateId: activeId is String ? activeId : null,
        );
      }

      // Migrate the original single-list settings stored by earlier builds.
      final mode = _enumValue(VpnRoutingMode.values, decoded['mode']) ??
          VpnRoutingMode.vpnExceptListed;
      final rawRules = decoded['rules'];
      final rules = rawRules is List
          ? rawRules
              .map(VpnRoutingRule.fromJson)
              .whereType<VpnRoutingRule>()
              .toList()
          : const <VpnRoutingRule>[];
      return VpnRoutingSettings(enabled: enabled, mode: mode, rules: rules);
    } on FormatException {
      return const VpnRoutingSettings();
    }
  }
}

T? _enumValue<T extends Enum>(List<T> values, Object? name) {
  if (name is! String) return null;
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}

List<String> _stringList(Object? value) {
  if (value is! List) return const [];
  return value
      .whereType<String>()
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList();
}
