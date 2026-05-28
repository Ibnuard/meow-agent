import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';

import '../../../services/agent_runtime/runtime_models.dart';

/// SQLite-backed debug log for the latest runtime command per agent.
///
/// The table is intentionally scoped to the last command only: starting a new
/// user command clears prior rows for that agent, while confirmation continues
/// append to the same log so sensitive multi-step work remains traceable.
class ChatRuntimeLogService {
  ChatRuntimeLogService({String? overrideDbPath})
    : _overrideDbPath = overrideDbPath;

  final String? _overrideDbPath;
  Database? _db;

  Future<Database> get _database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final dbPath =
        _overrideDbPath ?? '${await getDatabasesPath()}/meow_runtime_logs.db';
    return openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE runtime_log_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            agent_id TEXT NOT NULL,
            event_type TEXT NOT NULL,
            message TEXT NOT NULL,
            data_json TEXT,
            created_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE INDEX idx_runtime_logs_agent
            ON runtime_log_events(agent_id, id)
        ''');
      },
    );
  }

  /// Start a fresh command log for [agentId].
  Future<void> startRun({
    required String agentId,
    required String userMessage,
  }) async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.delete(
        'runtime_log_events',
        where: 'agent_id = ?',
        whereArgs: [agentId],
      );
      await txn.insert('runtime_log_events', {
        'agent_id': agentId,
        'event_type': 'user_request',
        'message': 'User request',
        'data_json': jsonEncode({'message': userMessage}),
        'created_at': DateTime.now().toIso8601String(),
      });
    });
  }

  Future<void> appendEvent({
    required String agentId,
    required RuntimeEvent event,
  }) async {
    await appendRawEvent(
      agentId: agentId,
      type: event.type,
      message: event.message,
      data: event.data,
      createdAt: event.createdAt,
    );
  }

  Future<void> appendRawEvent({
    required String agentId,
    required String type,
    required String message,
    Map<String, dynamic>? data,
    DateTime? createdAt,
  }) async {
    final db = await _database;
    await db.insert('runtime_log_events', {
      'agent_id': agentId,
      'event_type': type,
      'message': message,
      'data_json': data == null ? null : jsonEncode(_jsonSafe(data)),
      'created_at': (createdAt ?? DateTime.now()).toIso8601String(),
    });
  }

  Future<List<ChatRuntimeLogEvent>> loadLast(
    String agentId, {
    int limit = 200,
  }) async {
    final db = await _database;
    final rows = await db.query(
      'runtime_log_events',
      where: 'agent_id = ?',
      whereArgs: [agentId],
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows.reversed.map(ChatRuntimeLogEvent.fromRow).toList();
  }

  Future<void> clear(String agentId) async {
    final db = await _database;
    await db.delete(
      'runtime_log_events',
      where: 'agent_id = ?',
      whereArgs: [agentId],
    );
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  Object? _jsonSafe(Object? value) {
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }
    if (value is DateTime) return value.toIso8601String();
    if (value is Map) {
      return {
        for (final entry in value.entries)
          entry.key.toString(): _jsonSafe(entry.value),
      };
    }
    if (value is Iterable) {
      return value.map(_jsonSafe).toList();
    }
    return value.toString();
  }
}

class ChatRuntimeLogEvent {
  const ChatRuntimeLogEvent({
    this.id,
    required this.agentId,
    required this.type,
    required this.message,
    this.data,
    required this.createdAt,
  });

  final int? id;
  final String agentId;
  final String type;
  final String message;
  final Map<String, dynamic>? data;
  final DateTime createdAt;

  bool get isUserRequest => type == 'user_request';

  factory ChatRuntimeLogEvent.fromRow(Map<String, dynamic> row) {
    Map<String, dynamic>? data;
    final raw = row['data_json'] as String?;
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          data = decoded.cast<String, dynamic>();
        }
      } catch (_) {
        data = {'raw': raw};
      }
    }

    return ChatRuntimeLogEvent(
      id: row['id'] as int?,
      agentId: row['agent_id'] as String,
      type: row['event_type'] as String,
      message: row['message'] as String,
      data: data,
      createdAt:
          DateTime.tryParse(row['created_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

final chatRuntimeLogServiceProvider = Provider<ChatRuntimeLogService>(
  (ref) => ChatRuntimeLogService(),
);
