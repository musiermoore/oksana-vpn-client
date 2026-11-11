import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import '../models/subscription_profile.dart';
import 'vpn_runtime.dart';

const _xrayExecutableOverride = String.fromEnvironment('XRAY_EXECUTABLE');

class MacosProxyRuntime implements VpnRuntime {
  final StreamController<VpnRuntimeSnapshot> _stateChanges =
      StreamController<VpnRuntimeSnapshot>.broadcast();
  Process? _process;
  Directory? _workingDirectory;
  VpnRuntimePhase _phase = VpnRuntimePhase.disconnected;
  String? _errorMessage;
  List<int> _localProxyPorts = const [];
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
  Future<void> connect(SubscriptionProfile profile, VpnMode mode) async {
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

      final configuration = _prepareConfiguration(profile);
      final ports = _findProxyPorts(configuration);
      if (ports.isEmpty) {
        throw const VpnRuntimeException(
          'В профиле нет локального SOCKS или HTTP proxy.',
        );
      }

      final directory = await Directory.systemTemp.createTemp('oksana-vpn-');
      _workingDirectory = directory;
      _ensureNotDisposed();
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
        environment: {'XRAY_LOCATION_ASSET': _resourceDirectory},
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

  Map<String, dynamic> _prepareConfiguration(SubscriptionProfile profile) {
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
    final hasLocalProxy = inbounds.any((item) {
      if (item is! Map) return false;
      return item['protocol'] == 'socks' || item['protocol'] == 'http';
    });

    if (!hasLocalProxy) {
      inbounds.add({
        'tag': 'local-socks',
        'listen': '127.0.0.1',
        'port': 10808,
        'protocol': 'socks',
        'settings': {'udp': true},
      });
    }

    configuration['inbounds'] = inbounds;
    return configuration;
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
