import 'dart:convert';

import 'secure_app_state_store.dart';

class SubscriptionStore {
  const SubscriptionStore();

  static const _externalSubscriptionsKey = 'external_subscriptions';
  static const _favoriteProfilesKey = 'favorite_subscription_profiles';
  Future<List<String>> readExternalSubscriptions() async {
    final value = await SecureAppStateStore.read(_externalSubscriptionsKey);
    if (value == null || value.isEmpty) return const [];
    try {
      final decoded = jsonDecode(value);
      if (decoded is! List) return const [];
      return decoded.whereType<String>().toList(growable: true);
    } on FormatException {
      return const [];
    }
  }

  Future<void> saveExternalSubscriptions(List<String> urls) =>
      SecureAppStateStore.write(
        _externalSubscriptionsKey,
        jsonEncode(urls
            .map((url) => url.trim())
            .where((url) => url.isNotEmpty)
            .toList()),
      );

  Future<Map<String, Set<String>>> readFavoriteProfiles() async {
    final value = await SecureAppStateStore.read(_favoriteProfilesKey);
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
      SecureAppStateStore.write(
        _favoriteProfilesKey,
        jsonEncode({
          for (final entry in favorites.entries)
            if (entry.value.isNotEmpty) entry.key: entry.value.toList(),
        }),
      );
}
