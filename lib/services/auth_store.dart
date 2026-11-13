import 'secure_app_state_store.dart';

class AuthStore {
  const AuthStore();
  static const _tokenKey = 'auth_bearer_token';
  Future<String?> readToken() => SecureAppStateStore.read(_tokenKey);
  Future<void> saveToken(String token) =>
      SecureAppStateStore.write(_tokenKey, token);
  Future<void> clear() async {
    await SecureAppStateStore.delete(_tokenKey);
    await SecureAppStateStore.deletePreviousState();
  }
}
