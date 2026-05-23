import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Non-sensitive local storage backed by shared_preferences.
class LocalStorageService {
  LocalStorageService(this._prefs);

  final SharedPreferences _prefs;

  String? readString(String key) => _prefs.getString(key);
  Future<bool> writeString(String key, String value) =>
      _prefs.setString(key, value);

  bool? readBool(String key) => _prefs.getBool(key);
  Future<bool> writeBool(String key, bool value) =>
      _prefs.setBool(key, value);

  Future<bool> remove(String key) => _prefs.remove(key);
}

/// Async-initialised provider. Override the `prefs` provider in `main`
/// once SharedPreferences has been resolved.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError(
    'Override sharedPreferencesProvider with the resolved instance in main.',
  ),
);

final localStorageProvider = Provider<LocalStorageService>(
  (ref) => LocalStorageService(ref.watch(sharedPreferencesProvider)),
);
