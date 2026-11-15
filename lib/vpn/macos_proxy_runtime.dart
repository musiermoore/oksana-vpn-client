import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import '../models/local_socks_auth_settings.dart';
import '../models/subscription_profile.dart';
import '../models/vpn_routing_settings.dart';
import '../services/routing_geo_data_loader.dart';
import '../services/xray_routing_configuration.dart';
import '../services/xray_socks_authentication.dart';
import 'vpn_runtime.dart';

const _xrayExecutableOverride = String.fromEnvironment('XRAY_EXECUTABLE');

class MacosProxyRuntime implements VpnRuntime, VpnConnectivityProbe {
  final StreamController<VpnRuntimeSnapshot> _stateChanges =
      StreamController<VpnRuntimeSnapshot>.broadcast();
  Process? _process;
  Directory? _workingDirectory;
  VpnRuntimePhase _phase = VpnRuntimePhase.disconnected;
  String? _errorMessage;
  List<int> _localProxyPorts = const [];
  int? _probeHttpPort;
  bool _disposed = false;

  @override
  VpnRuntimeSnapshot get snapshot => VpnRuntimeSnapshot(
        phase: _phase,
        errorMessage: _errorMessage,
        localProxyPorts: _localProxyPorts,
      );

  @override
  Stream<VpnRuntimeSnapshot> get changes => _stateChanges.stream;

  @override
  bool supports(VpnMode mode) =>
      Platform.isMacOS &&
      Abi.current() == Abi.macosArm64 &&
      mode == VpnMode.proxy;

  @override
  Future<void> connect(
    SubscriptionProfile profile,
    VpnMode mode, {
    VpnRoutingSettings routingSettings = const VpnRoutingSettings(),
    GlobalDnsSettings globalDnsSettings = const GlobalDnsSettings(),
    LocalSocksAuthSettings localSocksAuthSettings =
        const LocalSocksAuthSettings(),
  }) async {
    if (!Platform.isMacOS) {
      throw const VpnRuntimeException(
          'Прокси-режим недоступен на этом устройстве.');
    }
    if (Abi.current() != Abi.macosArm64) {
      throw const VpnRuntimeException(
          'Текущая версия приложения не поддерживает это устройство.');
    }
    if (_process != null) {
      throw const VpnRuntimeException('Xray уже запущен.');
    }

    _phase = VpnRuntimePhase.starting;
    _errorMessage = null;
    _localProxyPorts = const [];
    _publish();

    try {
      final executable = _resolveExecutable();
      if (!await executable.exists()) {
        throw const VpnRuntimeException(
          'Компонент Xray не найден. Переустановите приложение или обратитесь в поддержку.',
        );
      }
      _ensureNotDisposed();

      final configuration = _prepareConfiguration(
        profile,
        routingSettings,
        localSocksAuthSettings,
      );
      final ports = _findProxyPorts(configuration);
      if (ports.isEmpty) {
        throw const VpnRuntimeException(
          'В профиле нет локального SOCKS или HTTP proxy.',
        );
      }

      final directory = await Directory.systemTemp.createTemp('oksana-vpn-');
      _workingDirectory = directory;
      _ensureNotDisposed();
      final assetDirectory = await _prepareAssetDirectory(
        directory,
        routingSettings,
      );
      final configFile = File('${directory.path}/profile.json');
      await configFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(configuration),
        flush: true,
      );
      _ensureNotDisposed();

      final process = await Process.start(
        executable.path,
        ['run', '-c', configFile.path],
        workingDirectory: directory.path,
        environment: {'XRAY_LOCATION_ASSET': assetDirectory},
        runInShell: false,
      );
      _process = process;
      _ensureNotDisposed();

      // Xray output may contain private configuration details. Drain it without logging.
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      unawaited(_watchProcess(process));

      await _waitForProxy(ports.first);
      _localProxyPorts = ports;
      _phase = VpnRuntimePhase.running;
      _publish();
    } catch (error) {
      final process = _process;
      _process = null;
      if (process != null) {
        process.kill(ProcessSignal.sigterm);
        try {
          await process.exitCode.timeout(const Duration(seconds: 3));
        } on TimeoutException {
          process.kill(ProcessSignal.sigkill);
          await process.exitCode;
        }
      }
      await _cleanup();
      _phase = VpnRuntimePhase.error;
      _errorMessage = switch (error) {
        VpnRuntimeException runtimeError => runtimeError.message,
        ProcessException() => 'Не удалось запустить компонент VPN.',
        FileSystemException() => 'Не удалось подготовить файлы VPN.',
        _ => 'Не удалось запустить локальный proxy.',
      };
      _publish();
      if (error is VpnRuntimeException) rethrow;
      throw VpnRuntimeException(_errorMessage!);
    }
  }

  @override
  Future<int> probeConnectivity(
    SubscriptionProfile profile,
    Uri testUri,
  ) async {
    if (!supports(VpnMode.proxy)) return -1;

    final reservation =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = reservation.port;
    await reservation.close();
    _probeHttpPort = port;

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..idleTimeout = const Duration(seconds: 2)
      ..findProxy = (_) => 'PROXY 127.0.0.1:$port';

    try {
      await connect(profile, VpnMode.proxy);
      final stopwatch = Stopwatch()..start();
      final request =
          await client.getUrl(testUri).timeout(const Duration(seconds: 10));
      request.headers
          .set(HttpHeaders.userAgentHeader, 'OksanaVPN-Connectivity');
      final response =
          await request.close().timeout(const Duration(seconds: 10));
      await response.drain<void>().timeout(const Duration(seconds: 5));
      stopwatch.stop();
      return response.statusCode >= HttpStatus.ok &&
              response.statusCode < HttpStatus.badRequest
          ? stopwatch.elapsedMilliseconds
          : -1;
    } catch (_) {
      return -1;
    } finally {
      client.close(force: true);
      _probeHttpPort = null;
      await disconnect();
    }
  }

  @override
  Future<void> disconnect() async {
    final process = _process;
    if (process == null) {
      _phase = VpnRuntimePhase.disconnected;
      _localProxyPorts = const [];
      _publish();
      await _cleanup();
      return;
    }

    _phase = VpnRuntimePhase.stopping;
    _publish();
    process.kill(ProcessSignal.sigterm);

    try {
      await process.exitCode.timeout(const Duration(seconds: 4));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }

    if (identical(_process, process)) _process = null;
    await _cleanup();
    _phase = VpnRuntimePhase.disconnected;
    _localProxyPorts = const [];
    _errorMessage = null;
    _publish();
  }

  File _resolveExecutable() {
    if (_xrayExecutableOverride.isNotEmpty) {
      return File(_xrayExecutableOverride);
    }

    final executable = File(Platform.resolvedExecutable);
    final contentsDirectory = executable.parent.parent;
    final appResource = File('${contentsDirectory.path}/Resources/xray');
    if (appResource.existsSync()) {
      return appResource;
    }
    return File('/opt/homebrew/bin/xray');
  }

  String get _resourceDirectory {
    final executable = File(Platform.resolvedExecutable);
    return '${executable.parent.parent.path}/Resources';
  }

  Map<String, dynamic> _prepareConfiguration(
    SubscriptionProfile profile,
    VpnRoutingSettings routingSettings,
    LocalSocksAuthSettings localSocksAuthSettings,
  ) {
    final configuration =
        jsonDecode(jsonEncode(profile.toRuntimeConfiguration()))
            as Map<String, dynamic>;
    if (configuration['outbounds'] is! List ||
        (configuration['outbounds'] as List).isEmpty) {
      throw const VpnRuntimeException('В профиле отсутствуют Xray outbounds.');
    }

    final inbounds = configuration['inbounds'] is List
        ? List<dynamic>.from(configuration['inbounds'] as List)
        : <dynamic>[];
    final probePort = _probeHttpPort;
    if (probePort != null) {
      final sourceInbound = inbounds.whereType<Map>().firstWhere(
            (item) => item['protocol'] == 'socks' || item['protocol'] == 'http',
            orElse: () => const {},
          );
      final sourceTag = sourceInbound['tag'];
      configuration['inbounds'] = [
        {
          'tag': sourceTag is String && sourceTag.isNotEmpty
              ? sourceTag
              : 'local-socks',
          'listen': '127.0.0.1',
          'port': probePort,
          'protocol': 'http',
          'settings': <String, dynamic>{},
        }
      ];
      return configuration;
    }

    if (localSocksAuthSettings.enabled &&
        localSocksAuthSettings.validationError != null) {
      throw VpnRuntimeException(localSocksAuthSettings.validationError!);
    }

    final hasLocalProxy = inbounds.any(_isLocalProxyInbound);
    final hasLocalSocks = inbounds.any(_isLocalSocksInbound);
    if (!hasLocalProxy || (localSocksAuthSettings.enabled && !hasLocalSocks)) {
      final usedTags = inbounds
          .whereType<Map>()
          .map((inbound) => inbound['tag'])
          .whereType<String>()
          .toSet();
      final usedPorts = inbounds
          .whereType<Map>()
          .map((inbound) => inbound['port'])
          .whereType<int>()
          .toSet();
      var port = 10808;
      while (usedPorts.contains(port)) {
        port++;
      }
      inbounds.add({
        'tag': _uniqueTag('local-socks', usedTags),
        'listen': '127.0.0.1',
        'port': port,
        'protocol': 'socks',
        'settings': {'udp': true},
      });
    }

    if (localSocksAuthSettings.enabled) {
      for (var index = 0; index < inbounds.length; index++) {
        final item = inbounds[index];
        if (item is! Map || !_isLocalSocksInbound(item)) continue;
        final inbound = Map<String, dynamic>.from(item);
        XraySocksAuthentication.apply(inbound, localSocksAuthSettings);
        inbounds[index] = inbound;
      }
    }

    if (routingSettings.enabled) {
      final usedTags = inbounds
          .whereType<Map>()
          .map((inbound) => inbound['tag'])
          .whereType<String>()
          .toSet();
      final inboundTags = <String>[];
      for (var index = 0; index < inbounds.length; index++) {
        final item = inbounds[index];
        if (item is! Map || !_isLocalProxyInbound(item)) continue;
        final inbound = Map<String, dynamic>.from(item);
        var tag = inbound['tag'];
        if (tag is! String || tag.isEmpty) {
          tag = _uniqueTag('oksana-local-proxy', usedTags);
          inbound['tag'] = tag;
          inbounds[index] = inbound;
        }
        inboundTags.add(tag);

        if (routingSettings.activeTemplate.usesFakeDns ||
            routingSettings.activeTemplate.rules
                .any((rule) => rule.hasDomainTarget)) {
          final sniffing = inbound['sniffing'] is Map
              ? Map<String, dynamic>.from(inbound['sniffing'] as Map)
              : <String, dynamic>{};
          final overrides = sniffing['destOverride'] is List
              ? (sniffing['destOverride'] as List).whereType<String>().toList()
              : <String>[];
          for (final protocol in ['http', 'tls', 'quic']) {
            if (!overrides.contains(protocol)) overrides.add(protocol);
          }
          if (routingSettings.activeTemplate.usesFakeDns &&
              !overrides.contains('fakedns')) {
            overrides.add('fakedns');
          }
          sniffing
            ..['enabled'] = true
            ..['routeOnly'] = true
            ..['destOverride'] = overrides;
          inbound['sniffing'] = sniffing;
          inbounds[index] = inbound;
        }
      }

      XrayRoutingConfiguration.apply(
        configuration,
        routingSettings,
        inboundTags: inboundTags,
      );
    }

    configuration['inbounds'] = inbounds;
    return configuration;
  }

  bool _isLocalProxyInbound(Object? value) {
    if (value is! Map ||
        (value['protocol'] != 'socks' && value['protocol'] != 'http')) {
      return false;
    }
    return value['listen'] == '127.0.0.1';
  }

  bool _isLocalSocksInbound(Object? value) =>
      value is Map &&
      value['protocol'] == 'socks' &&
      value['listen'] == '127.0.0.1';

  String _uniqueTag(String base, Set<String> usedTags) {
    var tag = base;
    var suffix = 2;
    while (usedTags.contains(tag)) {
      tag = '$base-${suffix++}';
    }
    usedTags.add(tag);
    return tag;
  }

  Future<String> _prepareAssetDirectory(
    Directory workingDirectory,
    VpnRoutingSettings routingSettings,
  ) async {
    if (!routingSettings.enabled) return _resourceDirectory;

    final assetDirectory = Directory('${workingDirectory.path}/assets');
    await assetDirectory.create();
    for (final fileName in ['geoip.dat', 'geosite.dat']) {
      final bundledFile = File('$_resourceDirectory/$fileName');
      if (!await bundledFile.exists()) {
        throw const VpnRuntimeException(
          'Не найдены встроенные базы геоданных. Переустановите приложение.',
        );
      }
      await bundledFile.copy('${assetDirectory.path}/$fileName');
    }

    final downloaded =
        await RoutingGeoDataLoader.download(routingSettings.activeTemplate);
    for (final entry in downloaded.entries) {
      final fileName = switch (entry.key) {
        'geoipData' => 'geoip.dat',
        'geositeData' => 'geosite.dat',
        _ => null,
      };
      if (fileName != null) {
        await File('${assetDirectory.path}/$fileName')
            .writeAsBytes(entry.value, flush: true);
      }
    }
    return assetDirectory.path;
  }

  List<int> _findProxyPorts(Map<String, dynamic> configuration) {
    final inbounds = configuration['inbounds'];
    if (inbounds is! List) return const [];

    return inbounds
        .whereType<Map>()
        .where((inbound) {
          return (inbound['protocol'] == 'socks' ||
                  inbound['protocol'] == 'http') &&
              inbound['listen'] == '127.0.0.1';
        })
        .map((inbound) => inbound['port'])
        .whereType<int>()
        .toList(growable: false);
  }

  Future<void> _waitForProxy(int port) async {
    for (var attempt = 0; attempt < 30; attempt++) {
      final process = _process;
      if (process == null) break;

      try {
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          port,
          timeout: const Duration(milliseconds: 300),
        );
        socket.destroy();
        return;
      } on SocketException {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }

    throw const VpnRuntimeException(
      'Xray не открыл локальный proxy-порт. Проверьте профиль и Xray binary.',
    );
  }

  Future<void> _watchProcess(Process process) async {
    final exitCode = await process.exitCode;
    if (!identical(_process, process)) return;

    _process = null;
    await _cleanup();
    if (_phase == VpnRuntimePhase.stopping ||
        _phase == VpnRuntimePhase.disconnected) {
      return;
    }

    _phase = VpnRuntimePhase.error;
    _errorMessage = exitCode == 0
        ? 'Локальный proxy остановлен.'
        : 'Xray завершился с ошибкой.';
    _localProxyPorts = const [];
    _publish();
  }

  Future<void> _cleanup() async {
    final directory = _workingDirectory;
    _workingDirectory = null;
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  void _publish() {
    if (!_disposed && !_stateChanges.isClosed) _stateChanges.add(snapshot);
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw const VpnRuntimeException('Приложение закрывается.');
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_shutdownAndClose());
  }

  Future<void> _shutdownAndClose() async {
    try {
      await disconnect();
    } finally {
      await _stateChanges.close();
    }
  }
}
