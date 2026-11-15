import '../models/local_socks_auth_settings.dart';
import '../vpn/vpn_runtime.dart';

class XraySocksAuthentication {
  const XraySocksAuthentication._();

  static void apply(
    Map<String, dynamic> inbound,
    LocalSocksAuthSettings settings,
  ) {
    if (!settings.enabled ||
        inbound['protocol'] != 'socks' ||
        inbound['listen'] != '127.0.0.1') {
      return;
    }

    final validationError = settings.validationError;
    if (validationError != null) {
      throw VpnRuntimeException(validationError);
    }

    final xraySettings = inbound['settings'] is Map
        ? Map<String, dynamic>.from(inbound['settings'] as Map)
        : <String, dynamic>{};
    xraySettings.remove('users');
    xraySettings
      ..['auth'] = 'password'
      ..['accounts'] = [
        {
          'user': settings.username,
          'pass': settings.password,
        },
      ];
    inbound['settings'] = xraySettings;
  }
}
