import 'dart:convert';
import 'dart:math';

class LocalSocksAuthSettings {
  const LocalSocksAuthSettings({
    this.enabled = false,
    this.username = '',
    this.password = '',
  });

  final bool enabled;
  final String username;
  final String password;

  static LocalSocksAuthSettings createSecureDefault() {
    const alphabet =
        'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = Random.secure();
    final password = List.generate(
      24,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
    return LocalSocksAuthSettings(
      enabled: true,
      username: 'oksana',
      password: password,
    );
  }

  LocalSocksAuthSettings copyWith({
    bool? enabled,
    String? username,
    String? password,
  }) =>
      LocalSocksAuthSettings(
        enabled: enabled ?? this.enabled,
        username: username ?? this.username,
        password: password ?? this.password,
      );

  String? get validationError {
    if (username.isEmpty) return 'Введите имя пользователя.';
    if (password.isEmpty) return 'Введите пароль.';
    if (utf8.encode(username).length > 255 ||
        utf8.encode(password).length > 255) {
      return 'Логин и пароль должны быть не длиннее 255 байт.';
    }
    return null;
  }

  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'username': username,
        'password': password,
      };

  String encode() => jsonEncode(toJson());

  static LocalSocksAuthSettings decode(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map) return const LocalSocksAuthSettings();
      return LocalSocksAuthSettings(
        enabled: decoded['enabled'] == true,
        username:
            decoded['username'] is String ? decoded['username'] as String : '',
        password:
            decoded['password'] is String ? decoded['password'] as String : '',
      );
    } on FormatException {
      return const LocalSocksAuthSettings();
    }
  }
}
