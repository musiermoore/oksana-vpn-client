import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Keeps the app's persisted values in one Keychain item to avoid prompting
/// for access to several separate items at startup.
class SecureAppStateStore {
  SecureAppStateStore._();

  // Reuse the existing token item so this change does not require a new
  // Keychain access permission for a second item.
  static const _stateKey = 'auth_bearer_token';
  static const _previousStateKey = 'oksana_vpn_secure_app_state_v1';
  static const _statePrefix = 'oksana-vpn-state-v1:';
  static const _legacyKeys = {
    'auth_bearer_token',
    'app_theme_mode',
    'vpn_mode',
    'external_subscriptions',
    'favorite_subscription_profiles',
  };
  static const _storage = FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );

  static Map<String, String> _values = {};
  static bool _loaded = false;
  static Future<void>? _loading;
  static Future<void> _writeQueue = Future<void>.value();

  static Future<String?> read(String key) async {
    await _ensureLoaded();
    return _values[key];
  }

  static Future<void> write(String key, String value) async {
    await _ensureLoaded();
    _values[key] = value;
    await _persist();
  }

  static Future<void> delete(String key) async {
    await _ensureLoaded();
    if (_values.remove(key) != null) await _persist();
  }

  static Future<void> deletePreviousState() async {
    try {
      await _storage.delete(key: _previousStateKey);
    } catch (_) {
      // The active session has already been removed from the current item.
    }
  }

  static Future<void> _ensureLoaded() async {
    if (_loaded) return;
    final pending = _loading;
    if (pending != null) {
      await pending;
      _loaded = true;
      return;
    }

    final load = _load();
    _loading = load;
    try {
      await load;
      _loaded = true;
    } catch (_) {
      _loading = null;
      rethrow;
    }
  }

  static Future<void> _load() async {
    final storedState = await _storage.read(key: _stateKey);
    if (storedState != null && storedState.isNotEmpty) {
      final decoded = _decodeState(storedState, requirePrefix: true);
      if (decoded != null) {
        _values = decoded;
        return;
      }
    }

    String? previousState;
    try {
      previousState = await _storage.read(key: _previousStateKey);
    } catch (_) {
      // Continue from the existing per-key values if the transitional item
      // has a separate Keychain permission.
    }
    final previousValues = previousState == null
        ? null
        : _decodeState(previousState, allowPlainJson: true);
    if (previousValues != null) {
      _values = previousValues;
      await _persist();
      await deletePreviousState();
      return;
    }

    _values = {};
    for (final key in _legacyKeys) {
      String? value;
      if (key == _stateKey) {
        value = storedState;
      } else {
        try {
          value = await _storage.read(key: key);
        } catch (_) {
          // One inaccessible preference must not block session restoration.
          continue;
        }
      }
      if (value != null) _values[key] = value;
    }
    if (_values.isNotEmpty) await _persist();
  }

  static Future<void> _persist() {
    final snapshot =
        '$_statePrefix${base64Encode(utf8.encode(jsonEncode(_values)))}';
    final write = _writeQueue.then((_) async {
      await _storage.write(key: _stateKey, value: snapshot);
    });
    _writeQueue = write.catchError((_) {});
    return write;
  }

  static Map<String, String>? _decodeState(
    String value, {
    bool requirePrefix = false,
    bool allowPlainJson = false,
  }) {
    final hasPrefix = value.startsWith(_statePrefix);
    if (requirePrefix && !hasPrefix) return null;
    final encoded = hasPrefix ? value.substring(_statePrefix.length) : value;
    final decoders = <Object? Function()>[
      () => jsonDecode(utf8.decode(base64Decode(encoded))),
      if (allowPlainJson) () => jsonDecode(value),
    ];
    for (final decode in decoders) {
      try {
        final decoded = decode();
        if (decoded is Map) {
          return {
            for (final entry in decoded.entries)
              if (entry.key is String && entry.value is String)
                entry.key as String: entry.value as String,
          };
        }
      } on FormatException {
        // Try the other supported representation.
      }
    }
    return null;
  }
}
