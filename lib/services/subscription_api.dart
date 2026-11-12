import 'dart:convert';
import 'dart:io';

import '../models/subscription_metadata.dart';
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

  Future<SubscriptionLoadResult> fetchProfiles(String input) async {
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
    if (endpoint.scheme != 'https' ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty) {
      throw const SubscriptionApiException('Адрес API настроен некорректно.');
    }

    final uri = endpoint.replace(
      queryParameters: {...endpoint.queryParameters, 'token': uuid},
    );

    try {
      final request =
          await _client.getUrl(uri).timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.userAgentHeader, 'OksanaVPN-Desktop');

      final response =
          await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        if (response.statusCode == HttpStatus.notFound ||
            response.statusCode == HttpStatus.forbidden) {
          throw const SubscriptionApiException(
            'Подписка не найдена или доступ к ней ограничен.',
          );
        }
        throw const SubscriptionApiException(
            'Сервис подписок временно недоступен.');
      }

      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 30));
      final profiles = _decodeProfiles(body);
      if (profiles.isEmpty) {
        throw const SubscriptionApiException(
            'Для этой подписки нет доступных серверов.');
      }
      return SubscriptionLoadResult(
        profiles: profiles,
        metadata: SubscriptionMetadata.fromHeaders(response.headers),
      );
    } on SubscriptionApiException {
      rethrow;
    } on SocketException {
      throw const SubscriptionApiException(
          'Не удалось подключиться к сервису подписок.');
    } on HttpException {
      throw const SubscriptionApiException(
          'Не удалось получить профили подписки.');
    } on FormatException {
      throw const SubscriptionApiException('Сервис вернул некорректный JSON.');
    } catch (_) {
      throw const SubscriptionApiException(
          'Не удалось загрузить подписку. Попробуйте ещё раз.');
    }
  }

  Future<SubscriptionLoadResult> fetchExternalProfiles(String input) async {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const SubscriptionApiException(
          'Укажите корректную HTTPS-ссылку подписки.');
    }
    try {
      final request =
          await _client.getUrl(uri).timeout(const Duration(seconds: 15));
      request.followRedirects = true;
      request.maxRedirects = 5;
      request.headers
          .set(HttpHeaders.acceptHeader, 'application/json, text/plain, */*');
      request.headers.set(HttpHeaders.userAgentHeader, 'OksanaVPN-Desktop');
      final response =
          await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw const SubscriptionApiException(
            'Не удалось загрузить стороннюю подписку.');
      }
      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 30));
      final profiles = _decodeProfiles(body);
      if (profiles.isEmpty) {
        throw const SubscriptionApiException(
            'В подписке не найдены поддерживаемые профили.');
      }
      return SubscriptionLoadResult(
        profiles: profiles,
        metadata: SubscriptionMetadata.fromHeaders(response.headers),
      );
    } on SubscriptionApiException {
      rethrow;
    } on SocketException {
      throw const SubscriptionApiException(
          'Не удалось подключиться к сторонней подписке.');
    } on FormatException {
      throw const SubscriptionApiException(
          'Сторонняя подписка имеет некорректный формат.');
    } catch (_) {
      throw const SubscriptionApiException(
          'Не удалось загрузить стороннюю подписку.');
    }
  }

  List<SubscriptionProfile> _decodeProfiles(String body) {
    dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      var text = body.trim();
      try {
        final normalized =
            base64.normalize(text.replaceAll(RegExp(r'\s+'), ''));
        text = utf8.decode(base64.decode(normalized));
      } on FormatException {
        // Subscription may already contain one URI per line.
      }
      final profiles = <SubscriptionProfile>[];
      for (final line in text.split(RegExp(r'[\r\n]+'))) {
        final profile = _profileFromVlessUri(line.trim(), profiles.length + 1);
        if (profile != null) profiles.add(profile);
      }
      return profiles;
    }
    if (decoded is Map && decoded['outbounds'] is List) decoded = [decoded];
    if (decoded is! List) return const [];
    final profiles = <SubscriptionProfile>[];
    for (final item in decoded) {
      if (item is! Map || item['outbounds'] is! List) continue;
      final configuration = Map<String, dynamic>.from(item);
      profiles.add(SubscriptionProfile(
          configuration: configuration, index: profiles.length + 1));
    }
    return profiles;
  }

  SubscriptionProfile? _profileFromVlessUri(String value, int index) {
    if (!value.startsWith('vless://')) return null;
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty || uri.userInfo.isEmpty) return null;
    final userId = uri.userInfo;
    final port = uri.hasPort ? uri.port : 443;
    final query = uri.queryParameters;
    final network = query['type'] ?? 'tcp';
    final security = query['security'] ?? 'none';
    final user = <String, dynamic>{'id': userId, 'encryption': 'none'};
    if ((query['flow'] ?? '').isNotEmpty) user['flow'] = query['flow'];
    final outbound = <String, dynamic>{
      'tag': 'proxy',
      'protocol': 'vless',
      'settings': {
        'vnext': [
          {
            'address': uri.host,
            'port': port,
            'users': [user]
          }
        ]
      },
      'streamSettings': {'network': network, 'security': security},
    };
    final stream = outbound['streamSettings'] as Map<String, dynamic>;
    if (security == 'tls' || security == 'reality') {
      final tls = <String, dynamic>{
        'serverName': query['sni'] ?? query['host'] ?? uri.host,
        'allowInsecure': false,
      };
      if ((query['alpn'] ?? '').isNotEmpty) {
        tls['alpn'] = query['alpn']!.split(',');
      }
      if (security == 'reality') {
        tls['publicKey'] = query['pbk'] ?? '';
        tls['shortId'] = query['sid'] ?? '';
        tls['fingerprint'] = query['fp'] ?? 'chrome';
        tls['spiderX'] = query['spx'] ?? '/';
        stream['realitySettings'] = tls;
      } else {
        if ((query['fp'] ?? '').isNotEmpty) {
          tls['fingerprint'] = query['fp'];
        }
        stream['tlsSettings'] = tls;
      }
    }
    if (network == 'ws') {
      stream['wsSettings'] = {
        'path': query['path'] ?? '/',
        'headers': {'Host': query['host'] ?? uri.host}
      };
    } else if (network == 'grpc') {
      stream['grpcSettings'] = {'serviceName': query['serviceName'] ?? ''};
    } else if (network == 'httpupgrade') {
      stream['httpupgradeSettings'] = {
        'path': query['path'] ?? '/',
        'host': query['host'] ?? uri.host
      };
    } else if (network == 'xhttp') {
      stream['xhttpSettings'] = {
        'path': query['path'] ?? '/',
        'host': query['host'] ?? uri.host,
        if ((query['mode'] ?? '').isNotEmpty) 'mode': query['mode'],
      };
    }
    final label = uri.fragment.isEmpty
        ? 'Сервер $index'
        : Uri.decodeComponent(uri.fragment);
    final config = <String, dynamic>{
      'remarks': label,
      'outbounds': [outbound]
    };
    return SubscriptionProfile(configuration: config, index: index);
  }

  void close() => _client.close(force: true);
}
