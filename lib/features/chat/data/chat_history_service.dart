import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';

/// Persists chat messages per agent using SQLite.
class ChatHistoryService {
  Database? _db;

  Future<Database> get _database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final dbDir = await getDatabasesPath();
    final dbPath = '$dbDir/meow_chat.db';
    return openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            agent_id TEXT NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            timestamp TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE INDEX idx_messages_agent ON messages(agent_id)
        ''');
      },
    );
  }

  /// Load messages for an agent.
  Future<List<ChatMessage>> load(String agentId) async {
    final db = await _database;
    final rows = await db.query(
      'messages',
      where: 'agent_id = ?',
      whereArgs: [agentId],
      orderBy: 'id ASC',
    );
    return rows.map((r) => ChatMessage.fromRow(r)).toList();
  }

  /// Append a single message for an agent.
  Future<void> addMessage(String agentId, ChatMessage message) async {
    final db = await _database;
    await db.insert('messages', {
      'agent_id': agentId,
      'role': message.role,
      'content': message.content,
      'timestamp': message.timestamp.toIso8601String(),
    });
  }

  /// Append multiple messages at once.
  Future<void> addMessages(String agentId, List<ChatMessage> messages) async {
    final db = await _database;
    final batch = db.batch();
    for (final msg in messages) {
      batch.insert('messages', {
        'agent_id': agentId,
        'role': msg.role,
        'content': msg.content,
        'timestamp': msg.timestamp.toIso8601String(),
      });
    }
    await batch.commit(noResult: true);
  }

  /// Clear chat history for an agent.
  Future<void> clear(String agentId) async {
    final db = await _database;
    await db.delete('messages', where: 'agent_id = ?', whereArgs: [agentId]);
  }

  /// Clear all chat histories.
  Future<void> clearAll() async {
    final db = await _database;
    await db.delete('messages');
  }

  /// Close the database.
  Future<void> close() async {
    final db = await _database;
    await db.close();
    _db = null;
  }
}

/// A single chat message.
class ChatMessage {
  ChatMessage({
    required this.role,
    required this.content,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  final String role;
  final String content;
  final DateTime timestamp;

  factory ChatMessage.fromRow(Map<String, dynamic> row) => ChatMessage(
        role: row['role'] as String,
        content: row['content'] as String,
        timestamp: DateTime.tryParse(row['timestamp'] as String? ?? ''),
      );
}

final chatHistoryServiceProvider = Provider<ChatHistoryService>(
  (ref) => ChatHistoryService(),
);
