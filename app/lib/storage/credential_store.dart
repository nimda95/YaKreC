import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class CredentialStore {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static String _key(String deviceId) => 'kvm.cred.$deviceId';

  static Future<void> setPassword(String deviceId, String? password) async {
    final k = _key(deviceId);
    if (password == null || password.isEmpty) {
      await _storage.delete(key: k);
    } else {
      await _storage.write(key: k, value: password);
    }
  }

  static Future<String?> getPassword(String deviceId) =>
      _storage.read(key: _key(deviceId));

  static Future<void> deletePassword(String deviceId) =>
      _storage.delete(key: _key(deviceId));
}
