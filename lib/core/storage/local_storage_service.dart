import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app_settings_repository.dart';

/// Non-sensitive local storage backed by SQLite app_settings.
/// Replaces the legacy SharedPreferences implementation.
///
/// Keeps an in-memory cache of all settings for synchronous reads,
/// and writes through to SQLite asynchronously.
class LocalStorageService {
  LocalStorageService(this._settingsRepo, Map<String, String> initialSettings)
      : _cache = Map<String, String>.from(initialSettings);

  final AppSettingsRepository _settingsRepo;
  final Map<String, String> _cache;

  final List<Future<void>> _pendingWrites = [];

  /// Returns a Future that completes when all currently pending database writes are finished.
  Future<void> get waitForPendingWrites => Future.wait(_pendingWrites);

  String? readString(String key) => _cache[key];

  Future<bool> writeString(String key, String value) async {
    _cache[key] = value;
    final fut = _settingsRepo.set(key, value);
    _pendingWrites.add(fut);
    try {
      await fut;
    } finally {
      _pendingWrites.remove(fut);
    }
    return true;
  }

  bool? readBool(String key) {
    final val = _cache[key];
    if (val == null) return null;
    return val == 'true';
  }

  Future<bool> writeBool(String key, bool value) async {
    final strVal = value ? 'true' : 'false';
    _cache[key] = strVal;
    final fut = _settingsRepo.set(key, strVal);
    _pendingWrites.add(fut);
    try {
      await fut;
    } finally {
      _pendingWrites.remove(fut);
    }
    return true;
  }

  int? readInt(String key) {
    final val = _cache[key];
    if (val == null) return null;
    return int.tryParse(val);
  }

  Future<bool> writeInt(String key, int value) async {
    final strVal = value.toString();
    _cache[key] = strVal;
    final fut = _settingsRepo.set(key, strVal);
    _pendingWrites.add(fut);
    try {
      await fut;
    } finally {
      _pendingWrites.remove(fut);
    }
    return true;
  }

  Future<bool> remove(String key) async {
    _cache.remove(key);
    final fut = _settingsRepo.remove(key);
    _pendingWrites.add(fut);
    try {
      await fut;
    } finally {
      _pendingWrites.remove(fut);
    }
    return true;
  }
}

/// Async-initialised provider. Override the `localStorageProvider` provider in `main`
/// once LocalStorageService has been resolved.
final localStorageProvider = Provider<LocalStorageService>(
  (ref) => throw UnimplementedError(
    'Override localStorageProvider with the resolved instance in main.',
  ),
);

