import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SubscriptionStore {
  const SubscriptionStore();

  static const _externalSubscriptionsKey = 'external_subscriptions';
  static const _favoriteProfilesKey = 'favorite_subscription_profiles';
  static const _storage = FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );

  Future<List<String>> readExternalSubscriptions() async {
    final value = await _storage.read(key: _externalSubscriptionsKey);
    if (value == null || value.isEmpty) return const [];
    try {
      final decoded = jsonDecode(value);
      if (decoded is! List) return const [];
      return decoded.whereType<String>().toList(growable: true);
    } on FormatException {
      return const [];
    }
  }

  Future<void> saveExternalSubscriptions(List<String> urls) => _storage.write(
        key: _externalSubscriptionsKey,
        value: jsonEncode(urls
            .map((url) => url.trim())
            .where((url) => url.isNotEmpty)
            .toList()),
      );

  Future<Map<String, Set<String>>> readFavoriteProfiles() async {
    final value = await _storage.read(key: _favoriteProfilesKey);
    if (value == null || value.isEmpty) return const {};
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map) return const {};
      return {
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is List)
            entry.key as String:
                (entry.value as List).whereType<String>().toSet(),
      };
    } on FormatException {
      return const {};
    }
  }

  Future<void> saveFavoriteProfiles(Map<String, Set<String>> favorites) =>
      _storage.write(
        key: _favoriteProfilesKey,
        value: jsonEncode({
          for (final entry in favorites.entries)
            if (entry.value.isNotEmpty) entry.key: entry.value.toList(),
        }),
      );
}
