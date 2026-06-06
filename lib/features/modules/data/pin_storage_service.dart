import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Service for securely storing and retrieving device PIN.
class PinStorageService {
  PinStorageService._();
  static final instance = PinStorageService._();

  static const _key = 'meow_agent_device_pin';
  static const _storage = FlutterSecureStorage();

  /// Check if a PIN has been stored.
  Future<bool> hasPin() async {
    return await _storage.containsKey(key: _key);
  }

  /// Store a PIN securely.
  Future<void> savePin(String pin) async {
    await _storage.write(key: _key, value: pin);
  }

  /// Retrieve the stored PIN.
  Future<String?> getPin() async {
    return await _storage.read(key: _key);
  }

  /// Delete the stored PIN.
  Future<void> deletePin() async {
    await _storage.delete(key: _key);
  }
}
