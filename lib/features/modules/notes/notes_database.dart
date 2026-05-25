import 'package:sqflite/sqflite.dart';

/// Manages the notes SQLite database.
class NotesDatabase {
  NotesDatabase._();
  static final NotesDatabase instance = NotesDatabase._();

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final dbPath = await getDatabasesPath();
    final path = '$dbPath/meow_notes.db';
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE notes (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            content TEXT NOT NULL,
            tags TEXT,
            source TEXT,
            pinned INTEGER DEFAULT 0,
            archived INTEGER DEFAULT 0,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
        // Index for search performance.
        await db.execute(
            'CREATE INDEX idx_notes_updated ON notes(updated_at DESC)');
        await db.execute(
            'CREATE INDEX idx_notes_pinned ON notes(pinned DESC, updated_at DESC)');
      },
    );
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
