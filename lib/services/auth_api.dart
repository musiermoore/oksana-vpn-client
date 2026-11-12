import 'dart:convert';
import 'dart:io';

const _authApiBaseUrl = String.fromEnvironment(
  'AUTH_API_BASE_URL',
  defaultValue: 'https://api.oksana1984.ru/api/v1',
);

class AuthApiException implements Exception {
  const AuthApiException(this.message);
  final String message;
}

class AuthProfile {
  const AuthProfile({required this.uuid, required this.name});
  final String uuid;
  final String name;
}

class AuthApi {
  AuthApi({HttpClient? client}) : _client = client ?? HttpClient();
  final HttpClient _client;

  Uri _endpoint(String path) {
    final base = Uri.parse(_authApiBaseUrl);
    if (base.scheme != 'https' ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty) {
      throw const AuthApiException(
          'Адрес API авторизации настроен некорректно.');
    }
    final basePath = base.path.endsWith('/') ? base.path : '${base.path}/';
    return base.replace(path: '$basePath$path', query: null, fragment: null);
  }

  Future<String> login(String login, String password) async {
    try {
      final request = await _client.postUrl(_endpoint('auth/login'));
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.write(jsonEncode({'login': login.trim(), 'password': password}));
      final response =
          await request.close().timeout(const Duration(seconds: 30));
      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != HttpStatus.ok) {
        throw AuthApiException(response.statusCode == HttpStatus.unauthorized
            ? 'Неверный логин или пароль.'
            : 'Не удалось выполнить вход. Проверьте подключение и попробуйте ещё раз.');
      }
      final decoded = jsonDecode(body);
      final token =
          decoded is Map ? decoded['access_token'] ?? decoded['token'] : null;
      if (token is! String || token.isEmpty) {
        throw const AuthApiException(
            'Сервис авторизации вернул некорректный ответ.');
      }
      return token;
    } on AuthApiException {
      rethrow;
    } on SocketException {
      throw const AuthApiException(
          'Не удалось подключиться к сервису авторизации.');
    } on FormatException {
      throw const AuthApiException(
          'Сервис авторизации вернул некорректный ответ.');
    } catch (_) {
      throw const AuthApiException(
          'Не удалось выполнить вход. Попробуйте ещё раз.');
    }
  }

  Future<String> exchangeTelegramTicket(String ticket) async {
    try {
      final request =
          await _client.postUrl(_endpoint('auth/telegram/oidc/exchange'));
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.write(jsonEncode({'ticket': ticket}));
      final response =
          await request.close().timeout(const Duration(seconds: 30));
      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != HttpStatus.ok) {
        throw const AuthApiException(
            'Билет входа истёк или уже использован. Повторите вход через Telegram.');
      }
      final decoded = jsonDecode(body);
      final token = decoded is Map ? decoded['access_token'] : null;
      if (token is! String || token.isEmpty) {
        throw const AuthApiException(
            'Сервис авторизации вернул некорректный ответ.');
      }
      return token;
    } on AuthApiException {
      rethrow;
    } on SocketException {
      throw const AuthApiException(
          'Не удалось подключиться к сервису авторизации.');
    } on FormatException {
      throw const AuthApiException(
          'Сервис авторизации вернул некорректный ответ.');
    } catch (_) {
      throw const AuthApiException('Не удалось завершить вход через Telegram.');
    }
  }

  Future<AuthProfile> fetchProfile(String token) async {
    try {
      final request = await _client.getUrl(_endpoint('auth/me'));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final response =
          await request.close().timeout(const Duration(seconds: 30));
      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != HttpStatus.ok) {
        throw const AuthApiException('Сессия истекла. Войдите снова.');
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map ||
          decoded['uuid'] is! String ||
          (decoded['uuid'] as String).isEmpty) {
        throw const AuthApiException('В профиле не найден UUID подписки.');
      }
      return AuthProfile(
          uuid: decoded['uuid'] as String,
          name: decoded['name'] is String ? decoded['name'] as String : '');
    } on AuthApiException {
      rethrow;
    } on SocketException {
      throw const AuthApiException(
          'Не удалось подключиться к сервису авторизации.');
    } on FormatException {
      throw const AuthApiException(
          'Сервис авторизации вернул некорректный ответ.');
    } catch (_) {
      throw const AuthApiException(
          'Не удалось загрузить профиль. Попробуйте ещё раз.');
    }
  }

  Future<void> logout(String token) async {
    try {
      final request = await _client.postUrl(_endpoint('auth/logout'));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response =
          await request.close().timeout(const Duration(seconds: 20));
      await response.drain<void>().timeout(const Duration(seconds: 5));
    } catch (_) {
      // The local credential is cleared even when the API cannot be reached.
    }
  }

  void close() => _client.close(force: true);
}
