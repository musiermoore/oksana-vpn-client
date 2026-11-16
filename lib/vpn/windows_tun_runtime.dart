import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';

import '../models/local_socks_auth_settings.dart';
import '../models/subscription_profile.dart';
import '../models/vpn_routing_settings.dart';
import '../services/routing_geo_data_loader.dart';
import '../services/xray_dns_configuration.dart';
import '../services/xray_global_dns_configuration.dart';
import '../services/xray_routing_configuration.dart';
import 'vpn_runtime.dart';

/// Windows TUN is provided by Xray's native Wintun inbound. A small elevated
/// companion owns Xray so that routes and DNS are reverted when it exits.
class WindowsTunRuntime implements VpnRuntime {
  static const _channel = MethodChannel('oksanavpn/vpn_runtime');

  final StreamController<VpnRuntimeSnapshot> _changes =
      StreamController<VpnRuntimeSnapshot>.broadcast();
  Timer? _statusTimer;
  VpnRuntimePhase _phase = VpnRuntimePhase.disconnected;
  String? _errorMessage;
  bool _disposed = false;
  bool _requestInProgress = false;
  Future<void> _requestTail = Future<void>.value();

  WindowsTunRuntime() {
    unawaited(_loadInitialStatus());
  }

  @override
  VpnRuntimeSnapshot get snapshot => VpnRuntimeSnapshot(
        phase: _phase,
        errorMessage: _errorMessage,
      );

  @override
  Stream<VpnRuntimeSnapshot> get changes => _changes.stream;

  @override
  bool supports(VpnMode mode) =>
      Platform.isWindows &&
      Abi.current() == Abi.windowsX64 &&
      mode == VpnMode.tun;

  @override
  Future<void> connect(
    SubscriptionProfile profile,
    VpnMode mode, {
    VpnRoutingSettings routingSettings = const VpnRoutingSettings(),
    GlobalDnsSettings globalDnsSettings = const GlobalDnsSettings(),
    LocalSocksAuthSettings localSocksAuthSettings =
        const LocalSocksAuthSettings(),
  }) async {
    if (!supports(mode)) {
      throw const VpnRuntimeException(
          'Режим TUN недоступен на этом устройстве.');
    }
    if (_phase == VpnRuntimePhase.running ||
        _phase == VpnRuntimePhase.starting) {
      throw const VpnRuntimeException('VPN-туннель уже запущен.');
    }

    _setPhase(VpnRuntimePhase.starting);
    _publish();
    try {
      final configuration = _prepareConfiguration(
        profile,
        routingSettings,
        globalDnsSettings,
      );
      final geoData = routingSettings.enabled
          ? await RoutingGeoDataLoader.download(routingSettings.activeTemplate)
          : const <String, List<int>>{};
      final response = await _request({
        'command': 'start',
        'configuration': jsonEncode(configuration),
        if (geoData['geoipData'] != null)
          'geoipData': Uint8List.fromList(geoData['geoipData']!),
        if (geoData['geositeData'] != null)
          'geositeData': Uint8List.fromList(geoData['geositeData']!),
      });
      _applyState(response['state'] as String? ?? 'running');
      _startStatusPolling();
    } on PlatformException catch (error) {
      _fail(_safePlatformError(error));
      throw VpnRuntimeException(_errorMessage!);
    } on VpnRuntimeException catch (error) {
      _fail(error.message);
      rethrow;
    } on Object {
      _fail(
          'Не удалось подготовить TUN-туннель. Проверьте профиль и соединение.');
      throw VpnRuntimeException(_errorMessage!);
    }
  }

  Map<String, dynamic> _prepareConfiguration(
    SubscriptionProfile profile,
    VpnRoutingSettings routingSettings,
    GlobalDnsSettings globalDnsSettings,
  ) {
    final configuration =
        jsonDecode(jsonEncode(profile.toRuntimeConfiguration()))
            as Map<String, dynamic>;
    if (configuration['outbounds'] is! List ||
        (configuration['outbounds'] as List).isEmpty) {
      throw const VpnRuntimeException('В профиле отсутствуют Xray outbounds.');
    }
    configuration['log'] = {'loglevel': 'none'};

    final oldInbounds = configuration['inbounds'] is List
        ? (configuration['inbounds'] as List).whereType<Map>().toList()
        : <Map>[];
    final oldTags = oldInbounds
        .map((inbound) => inbound['tag'])
        .whereType<String>()
        .where((tag) => tag.isNotEmpty)
        .toSet();
    Map<String, dynamic>? sniffingFromProfile;
    for (final inbound in oldInbounds) {
      if (inbound['sniffing'] is Map) {
        sniffingFromProfile =
            Map<String, dynamic>.from(inbound['sniffing'] as Map);
        break;
      }
    }
    final sniffing = sniffingFromProfile ??
        <String, dynamic>{
          'enabled': true,
          'destOverride': ['http', 'tls', 'quic'],
        };
    final template = routingSettings.activeTemplate;
    final needsSniffing = routingSettings.enabled &&
        (template.usesFakeDns ||
            template.rules.any((rule) => rule.hasDomainTarget));
    if (needsSniffing) {
      final overrides = sniffing['destOverride'] is List
          ? (sniffing['destOverride'] as List).whereType<String>().toList()
          : <String>[];
      for (final protocol in ['http', 'tls', 'quic']) {
        if (!overrides.contains(protocol)) overrides.add(protocol);
      }
      if (template.usesFakeDns && !overrides.contains('fakedns')) {
        overrides.add('fakedns');
      }
      sniffing
        ..['enabled'] = true
        ..['routeOnly'] = true
        ..['destOverride'] = overrides;
    }

    final routingTemplateControlsDns =
        routingSettings.enabled && XrayDnsConfiguration.controlsDns(template);
    if (routingTemplateControlsDns) {
      configuration['dns'] = XrayDnsConfiguration.buildDns(
        template,
        profileDns: configuration['dns'],
      );
    }
    final dns = _dnsAddresses(
      configuration,
      globalDnsSettings,
      includeGlobalSettings: !routingTemplateControlsDns,
    );
    if (dns.isEmpty) {
      throw const VpnRuntimeException(
        'Для TUN нужен DNS-сервер с IP-адресом. Выберите DNS в настройках или используйте профиль с настроенным DNS.',
      );
    }
    configuration['inbounds'] = [
      {
        'tag': 'oksana-tun',
        'protocol': 'tun',
        'port': 0,
        'settings': {
          'name': 'OksanaVPN',
          'desc': 'Wintun',
          'mtu': 1500,
          'gateway': ['172.19.0.1/30', 'fdfe:dcba:9876::1/126'],
          'dns': dns,
          'autoSystemRoutingTable': ['0.0.0.0/0', '::/0'],
          'autoOutboundsInterface': 'auto',
          'autoSystemWfpBlockLeak': ['dns', 'misconfigtun'],
        },
        'sniffing': sniffing,
      }
    ];

    final routing = configuration['routing'];
    if (routing is Map && routing['rules'] is List) {
      for (final rawRule in routing['rules'] as List) {
        if (rawRule is! Map) continue;
        final tags = rawRule['inboundTag'];
        if (tags is String && oldTags.contains(tags)) {
          rawRule['inboundTag'] = 'oksana-tun';
        } else if (tags is List &&
            tags.whereType<String>().any(oldTags.contains)) {
          rawRule['inboundTag'] = [
            ...tags.whereType<String>().where((tag) => !oldTags.contains(tag)),
            'oksana-tun',
          ];
        }
      }
    }
    if (routingSettings.enabled) {
      XrayRoutingConfiguration.apply(
        configuration,
        routingSettings,
        inboundTags: const ['oksana-tun'],
      );
    }
    XrayGlobalDnsConfiguration.apply(
      configuration,
      globalDnsSettings,
      routingSettings: routingSettings,
      inboundTags: const ['oksana-tun'],
    );
    return configuration;
  }

  List<String> _dnsAddresses(
    Map<String, dynamic> configuration,
    GlobalDnsSettings globalDnsSettings, {
    required bool includeGlobalSettings,
  }) {
    // Resolve DNS configuration using the same builders that feed Xray's DNS
    // engine so the system adapter and Xray agree on the active resolvers.
    final dns = configuration['dns'];
    final servers = dns is Map && dns['servers'] is List
        ? dns['servers'] as List
        : const <dynamic>[];
    final values = <String>[];
    for (final server in servers) {
      final address = server is String
          ? server
          : server is Map && server['address'] is String
              ? server['address'] as String
              : null;
      if (address == null) continue;
      final normalized = address.startsWith('udp://')
          ? address.substring('udp://'.length)
          : address;
      final parsed = InternetAddress.tryParse(normalized);
      if (parsed != null) {
        values.add(parsed.address);
      } else {
        final uri = Uri.tryParse(normalized);
        final hosts =
            dns is Map && dns['hosts'] is Map ? dns['hosts'] as Map : const {};
        final mapped = uri == null ? null : hosts[uri.host];
        if (mapped is String && InternetAddress.tryParse(mapped) != null) {
          values.add(mapped);
        }
      }
    }
    if (includeGlobalSettings) {
      for (final upstream in globalDnsSettings.upstreams) {
        final ip = InternetAddress.tryParse(upstream.server);
        if (ip != null) values.add(ip.address);
        final bootstrap = upstream.bootstrapIp;
        if (bootstrap != null && InternetAddress.tryParse(bootstrap) != null) {
          values.add(bootstrap);
        }
      }
    }
    return values.toSet().toList(growable: false);
  }

  Future<Map<String, dynamic>> _request(Map<String, Object?> request) async {
    final previousRequest = _requestTail;
    final gate = Completer<void>();
    _requestTail = gate.future;
    await previousRequest;
    _requestInProgress = true;
    try {
      final response = await _channel
          .invokeMapMethod<String, dynamic>('request', request)
          .timeout(const Duration(seconds: 45));
      if (response == null || response['ok'] != true) {
        throw VpnRuntimeException(
          response?['error'] as String? ?? 'Служба TUN отклонила команду.',
        );
      }
      return response;
    } on TimeoutException {
      throw const VpnRuntimeException('Служба TUN не ответила вовремя.');
    } finally {
      _requestInProgress = false;
      gate.complete();
    }
  }

  void _startStatusPolling() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_requestInProgress || _disposed) return;
      try {
        final response = await _request({'command': 'status'});
        _applyState(response['state'] as String? ?? 'disconnected');
      } on Object {
        if (_phase == VpnRuntimePhase.running) {
          _fail('Потеряна связь со службой TUN.');
        }
      }
    });
  }

  Future<void> _loadInitialStatus() async {
    try {
      final response = await _request({'command': 'status'});
      if (!_disposed) {
        _applyState(response['state'] as String? ?? 'disconnected');
        if (_phase == VpnRuntimePhase.running) _startStatusPolling();
      }
    } on Object {
      // TUN has not been started in this logon session.
    }
  }

  void _applyState(String state) {
    _phase = state == 'running'
        ? VpnRuntimePhase.running
        : state == 'starting'
            ? VpnRuntimePhase.starting
            : VpnRuntimePhase.disconnected;
    if (_phase == VpnRuntimePhase.disconnected) {
      _statusTimer?.cancel();
      _statusTimer = null;
    }
    _errorMessage = null;
    _publish();
  }

  String _safePlatformError(PlatformException error) => switch (error.code) {
        'cancelled' =>
          'Запуск TUN отменён в запросе контроля учётных записей Windows.',
        'missing_runtime' =>
          'Не найден Xray или wintun.dll. Переустановите приложение.',
        'start_failed' => 'Не удалось запустить системную службу TUN.',
        _ => 'Не удалось запустить TUN-туннель.',
      };

  void _fail(String message) {
    _phase = VpnRuntimePhase.error;
    _errorMessage = message;
    _publish();
  }

  void _setPhase(VpnRuntimePhase phase) {
    _phase = phase;
    if (phase == VpnRuntimePhase.running ||
        phase == VpnRuntimePhase.disconnected) {
      _errorMessage = null;
    }
  }

  void _publish() {
    if (!_disposed && !_changes.isClosed) _changes.add(snapshot);
  }

  @override
  Future<void> disconnect() async {
    if (_phase == VpnRuntimePhase.disconnected) return;
    _phase = VpnRuntimePhase.stopping;
    _publish();
    try {
      final response = await _request({'command': 'stop'});
      _applyState(response['state'] as String? ?? 'disconnected');
    } on Object {
      _fail(
          'Не удалось корректно остановить TUN. Запусти приложение снова и отключи VPN.');
      rethrow;
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _statusTimer?.cancel();
    unawaited(_changes.close());
  }
}
