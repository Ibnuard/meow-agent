import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';

import 'meow_database.dart';
import 'meow_database_provider.dart';

/// Key-value app-level settings store. Replaces the `meow.json` settings
/// section (language, active agent id, autoCompact defaults, etc.).
///
/// Values are always strings — callers serialize/deserialize as needed.
class AppSettingsRepository {
  AppSettingsRepository(this._db);

  final MeowDatabase _db;
  final _controller = StreamController<Map<String, String>>.broadcast();

  /// Reactive view of all settings. Convenience for screens that need to
  /// react to multiple keys without subscribing one-by-one.
  Stream<Map<String, String>> watchAll() async* {
    yield await getAll();
    yield* _controller.stream;
  }

  Future<Map<String, String>> getAll() async {
    final db = await _db.database;
    final rows = await db.query('app_settings');
    return {
      for (final row in rows)
        row['key'] as String: row['value'] as String,
    };
  }

  Future<String?> get(String key) async {
    final db = await _db.database;
    final rows = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: [key],
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<void> set(String key, String value) async {
    final db = await _db.database;
    await db.insert(
      'app_settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _notify();
  }

  Future<void> remove(String key) async {
    final db = await _db.database;
    await db.delete('app_settings', where: 'key = ?', whereArgs: [key]);
    _notify();
  }

  void _notify() async {
    _controller.add(await getAll());
  }

  void dispose() {
    _controller.close();
  }
}

// ---------------------------------------------------------------------------
// Riverpod Providers
// ---------------------------------------------------------------------------

final appSettingsRepositoryProvider = Provider<AppSettingsRepository>((ref) {
  final db = ref.read(meowDatabaseProvider);
  final repo = AppSettingsRepository(db);
  ref.onDispose(repo.dispose);
  return repo;
});

final appSettingsStreamProvider = StreamProvider<Map<String, String>>((ref) {
  return ref.read(appSettingsRepositoryProvider).watchAll();
});
