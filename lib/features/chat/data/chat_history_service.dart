import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';

import '../../../services/agent_runtime/runtime_models.dart';

/// Page size for initial latest-message load (fast, lightweight).
/// Older messages load at 30 per page when scrolling up.
const int kMessagePageSize = 10;

/// Persists chat messages per agent using SQLite with pagination support.
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
      version: 3,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            agent_id TEXT NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            actions TEXT,
            image_paths TEXT
          )
        ''');
        await db.execute('''
          CREATE INDEX idx_messages_agent ON messages(agent_id)
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE messages ADD COLUMN actions TEXT');
        }
        if (oldVersion < 3) {
          await db.execute('ALTER TABLE messages ADD COLUMN image_paths TEXT');
        }
      },
    );
  }

  /// Load the latest [limit] messages for an agent (most recent page).
  Future<List<ChatMessage>> loadLatest(
    String agentId, {
    int limit = kMessagePageSize,
  }) async {
    final db = await _database;
    // Get the latest N messages by ordering DESC then reversing.
    final rows = await db.query(
      'messages',
      where: 'agent_id = ?',
      whereArgs: [agentId],
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows.reversed.map((r) => ChatMessage.fromRow(r)).toList();
  }

  /// Load older messages before a given [beforeId] for pagination.
  Future<List<ChatMessage>> loadOlder(
    String agentId, {
    required int beforeId,
    int limit = kMessagePageSize,
  }) async {
    final db = await _database;
    final rows = await db.query(
      'messages',
      where: 'agent_id = ? AND id < ?',
      whereArgs: [agentId, beforeId],
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows.reversed.map((r) => ChatMessage.fromRow(r)).toList();
  }

  /// Load all messages (legacy, for small histories).
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

  /// Get total message count for an agent.
  Future<int> count(String agentId) async {
    final db = await _database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as cnt FROM messages WHERE agent_id = ?',
      [agentId],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Append a single message for an agent. Returns the inserted row ID.
  Future<int> addMessage(String agentId, ChatMessage message) async {
    final db = await _database;
    return db.insert('messages', {
      'agent_id': agentId,
      'role': message.role,
      'content': message.content,
      'timestamp': message.timestamp.toIso8601String(),
      'actions': message.actions.isEmpty
          ? null
          : jsonEncode(message.actions.map((a) => a.toJson()).toList()),
      'image_paths': message.imagePaths.isEmpty
          ? null
          : jsonEncode(message.imagePaths),
    });
  }

  Future<void> updateMessage(ChatMessage message) async {
    final id = message.id;
    if (id == null) return;
    final db = await _database;
    await db.update(
      'messages',
      {
        'role': message.role,
        'content': message.content,
        'timestamp': message.timestamp.toIso8601String(),
        'actions': message.actions.isEmpty
            ? null
            : jsonEncode(message.actions.map((a) => a.toJson()).toList()),
        'image_paths': message.imagePaths.isEmpty
            ? null
            : jsonEncode(message.imagePaths),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
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
        'actions': msg.actions.isEmpty
            ? null
            : jsonEncode(msg.actions.map((a) => a.toJson()).toList()),
        'image_paths': msg.imagePaths.isEmpty
            ? null
            : jsonEncode(msg.imagePaths),
      });
    }
    await batch.commit(noResult: true);
  }

  /// Clear chat history for an agent.
  Future<void> clear(String agentId) async {
    final db = await _database;
    await db.delete('messages', where: 'agent_id = ?', whereArgs: [agentId]);
  }

  /// Delete a single message by row id.
  Future<void> deleteMessage(int id) async {
    final db = await _database;
    await db.delete('messages', where: 'id = ?', whereArgs: [id]);
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
    this.id,
    required this.role,
    required this.content,
    DateTime? timestamp,
    this.actions = const [],
    this.imagePaths = const [],
  }) : timestamp = timestamp ?? DateTime.now();

  final int? id;
  final String role;
  final String content;
  final DateTime timestamp;

  /// Optional contextual action buttons. Persisted as JSON in the DB.
  final List<ResultAction> actions;

  /// File paths for attached images. Persisted as JSON for thumbnail rendering.
  final List<String> imagePaths;

  factory ChatMessage.fromRow(Map<String, dynamic> row) {
    final actionsRaw = row['actions'] as String?;
    final actions = <ResultAction>[];
    if (actionsRaw != null && actionsRaw.isNotEmpty) {
      try {
        final list = jsonDecode(actionsRaw) as List;
        for (final item in list) {
          actions.add(ResultAction.fromJson(item as Map<String, dynamic>));
        }
      } catch (_) {
        // Malformed JSON — ignore.
      }
    }
    final imagePathsRaw = row['image_paths'] as String?;
    final imagePaths = <String>[];
    if (imagePathsRaw != null && imagePathsRaw.isNotEmpty) {
      try {
        final list = jsonDecode(imagePathsRaw) as List;
        for (final item in list) {
          imagePaths.add(item.toString());
        }
      } catch (_) {}
    }
    return ChatMessage(
      id: row['id'] as int?,
      role: row['role'] as String,
      content: row['content'] as String,
      timestamp: DateTime.tryParse(row['timestamp'] as String? ?? ''),
      actions: actions,
      imagePaths: imagePaths,
    );
  }
}

final chatHistoryServiceProvider = Provider<ChatHistoryService>(
  (ref) => ChatHistoryService(),
);
