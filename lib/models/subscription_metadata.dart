import 'dart:convert';
import 'dart:io';

import 'subscription_profile.dart';

class SubscriptionMetadata {
  const SubscriptionMetadata({
    this.title,
    this.updateInterval,
    this.webPageUrl,
    this.announceUrl,
    this.uploadBytes,
    this.downloadBytes,
    this.totalBytes,
    this.expiresAt,
    this.supportUrl,
    this.devicesLimit,
    this.devicesUsed,
  });

  final String? title;
  final String? updateInterval;
  final String? webPageUrl;
  final String? announceUrl;
  final int? uploadBytes;
  final int? downloadBytes;
  final int? totalBytes;
  final int? expiresAt;
  final String? supportUrl;
  final int? devicesLimit;
  final int? devicesUsed;

  Duration? get refreshInterval {
    final hours = int.tryParse(updateInterval ?? '');
    if (hours == null || hours <= 0) return null;
    return Duration(hours: hours.clamp(1, 168).toInt());
  }

  factory SubscriptionMetadata.fromHeaders(HttpHeaders headers) {
    final userInfo = headers.value('subscription-userinfo') ?? '';
    final values = <String, int>{};
    for (final part in userInfo.split(';')) {
      final separator = part.indexOf('=');
      if (separator <= 0) continue;
      final key = part.substring(0, separator).trim().toLowerCase();
      final value = int.tryParse(part.substring(separator + 1).trim());
      if (value != null) values[key] = value;
    }

    return SubscriptionMetadata(
      title: _decodeTitle(_header(headers, 'profile-title')),
      updateInterval: _header(headers, 'profile-update-interval'),
      webPageUrl: _header(headers, 'profile-web-page-url'),
      announceUrl: _header(headers, 'announce-url'),
      uploadBytes: values['upload'],
      downloadBytes: values['download'],
      totalBytes: values['total'],
      expiresAt: values['expire'],
      supportUrl: _header(headers, 'support-url'),
      devicesLimit:
          int.tryParse(_header(headers, 'x-subscription-devices-limit') ?? ''),
      devicesUsed:
          int.tryParse(_header(headers, 'x-subscription-devices-used') ?? ''),
    );
  }

  static String? _header(HttpHeaders headers, String name) {
    final value = headers.value(name)?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  static String? _decodeTitle(String? value) {
    if (value == null) return null;
    if (!value.startsWith('base64:')) return _decodeRawUtf8Header(value);
    try {
      return utf8.decode(base64.decode(base64.normalize(value.substring(7))));
    } on FormatException {
      return value;
    }
  }

  static String _decodeRawUtf8Header(String value) {
    if (value.codeUnits.any((unit) => unit > 0xff)) return value;
    try {
      final decoded = utf8.decode(value.codeUnits);
      final containsCyrillic = decoded.runes.any(
        (rune) => rune >= 0x0400 && rune <= 0x052f,
      );
      return containsCyrillic ? decoded : value;
    } on FormatException {
      return value;
    }
  }
}

class SubscriptionLoadResult {
  const SubscriptionLoadResult(
      {required this.profiles, required this.metadata});

  final List<SubscriptionProfile> profiles;
  final SubscriptionMetadata metadata;
}
