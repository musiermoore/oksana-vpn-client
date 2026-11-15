import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../models/vpn_routing_settings.dart';
import '../vpn/vpn_runtime.dart';

class RoutingGeoDataLoader {
  const RoutingGeoDataLoader._();

  static const _maximumGeoDataBytes = 32 * 1024 * 1024;

  static Future<Map<String, List<int>>> download(
      RoutingTemplate template) async {
    final urls = <String, String>{
      if (template.geoipUrl != null) 'geoipData': template.geoipUrl!,
      if (template.geositeUrl != null) 'geositeData': template.geositeUrl!,
    };
    if (urls.isEmpty) return const {};

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final entries = await Future.wait(
        urls.entries.map((entry) async => MapEntry(
              entry.key,
              await _download(client, entry.value),
            )),
      );
      return Map<String, List<int>>.fromEntries(entries);
    } on VpnRuntimeException {
      rethrow;
    } on SocketException {
      throw const VpnRuntimeException(
        'Не удалось загрузить базы геоданных. Проверьте интернет-соединение.',
      );
    } on HttpException {
      throw const VpnRuntimeException('Не удалось загрузить базы геоданных.');
    } on TimeoutException {
      throw const VpnRuntimeException(
        'Загрузка баз геоданных заняла слишком много времени.',
      );
    } finally {
      client.close(force: true);
    }
  }

  static Future<List<int>> _download(HttpClient client, String source) async {
    final parsedUri = Uri.tryParse(source);
    if (parsedUri == null ||
        parsedUri.scheme.toLowerCase() != 'https' ||
        parsedUri.host.isEmpty ||
        parsedUri.userInfo.isNotEmpty) {
      throw const VpnRuntimeException(
        'В шаблоне указана некорректная HTTPS-ссылка на базу геоданных.',
      );
    }
    var uri = parsedUri;

    for (var redirect = 0; redirect <= 5; redirect++) {
      final request =
          await client.getUrl(uri).timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/octet-stream');
      request.headers.set(HttpHeaders.userAgentHeader, 'OksanaVPN-Desktop');

      final response =
          await request.close().timeout(const Duration(seconds: 30));
      if (response.isRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        if (location == null || redirect == 5) {
          throw const VpnRuntimeException(
            'Ссылка на базу геоданных перенаправляет слишком много раз.',
          );
        }
        final redirected = uri.resolve(location);
        if (redirected.scheme.toLowerCase() != 'https' ||
            redirected.host.isEmpty ||
            redirected.userInfo.isNotEmpty) {
          throw const VpnRuntimeException(
            'Ссылка на базу геоданных перенаправляет на небезопасный адрес.',
          );
        }
        uri = redirected;
        continue;
      }
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw VpnRuntimeException(
          'Не удалось загрузить базу геоданных (HTTP ${response.statusCode}).',
        );
      }
      if (response.contentLength > _maximumGeoDataBytes) {
        await response.drain<void>();
        throw const VpnRuntimeException(
          'Файл геоданных слишком большой (максимум 32 МБ).',
        );
      }

      final data = BytesBuilder(copy: false);
      try {
        await for (final chunk
            in response.timeout(const Duration(seconds: 30))) {
          if (data.length + chunk.length > _maximumGeoDataBytes) {
            throw const VpnRuntimeException(
              'Файл геоданных слишком большой (максимум 32 МБ).',
            );
          }
          data.add(chunk);
        }
      } on SocketException {
        throw const VpnRuntimeException(
          'Не удалось загрузить базу геоданных. Проверьте интернет-соединение.',
        );
      } on TimeoutException {
        throw const VpnRuntimeException(
          'Загрузка базы геоданных заняла слишком много времени.',
        );
      }
      if (data.length == 0) {
        throw const VpnRuntimeException(
          'Ссылка вернула пустой файл геоданных.',
        );
      }
      return data.takeBytes();
    }
    throw const VpnRuntimeException('Не удалось загрузить базу геоданных.');
  }
}
