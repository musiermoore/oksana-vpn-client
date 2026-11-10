import 'dart:convert';
import 'dart:io';

import '../models/subscription_profile.dart';

const _subscriptionEndpoint = String.fromEnvironment(
  'SUBSCRIPTION_ENDPOINT',
  defaultValue: 'https://connect.oksana1984.ru/start',
);

class SubscriptionApiException implements Exception {
  const SubscriptionApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SubscriptionApi {
  SubscriptionApi({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  static final _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  static bool isValidUuid(String value) => _uuidPattern.hasMatch(value.trim());

  Future<List<SubscriptionProfile>> fetchProfiles(String input) async {
    final uuid = input.trim();
    if (!isValidUuid(uuid)) {
      throw const SubscriptionApiException('Введите корректный UUID подписки.');
    }

    late final Uri endpoint;
    try {
      endpoint = Uri.parse(_subscriptionEndpoint);
    } on FormatException {
      throw const SubscriptionApiException('Адрес API настроен некорректно.');
    }
    if (endpoint.scheme != 'https' || endpoint.host.isEmpty || endpoint.userInfo.isNotEmpty) {
      throw const SubscriptionApiException('Адрес API настроен некорректно.');
    }

    final uri = endpoint.replace(
      queryParameters: {...endpoint.queryParameters, 'token': uuid},
    );

    try {
      final request = await _client.getUrl(uri).timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.userAgentHeader, 'OksanaVPN-Desktop');

      final response = await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        if (response.statusCode == HttpStatus.notFound ||
            response.statusCode == HttpStatus.forbidden) {
          throw const SubscriptionApiException(
            'Подписка не найдена или доступ к ней ограничен.',
          );
        }
        throw const SubscriptionApiException('Сервис подписок временно недоступен.');
      }

      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 30));
      final decoded = jsonDecode(body);
      if (decoded is! List) {
        throw const SubscriptionApiException('Сервис вернул неожиданный формат профилей.');
      }

      final profiles = <SubscriptionProfile>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        final profile = Map<String, dynamic>.from(item);
        if (profile['outbounds'] is! List) continue;
        profiles.add(SubscriptionProfile(
          configuration: profile,
          index: profiles.length + 1,
        ));
      }

      if (profiles.isEmpty) {
        throw const SubscriptionApiException('Для этой подписки нет доступных серверов.');
      }
      return profiles;
    } on SubscriptionApiException {
      rethrow;
    } on SocketException {
      throw const SubscriptionApiException('Не удалось подключиться к сервису подписок.');
    } on HttpException {
      throw const SubscriptionApiException('Не удалось получить профили подписки.');
    } on FormatException {
      throw const SubscriptionApiException('Сервис вернул некорректный JSON.');
    } catch (_) {
      throw const SubscriptionApiException('Не удалось загрузить подписку. Попробуйте ещё раз.');
    }
  }

  void close() => _client.close(force: true);
}
