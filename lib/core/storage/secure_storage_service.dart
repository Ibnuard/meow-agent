import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Wrapper around flutter_secure_storage. Used for sensitive values
/// like the LLM API key.
class SecureStorageService {
  SecureStorageService(this._storage);

  static const _options = AndroidOptions(
    encryptedSharedPreferences: true,
  );

  final FlutterSecureStorage _storage;

  Future<String?> read(String key) =>
      _storage.read(key: key, aOptions: _options);

  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value, aOptions: _options);

  Future<void> delete(String key) =>
      _storage.delete(key: key, aOptions: _options);

  Future<void> deleteAll() => _storage.deleteAll(aOptions: _options);
}

final secureStorageProvider = Provider<SecureStorageService>(
  (ref) => SecureStorageService(const FlutterSecureStorage()),
);
