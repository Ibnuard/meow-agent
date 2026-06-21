import 'package:sqflite/sqflite.dart';

/// Isolated SQLite database for user-defined tables.
///
/// Completely separate from [MeowDatabase] (meow_core.db) — this is the user's
/// personal data sandbox where they and agents can freely create tables.
///
/// Only stores user-defined data tables. Internal metadata about which tables
/// exist is derived by querying sqlite_master — no separate registry table
/// needed, which means the DB is always self-consistent.
class UserDatabase {
  UserDatabase._();
  static final UserDatabase instance = UserDatabase._();

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final dbPath = await getDatabasesPath();
    final path = '$dbPath/meow_user.db';
    return openDatabase(
      path,
      version: 1,
      // No fixed schema — tables are created dynamically by the agent.
      onCreate: (db, version) async {
        // Intentionally empty: all tables are user/agent-defined.
      },
    );
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
