import 'package:uuid/uuid.dart';

import 'notes_database.dart';
import 'notes_models.dart';

/// Repository for CRUD operations on notes.
class NotesRepository {
  NotesRepository();

  static const _uuid = Uuid();

  Future<Note> createNote({
    required String title,
    required String content,
    List<String> tags = const [],
    String source = 'user',
  }) async {
    final db = await NotesDatabase.instance.database;
    final now = DateTime.now();
    final note = Note(
      id: 'note_${_uuid.v4().substring(0, 8)}',
      title: title,
      content: content,
      tags: tags,
      source: source,
      createdAt: now,
      updatedAt: now,
    );
    await db.insert('notes', note.toDbMap());
    return note;
  }

  Future<List<Note>> listRecentNotes({int limit = 20}) async {
    final db = await NotesDatabase.instance.database;
    final rows = await db.query(
      'notes',
      where: 'archived = 0',
      orderBy: 'pinned DESC, updated_at DESC',
      limit: limit,
    );
    return rows.map(Note.fromDbMap).toList();
  }

  Future<Note?> getNote(String id) async {
    final db = await NotesDatabase.instance.database;
    final rows = await db.query('notes', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return Note.fromDbMap(rows.first);
  }

  Future<List<Note>> searchNotes(String query, {int limit = 20}) async {
    if (query.trim().isEmpty) return [];
    final db = await NotesDatabase.instance.database;
    final pattern = '%${query.trim()}%';
    final rows = await db.query(
      'notes',
      where: '(title LIKE ? OR content LIKE ? OR tags LIKE ?) AND archived = 0',
      whereArgs: [pattern, pattern, pattern],
      orderBy: 'updated_at DESC',
      limit: limit,
    );
    return rows.map(Note.fromDbMap).toList();
  }

  Future<Note> updateNote(
    String id, {
    String? title,
    String? content,
    List<String>? tags,
    bool? pinned,
    bool? archived,
  }) async {
    final db = await NotesDatabase.instance.database;
    final existing = await getNote(id);
    if (existing == null) {
      throw Exception('Note not found: $id');
    }
    final updated = existing.copyWith(
      title: title,
      content: content,
      tags: tags,
      pinned: pinned,
      archived: archived,
      updatedAt: DateTime.now(),
    );
    await db.update(
      'notes',
      updated.toDbMap(),
      where: 'id = ?',
      whereArgs: [id],
    );
    return updated;
  }

  Future<int> deleteNote(String id) async {
    final db = await NotesDatabase.instance.database;
    return db.delete('notes', where: 'id = ?', whereArgs: [id]);
  }
}
