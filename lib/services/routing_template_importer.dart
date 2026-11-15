import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/vpn_routing_settings.dart';
import 'xray_dns_configuration.dart';

class RoutingTemplateImportResult {
  const RoutingTemplateImportResult({
    required this.template,
    this.warnings = const [],
  });

  final RoutingTemplate template;
  final List<String> warnings;
}

class RoutingTemplateImporter {
  const RoutingTemplateImporter._();

  static const _maxRemoteTemplateBytes = 2 * 1024 * 1024;

  static Future<String> resolveInput(
    String input, {
    HttpClient? client,
  }) async {
    final raw = input.trim();
    final uri = Uri.tryParse(raw);
    if (uri == null || !{'http', 'https'}.contains(uri.scheme.toLowerCase())) {
      return raw;
    }
    if (uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('Укажите корректную HTTPS-ссылку.');
    }

    final httpClient = client ?? HttpClient();
    try {
      final request =
          await httpClient.getUrl(uri).timeout(const Duration(seconds: 15));
      request.followRedirects = true;
      request.maxRedirects = 5;
      request.headers
          .set(HttpHeaders.acceptHeader, 'application/json, text/plain, */*');
      request.headers.set(HttpHeaders.userAgentHeader, 'OksanaVPN-Desktop');

      final response =
          await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw FormatException(
          'Не удалось загрузить шаблон по ссылке (HTTP ${response.statusCode}).',
        );
      }
      if (response.contentLength > _maxRemoteTemplateBytes) {
        await response.drain<void>();
        throw const FormatException(
          'Файл маршрутизации слишком большой (максимум 2 МБ).',
        );
      }

      final body = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        if (body.length + chunk.length > _maxRemoteTemplateBytes) {
          throw const FormatException(
            'Файл маршрутизации слишком большой (максимум 2 МБ).',
          );
        }
        body.add(chunk);
      }
      return utf8.decode(body.takeBytes());
    } on FormatException {
      rethrow;
    } on SocketException {
      throw const FormatException(
        'Не удалось подключиться по ссылке. Проверьте интернет-соединение.',
      );
    } on TimeoutException {
      throw const FormatException(
        'Ссылка отвечает слишком долго. Попробуйте ещё раз.',
      );
    } on HttpException {
      throw const FormatException('Не удалось загрузить шаблон по ссылке.');
    } finally {
      if (client == null) httpClient.close(force: true);
    }
  }

  static String exportXrayJson(RoutingTemplate template) {
    const outboundTags = {
      RoutingAction.direct: 'direct',
      RoutingAction.proxy: 'proxy',
      RoutingAction.block: 'block',
    };
    final rules = <Map<String, Object?>>[
      for (final rule in template.rules) _exportRule(rule),
      ...XrayDnsConfiguration.resolverRoutingRules(template, outboundTags),
      {
        'type': 'field',
        'network': 'tcp,udp',
        'outboundTag': _outboundName(template.defaultAction),
      },
    ];
    final dns = XrayDnsConfiguration.controlsDns(template)
        ? XrayDnsConfiguration.buildDns(template)
        : null;
    final fakeDns = XrayDnsConfiguration.fakeDnsObject(template);
    return const JsonEncoder.withIndent('  ').convert({
      'name': template.name,
      if (template.domainStrategy != null)
        'domainStrategy': template.domainStrategy,
      if (template.geoipUrl != null) 'Geoipurl': template.geoipUrl,
      if (template.geositeUrl != null) 'Geositeurl': template.geositeUrl,
      if (dns != null && dns.isNotEmpty) 'dns': dns,
      if (fakeDns != null) 'fakedns': fakeDns,
      'rules': rules,
    });
  }

  static Map<String, Object?> _exportRule(VpnRoutingRule rule) {
    final hasStructuredConditions = rule.domains.isNotEmpty ||
        rule.ips.isNotEmpty ||
        rule.ports.isNotEmpty ||
        rule.networks.isNotEmpty ||
        rule.protocols.isNotEmpty;
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
    return {
      if (rule.label != null) '__name__': rule.label,
      'type': 'field',
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
      'outboundTag': _outboundName(rule.action),
    };
  }

  static RoutingTemplateImportResult parse(String input) {
    final source = _unwrapImport(input.trim());
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      try {
        decoded = jsonDecode(_decodeBase64(source));
      } on FormatException {
        throw const FormatException(
          'Не удалось прочитать JSON или ссылку на шаблон маршрутизации.',
        );
      }
    }
    if (decoded is! Map) {
      throw const FormatException(
          'В файле должен быть JSON-объект маршрутизации.');
    }

    if (_hasLegacyRoutingFields(decoded)) {
      return _parseCompatibleTemplate(decoded);
    }
    return _parseXray(decoded);
  }

  static String _unwrapImport(String input) {
    if (input.isEmpty) throw const FormatException('Вставьте ссылку или JSON.');
    final uri = Uri.tryParse(input);
    if (uri == null || !{'happ', 'incy'}.contains(uri.scheme.toLowerCase())) {
      return input;
    }

    final segments = <String>[
      if (uri.host.isNotEmpty) uri.host,
      ...uri.pathSegments,
    ];
    final routingIndex = segments.indexWhere((segment) => segment == 'routing');
    if (routingIndex < 0 || segments.length <= routingIndex + 2) {
      throw const FormatException('Ссылка не содержит шаблон маршрутизации.');
    }
    final command = segments[routingIndex + 1];
    if (command != 'add' && command != 'onadd') {
      throw const FormatException('Эта ссылка не добавляет шаблон.');
    }
    final encoded = segments.sublist(routingIndex + 2).join('/');
    try {
      return _decodeBase64(encoded);
    } on FormatException {
      throw const FormatException('В ссылке повреждён шаблон.');
    }
  }

  static String _decodeBase64(String value) {
    try {
      return utf8.decode(base64Url.decode(base64Url.normalize(value)));
    } on FormatException {
      return utf8.decode(base64.decode(base64.normalize(value)));
    }
  }

  static bool _hasLegacyRoutingFields(Map<dynamic, dynamic> json) {
    const fields = {
      'DirectSites',
      'DirectIp',
      'ProxySites',
      'ProxyIp',
      'BlockSites',
      'BlockIp',
    };
    return fields.any(json.containsKey) ||
        (json.containsKey('GlobalProxy') &&
            !json.containsKey('rules') &&
            !json.containsKey('routing'));
  }

  static RoutingTemplateImportResult _parseCompatibleTemplate(
      Map<dynamic, dynamic> json) {
    final rulesByAction = {
      for (final action in RoutingAction.values) action: <VpnRoutingRule>[],
    };
    final warnings = <String>[];
    void addValues(String key, RoutingTargetType type, RoutingAction action) {
      final raw = json[key];
      if (raw == null) return;
      if (raw is! List) {
        warnings.add('$key пропущено: ожидался список.');
        return;
      }
      for (final item in raw.whereType<String>()) {
        final cleaned = item.trim();
        if (cleaned.isEmpty) continue;
        rulesByAction[action]!.add(VpnRoutingRule(
          type: type,
          value: cleaned,
          action: action,
        ));
      }
    }

    addValues('DirectSites', RoutingTargetType.domain, RoutingAction.direct);
    addValues('DirectIp', RoutingTargetType.ip, RoutingAction.direct);
    addValues('ProxySites', RoutingTargetType.domain, RoutingAction.proxy);
    addValues('ProxyIp', RoutingTargetType.ip, RoutingAction.proxy);
    addValues('BlockSites', RoutingTargetType.domain, RoutingAction.block);
    addValues('BlockIp', RoutingTargetType.ip, RoutingAction.block);
    final rules = [
      for (final action
          in _readTemplateRouteOrder(json['RouteOrder'], warnings))
        ...rulesByAction[action]!,
    ];
    final geoipUrl = _readGeoDataUrl(json['Geoipurl'], 'Geoipurl', warnings);
    final geositeUrl =
        _readGeoDataUrl(json['Geositeurl'], 'Geositeurl', warnings);

    final dnsSettings = _readCompatibleDnsSettings(json, warnings);

    final strategyValue = json['DomainStrategy'];
    final strategy = switch (strategyValue) {
      'AsIs' => 'AsIs',
      'IPIfNonMatch' => 'IPIfNonMatch',
      'IPOnDemand' => 'IPOnDemand',
      _ => null,
    };
    if (strategyValue != null && strategy == null) {
      warnings.add('Неизвестная стратегия доменов пропущена.');
    }
    final name = _readName(json['Name'], 'Импортированный шаблон');
    return RoutingTemplateImportResult(
      template: RoutingTemplate(
        id: '',
        name: name,
        defaultAction: _globalProxyAction(json['GlobalProxy']),
        domainStrategy: strategy,
        geoipUrl: geoipUrl,
        geositeUrl: geositeUrl,
        dnsSettings: dnsSettings.settings,
        fakeDnsEnabled: dnsSettings.fakeDnsEnabled,
        rules: rules,
      ),
      warnings: warnings,
    );
  }

  static List<RoutingAction> _readTemplateRouteOrder(
    Object? raw,
    List<String> warnings,
  ) {
    const fallbackOrder = [
      RoutingAction.direct,
      RoutingAction.proxy,
      RoutingAction.block,
    ];
    if (raw == null) return fallbackOrder;
    if (raw is! String) {
      warnings.add('Порядок правил не распознан, используется стандартный.');
      return fallbackOrder;
    }

    final actions = raw
        .toLowerCase()
        .split(RegExp(r'[^a-z]+'))
        .where((part) => part.isNotEmpty)
        .map((part) => switch (part) {
              'direct' => RoutingAction.direct,
              'proxy' => RoutingAction.proxy,
              'block' => RoutingAction.block,
              _ => null,
            })
        .toList(growable: false);
    if (actions.length != 3 ||
        actions.any((action) => action == null) ||
        actions.toSet().length != 3) {
      warnings.add('Порядок правил не распознан, используется стандартный.');
      return fallbackOrder;
    }
    return actions.cast<RoutingAction>();
  }

  static String? _readGeoDataUrl(
    Object? value,
    String field,
    List<String> warnings,
  ) {
    if (value == null || value == false) return null;
    if (value is! String || value.trim().isEmpty) {
      warnings.add('$field пропущено: ожидалась HTTPS-ссылка.');
      return null;
    }
    final url = value.trim();
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      warnings.add('$field пропущено: разрешены только HTTPS-ссылки.');
      return null;
    }
    return url;
  }

  static ({RoutingDnsSettings? settings, bool? fakeDnsEnabled})
      _readCompatibleDnsSettings(
    Map<dynamic, dynamic> json,
    List<String> warnings,
  ) {
    String? readIp(Object? raw, String field) {
      if (raw == null || raw == false) return null;
      if (raw is String && raw.trim().isEmpty) return null;
      if (raw is! String || raw.trim().isEmpty) {
        warnings.add('$field пропущено: ожидался IP-адрес.');
        return null;
      }
      final address = raw.trim();
      if (InternetAddress.tryParse(address) == null) {
        warnings.add('$field пропущено: указан некорректный IP-адрес.');
        return null;
      }
      return address;
    }

    String? readDohUrl(Object? raw, String field) {
      if (raw == null || raw == false) return null;
      if (raw is String && raw.trim().isEmpty) return null;
      if (raw is! String || raw.trim().isEmpty) {
        warnings.add('$field пропущено: ожидалась HTTPS-ссылка DoH.');
        return null;
      }
      final value = raw.trim();
      final uri = Uri.tryParse(value);
      if (uri == null ||
          uri.scheme.toLowerCase() != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        warnings.add('$field пропущено: разрешены только HTTPS-ссылки DoH.');
        return null;
      }
      return value;
    }

    String? readEndpoint({
      required Object? typeValue,
      required Object? domainValue,
      required String? ipValue,
      required String typeField,
      required String domainField,
    }) {
      final type = typeValue is String ? typeValue.trim().toLowerCase() : '';
      if (type == 'doh') return readDohUrl(domainValue, domainField);
      if (type == 'dou') {
        return ipValue ?? readIp(domainValue, domainField);
      }
      if (type.isNotEmpty) {
        warnings.add('$typeField пропущено: поддерживаются DoH и DoU.');
        return null;
      }
      final address = _optionalString(domainValue);
      if (address != null && address.toLowerCase().startsWith('https://')) {
        return readDohUrl(address, domainField);
      }
      return ipValue ?? readIp(address, domainField);
    }

    final remoteIpRaw = json['RemoteDNSIP'] ?? json['RemoteDns'];
    final domesticIpRaw = json['DomesticDNSIP'] ?? json['DomesticDns'];
    final remoteBootstrapIp = readIp(remoteIpRaw, 'RemoteDNSIP');
    final domesticBootstrapIp = readIp(domesticIpRaw, 'DomesticDNSIP');
    final remoteServer = readEndpoint(
      typeValue: json['RemoteDNSType'],
      domainValue: json['RemoteDNSDomain'],
      ipValue: remoteBootstrapIp,
      typeField: 'RemoteDNSType',
      domainField: 'RemoteDNSDomain',
    );
    final domesticServer = readEndpoint(
      typeValue: json['DomesticDNSType'],
      domainValue: json['DomesticDNSDomain'],
      ipValue: domesticBootstrapIp,
      typeField: 'DomesticDNSType',
      domainField: 'DomesticDNSDomain',
    );

    final hosts = <String, String>{};
    final rawHosts = json['DnsHosts'];
    if (rawHosts != null) {
      if (rawHosts is! Map) {
        warnings.add('DnsHosts пропущено: ожидался объект доменов и IP.');
      } else {
        for (final entry in rawHosts.entries) {
          if (entry.key is! String || entry.value is! String) continue;
          final domain = (entry.key as String).trim();
          final address = (entry.value as String).trim();
          if (domain.isEmpty || InternetAddress.tryParse(address) == null) {
            warnings.add('Одна запись DnsHosts пропущена: некорректный IP.');
            continue;
          }
          hosts[domain] = address;
        }
      }
    }

    final settings = RoutingDnsSettings(
      remoteServer: remoteServer,
      remoteBootstrapIp: remoteBootstrapIp,
      domesticServer: domesticServer,
      domesticBootstrapIp: domesticBootstrapIp,
      hosts: hosts,
    );
    final fakeDnsRaw = json['FakeDNS'];
    bool? fakeDnsEnabled;
    if (fakeDnsRaw == true ||
        (fakeDnsRaw is String && fakeDnsRaw.trim().toLowerCase() == 'true')) {
      fakeDnsEnabled = true;
    } else if (fakeDnsRaw == false ||
        (fakeDnsRaw is String && fakeDnsRaw.trim().toLowerCase() == 'false')) {
      fakeDnsEnabled = false;
    } else if (fakeDnsRaw != null) {
      warnings.add('FakeDNS пропущено: ожидается true или false.');
    }

    for (final key in ['DnsServers', 'DnsServer']) {
      if (json.containsKey(key) && json[key] != null && json[key] != false) {
        warnings.add('Поле $key не распознано и пропущено.');
      }
    }
    return (
      settings: settings.hasSettings ? settings : null,
      fakeDnsEnabled: fakeDnsEnabled,
    );
  }

  static RoutingTemplateImportResult _parseXray(Map<dynamic, dynamic> json) {
    final routing = json['routing'] is Map ? json['routing'] as Map : json;
    final rawRules = routing['rules'];
    if (rawRules is! List) {
      throw const FormatException(
        'В JSON не найден список правил маршрутизации или Xray.',
      );
    }

    final rules = <VpnRoutingRule>[];
    final warnings = <String>[];
    final rawDns = json['dns'];
    final dnsConfig = rawDns is Map ? Map<String, dynamic>.from(rawDns) : null;
    if (rawDns != null && dnsConfig == null) {
      warnings.add('Настройки dns пропущены: ожидался объект Xray.');
    }
    final dnsServerTags = <String>{};
    final rawDnsServers = dnsConfig?['servers'];
    if (rawDnsServers is List) {
      for (final server in rawDnsServers.whereType<Map>()) {
        final tag = server['tag'];
        if (tag is String && tag.trim().isNotEmpty) {
          dnsServerTags.add(tag.trim());
        }
      }
    }
    final dnsRoutes = <RoutingDnsRoute>[];
    var fallbackAction = RoutingAction.proxy;
    for (final rawRule in rawRules) {
      if (rawRule is! Map) continue;
      final action = _xrayAction(rawRule['outboundTag']);
      final inboundTags = _readConditions(rawRule['inboundTag']);
      final matchingDnsTags =
          inboundTags.where((tag) => dnsServerTags.contains(tag)).toSet();
      if (matchingDnsTags.isNotEmpty &&
          matchingDnsTags.length == inboundTags.toSet().length) {
        if (action == null) {
          warnings.add('Маршрут DNS-сервера с неизвестным действием пропущен.');
        } else {
          const supportedDnsRouteFields = {
            'type',
            'inboundTag',
            'outboundTag',
          };
          if (rawRule.keys.any((key) =>
              key is! String || !supportedDnsRouteFields.contains(key))) {
            warnings.add(
                'Из маршрута DNS-сервера не поддержаны дополнительные условия.');
          }
          for (final tag in matchingDnsTags) {
            dnsRoutes.add(RoutingDnsRoute(inboundTag: tag, action: action));
          }
        }
        continue;
      }
      if (action == null) {
        warnings.add('Одно правило с неизвестным маршрутом пропущено.');
        continue;
      }

      final domains = _readConditions(rawRule['domain']);
      final ips = _readConditions(rawRule['ip']);
      final ports = _readConditions(rawRule['port']);
      final networks = _readConditions(rawRule['network'])
          .expand((network) => network.split(','))
          .map((network) => network.trim())
          .where((network) => network.isNotEmpty)
          .toList(growable: false);
      final protocols = _readConditions(rawRule['protocol']);
      if (domains.isEmpty &&
          ips.isEmpty &&
          ports.isEmpty &&
          networks.isEmpty &&
          protocols.isEmpty) {
        const metadata = {
          'type',
          'outboundTag',
          'inboundTag',
          '__name__',
          'ruleTag',
        };
        if (rawRule.keys
            .every((key) => key is String && metadata.contains(key))) {
          fallbackAction = action;
        } else {
          warnings.add('Одно правило без поддерживаемых условий пропущено.');
        }
        continue;
      }
      if (domains.isEmpty &&
          ips.isEmpty &&
          ports.isEmpty &&
          protocols.isEmpty &&
          networks.toSet().containsAll({'tcp', 'udp'}) &&
          rawRule.keys.every((key) =>
              key is String &&
              {
                'type',
                'outboundTag',
                'network',
                'inboundTag',
                '__name__',
                'ruleTag',
              }.contains(key))) {
        fallbackAction = action;
        continue;
      }
      const unsupported = [
        'sourcePort',
        'localPort',
        'sourceIP',
        'localIP',
        'user',
        'attrs',
        'process',
        'inboundTag',
      ];
      if (unsupported.any(rawRule.containsKey)) {
        warnings
            .add('Из некоторых правил не поддержаны дополнительные условия.');
      }

      final type = domains.isNotEmpty
          ? RoutingTargetType.domain
          : ips.isNotEmpty
              ? RoutingTargetType.ip
              : RoutingTargetType.port;
      final display = [
        ...domains,
        ...ips,
        ...ports,
        ...networks,
        ...protocols,
      ].join(' · ');
      rules.add(VpnRoutingRule(
        type: type,
        value: display,
        action: action,
        label: _optionalString(rawRule['__name__'] ?? rawRule['ruleTag']),
        domains: domains,
        ips: ips,
        ports: ports,
        networks: networks,
        protocols: protocols,
      ));
    }

    final globalProxy = json['GlobalProxy'];
    final fallback =
        globalProxy == null ? fallbackAction : _globalProxyAction(globalProxy);
    final rawStrategy = routing['domainStrategy'] ?? json['domainStrategy'];
    final strategy = rawStrategy is String ? rawStrategy : null;
    final geodata = json['geodata'] is Map ? json['geodata'] as Map : null;
    final assets = geodata?['assets'];
    String? readAssetUrl(String fileName) {
      if (assets is! List) return null;
      for (final asset in assets) {
        if (asset is Map && asset['file'] == fileName) {
          return _readGeoDataUrl(
              asset['url'], 'geodata.assets.$fileName', warnings);
        }
      }
      return null;
    }

    final geoipUrl = _readGeoDataUrl(
      json['Geoipurl'] ?? json['geoipUrl'] ?? readAssetUrl('geoip.dat'),
      'Geoipurl',
      warnings,
    );
    final geositeUrl = _readGeoDataUrl(
      json['Geositeurl'] ?? json['geositeUrl'] ?? readAssetUrl('geosite.dat'),
      'Geositeurl',
      warnings,
    );
    final rawFakeDns = json['fakedns'];
    final fakeDnsConfig =
        rawFakeDns is Map || rawFakeDns is List ? rawFakeDns : null;
    if (rawFakeDns != null && fakeDnsConfig == null) {
      warnings.add('Настройки fakedns пропущены: ожидался объект или список.');
    }
    if (routing.containsKey('domainMatcher') ||
        json.containsKey('domainMatcher')) {
      warnings.add('Параметр domainMatcher не поддерживается встроенным Xray.');
    }
    return RoutingTemplateImportResult(
      template: RoutingTemplate(
        id: '',
        name: _readName(
          json['__name__'] ?? json['name'] ?? json['Name'] ?? json['remarks'],
          'Импортированный шаблон',
        ),
        defaultAction: fallback,
        domainStrategy: strategy,
        geoipUrl: geoipUrl,
        geositeUrl: geositeUrl,
        xrayDnsConfig: dnsConfig,
        xrayFakeDnsConfig: fakeDnsConfig,
        dnsRoutes: dnsRoutes,
        rules: rules,
      ),
      warnings: warnings,
    );
  }

  static RoutingAction? _xrayAction(Object? tag) {
    if (tag is! String) return null;
    return switch (tag.toLowerCase()) {
      'direct' || 'freedom' => RoutingAction.direct,
      'proxy' || 'vpn' => RoutingAction.proxy,
      'block' || 'blackhole' || 'reject' => RoutingAction.block,
      _ => null,
    };
  }

  static String _outboundName(RoutingAction action) => switch (action) {
        RoutingAction.direct => 'direct',
        RoutingAction.proxy => 'proxy',
        RoutingAction.block => 'block',
      };

  static RoutingAction _globalProxyAction(Object? value) {
    if (value == false ||
        (value is String && value.trim().toLowerCase() == 'false')) {
      return RoutingAction.direct;
    }
    return RoutingAction.proxy;
  }

  static List<String> _readConditions(Object? value) {
    if (value is String) return [value];
    if (value is num) return [value.toString()];
    if (value is! List) return const [];
    return value
        .where((item) => item is String || item is num)
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  static String _readName(Object? raw, String fallback) {
    if (raw is! String || raw.trim().isEmpty) return fallback;
    return raw.trim();
  }

  static String? _optionalString(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return null;
    return raw.trim();
  }
}
