import 'package:flutter_test/flutter_test.dart';
import 'package:oksana_vpn_desktop/models/local_socks_auth_settings.dart';
import 'package:oksana_vpn_desktop/services/xray_socks_authentication.dart';

void main() {
  test('creates valid secure defaults for new installs', () {
    final settings = LocalSocksAuthSettings.createSecureDefault();

    expect(settings.enabled, isTrue);
    expect(settings.username, 'oksana');
    expect(settings.password, hasLength(24));
    expect(settings.validationError, isNull);
  });

  test('stores enabled SOCKS5 credentials and restores them', () {
    const settings = LocalSocksAuthSettings(
      enabled: true,
      username: 'oksana-client',
      password: 'strong-local-password',
    );

    final restored = LocalSocksAuthSettings.decode(settings.encode());

    expect(restored.enabled, isTrue);
    expect(restored.username, settings.username);
    expect(restored.password, settings.password);
  });

  test('requires nonempty credentials within the SOCKS5 size limit', () {
    expect(const LocalSocksAuthSettings().validationError, isNotNull);
    expect(
      const LocalSocksAuthSettings(username: 'user').validationError,
      'Введите пароль.',
    );
    expect(
      LocalSocksAuthSettings(
        username: 'u' * 256,
        password: 'password',
      ).validationError,
      'Логин и пароль должны быть не длиннее 255 байт.',
    );
    expect(
      const LocalSocksAuthSettings(
        username: 'user',
        password: 'password',
      ).validationError,
      isNull,
    );
  });

  test('adds password authentication to only the loopback SOCKS inbound', () {
    final socksInbound = <String, dynamic>{
      'tag': 'local-socks',
      'listen': '127.0.0.1',
      'protocol': 'socks',
      'settings': {
        'udp': true,
        'auth': 'noauth',
        'users': [
          {'user': 'old-user', 'pass': 'old-password'},
        ],
      },
    };
    final httpInbound = <String, dynamic>{
      'listen': '127.0.0.1',
      'protocol': 'http',
      'settings': <String, dynamic>{},
    };
    const auth = LocalSocksAuthSettings(
      enabled: true,
      username: 'app-user',
      password: 'app-password',
    );

    XraySocksAuthentication.apply(socksInbound, auth);
    XraySocksAuthentication.apply(httpInbound, auth);

    final settings = socksInbound['settings'] as Map;
    expect(settings['udp'], isTrue);
    expect(settings['auth'], 'password');
    expect(settings['accounts'], [
      {'user': 'app-user', 'pass': 'app-password'},
    ]);
    expect(settings.containsKey('users'), isFalse);
    expect(httpInbound['settings'], isEmpty);
  });
}
