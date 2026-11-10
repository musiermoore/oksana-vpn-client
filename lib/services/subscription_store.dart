import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SubscriptionStore {
  const SubscriptionStore();

  static const _subscriptionUuidKey = 'subscription_uuid';
  static const _storage = FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );

  Future<String?> readUuid() async {
    final value = await _storage.read(key: _subscriptionUuidKey);
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  Future<void> saveUuid(String uuid) =>
      _storage.write(key: _subscriptionUuidKey, value: uuid.trim());
}
