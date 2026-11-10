import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import '../models/subscription_profile.dart';
import 'vpn_runtime.dart';

class MacosDaemonTunnelRuntime implements VpnRuntime {
  static const _socketPath =
      '/var/run/com.oksana1984.oksanaVpnDesktop.sock';
  static const _maximumResponseWait = Duration(seconds: 30);

  final StreamController<VpnRuntimeSnapshot> _changes =
      StreamController<VpnRuntimeSnapshot>.broadcast();

  VpnRuntimePhase _phase = VpnRuntimePhase.disconnected;
  String? _errorMessage;
  Timer? _statusTimer;
  bool _statusCheckInProgress = false;
  bool _disposed = false;

  MacosDaemonTunnelRuntime() {
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
      mode == VpnMode.tun &&
      Platform.isMacOS &&
      Abi.current() == Abi.macosArm64;

  @override
  Future<void> connect(SubscriptionProfile profile, VpnMode mode) async {
    if (!supports(mode)) {
      throw const VpnRuntimeException(
          'TUN поддерживается только в macOS ARM64.');
    }
    if (_phase == VpnRuntimePhase.running ||
        _phase == VpnRuntimePhase.starting) {
      throw const VpnRuntimeException('VPN-туннель уже запущен.');
    }

    _setPhase(VpnRuntimePhase.starting);
    _errorMessage = null;
    _publish();
    try {
      final configuration = jsonEncode(_prepareConfiguration(profile));
      await _ensureServiceInstalled();
      final response = await _request({
        'command': 'start',
        'configuration': configuration,
      });
      _applyStatus(response['state'] as String? ?? 'running');
      _startStatusPolling();
    } on VpnRuntimeException catch (error) {
      _setPhase(VpnRuntimePhase.error);
      _errorMessage = error.message;
      _publish();
      rethrow;
    } on SocketException {
      _setPhase(VpnRuntimePhase.error);
      _errorMessage = 'Не удалось связаться с VPN-службой macOS.';
      _publish();
      throw VpnRuntimeException(_errorMessage!);
    } on ProcessException {
      _setPhase(VpnRuntimePhase.error);
      _errorMessage = 'Не удалось установить компонент VPN.';
      _publish();
      throw VpnRuntimeException(_errorMessage!);
    } on Object {
      _setPhase(VpnRuntimePhase.error);
      _errorMessage = 'Не удалось запустить TUN-туннель.';
      _publish();
      throw VpnRuntimeException(_errorMessage!);
    }
  }

  @override
  Future<void> disconnect() async {
    if (_phase == VpnRuntimePhase.disconnected) return;
    _setPhase(VpnRuntimePhase.stopping);
    _publish();
    try {
      final response = await _request({'command': 'stop'});
      _applyStatus(response['state'] as String? ?? 'disconnected');
      _statusTimer?.cancel();
      _statusTimer = null;
    } on VpnRuntimeException catch (error) {
      _setPhase(VpnRuntimePhase.error);
      _errorMessage = error.message;
      _publish();
      rethrow;
    } on SocketException {
      _setPhase(VpnRuntimePhase.error);
      _errorMessage = 'Не удалось связаться с VPN-службой macOS.';
      _publish();
      throw VpnRuntimeException(_errorMessage!);
    }
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
        ? (configuration['inbounds'] as List).whereType<Map>().toList()
        : <Map>[];
    final existingTags =
        inbounds.map((inbound) => inbound['tag']).whereType<String>().toSet();

    Map<String, dynamic>? existingSniffing;
    for (final inbound in inbounds) {
      final sniffing = inbound['sniffing'];
      if (sniffing is Map) {
        existingSniffing = Map<String, dynamic>.from(sniffing);
        break;
      }
    }

    configuration['inbounds'] = [
      {
        'tag': 'oksana-tun',
        'protocol': 'tun',
        'port': 0,
        'settings': {
          'mtu': 1500,
          'autoSystemRoutingTable': ['0.0.0.0/0', '::/0'],
          'autoOutboundsInterface': 'auto',
        },
        'sniffing': existingSniffing ??
            {
              'enabled': true,
              'destOverride': ['http', 'tls', 'quic'],
            },
      },
    ];

    final routing = configuration['routing'];
    if (routing is Map && routing['rules'] is List) {
      for (final value in routing['rules'] as List) {
        if (value is! Map) continue;
        final inboundTags = value['inboundTag'];
        if (inboundTags is String && existingTags.contains(inboundTags)) {
          value['inboundTag'] = 'oksana-tun';
        } else if (inboundTags is List) {
          final tags = inboundTags.whereType<String>().toList();
          if (tags.any(existingTags.contains)) {
            value['inboundTag'] = [
              ...tags.where((tag) => !existingTags.contains(tag)),
              'oksana-tun',
            ];
          }
        }
      }
    }
    return configuration;
  }

  Future<void> _ensureServiceInstalled() async {
    try {
      await _request({'command': 'status'});
      return;
    } on SocketException {
      // The first TUN connection installs the helper through one macOS
      // administrator authorization prompt.
    }

    final resourceDirectory = _resourceDirectory;
    final installerPath = '$resourceDirectory/install_vpn_daemon.sh';
    if (!await File(installerPath).exists()) {
      throw const VpnRuntimeException(
          'В приложении отсутствует установщик VPN-службы.');
    }

    final uidResult = await Process.run('/usr/bin/id', ['-u']);
    if (uidResult.exitCode != 0) {
      throw const ProcessException('/usr/bin/id', [], 'Could not determine the current user.');
    }
    final uid = (uidResult.stdout as String).trim();
    if (!RegExp(r'^[1-9][0-9]*$').hasMatch(uid)) {
      throw const VpnRuntimeException('Не удалось определить учётную запись macOS.');
    }

    const appleScript = '''
on run argv
  set installer to quoted form of (item 1 of argv)
  set ownerUID to item 2 of argv
  do shell script installer & " " & ownerUID with prompt "Установить системный компонент Oksana VPN?" with administrator privileges
end run
''';
    final result = await Process.run(
      '/usr/bin/osascript',
      ['-e', appleScript, installerPath, uid],
    );
    if (result.exitCode != 0) {
      throw const VpnRuntimeException(
          'Установка VPN-службы отменена или завершилась ошибкой.');
    }

    // Give launchd a moment to start the newly registered root helper.
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        await _request({'command': 'status'});
        return;
      } on SocketException {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    throw const VpnRuntimeException(
        'VPN-служба установлена, но не ответила. Перезапусти приложение и попробуй ещё раз.');
  }

  Future<Map<String, dynamic>> _request(Map<String, Object?> request) async {
    Socket socket;
    try {
      socket = await Socket.connect(
        InternetAddress(_socketPath, type: InternetAddressType.unix),
        0,
        timeout: const Duration(seconds: 3),
      );
    } on SocketException {
      rethrow;
    }

    try {
      socket.write('${jsonEncode(request)}\n');
      await socket.flush();
      final line = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(_maximumResponseWait);
      final response = jsonDecode(line) as Map<String, dynamic>;
      if (response['ok'] != true) {
        throw VpnRuntimeException(
            response['error'] as String? ?? 'VPN-служба отклонила команду.');
      }
      return response;
    } on TimeoutException {
      throw const VpnRuntimeException('VPN-служба не ответила вовремя.');
    } on FormatException {
      throw const VpnRuntimeException('VPN-служба вернула неверный ответ.');
    } finally {
      socket.destroy();
    }
  }

  String get _resourceDirectory {
    final executable = File(Platform.resolvedExecutable);
    return '${executable.parent.parent.path}/Resources';
  }

  void _startStatusPolling() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_statusCheckInProgress || _disposed) return;
      _statusCheckInProgress = true;
      try {
        final response = await _request({'command': 'status'});
        _applyStatus(response['state'] as String? ?? 'disconnected');
      } on Object {
        if (_phase == VpnRuntimePhase.running) {
          _setPhase(VpnRuntimePhase.error);
          _errorMessage = 'Потеряна связь с VPN-службой macOS.';
          _publish();
        }
      } finally {
        _statusCheckInProgress = false;
      }
    });
  }

  Future<void> _loadInitialStatus() async {
    try {
      final response = await _request({'command': 'status'});
      if (_disposed) return;
      _applyStatus(response['state'] as String? ?? 'disconnected');
      if (_phase == VpnRuntimePhase.running) _startStatusPolling();
    } on Object {
      // The helper is installed only on the first TUN connection.
    }
  }

  void _applyStatus(String state) {
    switch (state) {
      case 'running':
        _setPhase(VpnRuntimePhase.running);
        break;
      case 'starting':
        _setPhase(VpnRuntimePhase.starting);
        break;
      case 'stopping':
        _setPhase(VpnRuntimePhase.stopping);
        break;
      default:
        _setPhase(VpnRuntimePhase.disconnected);
        _statusTimer?.cancel();
        _statusTimer = null;
        break;
    }
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
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _statusTimer?.cancel();
    unawaited(_changes.close());
  }
}
