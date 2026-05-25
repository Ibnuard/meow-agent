import 'package:sqflite/sqflite.dart';

/// SQLite database for calendar events.
class CalendarDatabase {
  CalendarDatabase._();
  static final CalendarDatabase instance = CalendarDatabase._();

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final dbPath = await getDatabasesPath();
    return openDatabase(
      '$dbPath/meow_calendar.db',
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE calendar_events (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            description TEXT DEFAULT '',
            start_time INTEGER NOT NULL,
            end_time INTEGER NOT NULL,
            all_day INTEGER DEFAULT 0,
            color TEXT,
            tags TEXT DEFAULT '',
            source TEXT DEFAULT 'user',
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_events_start ON calendar_events(start_time)',
        );
        await db.execute(
          'CREATE INDEX idx_events_end ON calendar_events(end_time)',
        );
      },
    );
  }
}
