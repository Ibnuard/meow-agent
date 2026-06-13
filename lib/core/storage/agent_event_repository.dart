import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'meow_database.dart';
import 'meow_database_provider.dart';

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

/// Activity / heartbeat event. Replaces HEARTBEAT.md.
class AgentEvent {
  const AgentEvent({
    required this.id,
    required this.agentId,
    required this.eventType,
    this.state,
    this.task,
    this.lastTool,
    this.lastResult,
    required this.createdAt,
  });

  final int id;
  final String agentId;
  final String eventType;
  final String? state;
  final String? task;
  final String? lastTool;
  final String? lastResult;
  final DateTime createdAt;

  factory AgentEvent.fromRow(Map<String, dynamic> row) => AgentEvent(
    id: row['id'] as int,
    agentId: row['agent_id'] as String,
    eventType: row['event_type'] as String,
    state: row['state'] as String?,
    task: row['task'] as String?,
    lastTool: row['last_tool'] as String?,
    lastResult: row['last_result'] as String?,
    createdAt: DateTime.parse(row['created_at'] as String),
  );
}

// ---------------------------------------------------------------------------
// Repository
// ---------------------------------------------------------------------------

/// Activity event log per agent. Replaces the legacy HEARTBEAT.md write
/// loop with a single-row INSERT per event.
///
/// Insert-only on the hot path. Reads are query-by-time-range or
/// query-by-event-type, both indexed.
class AgentEventRepository {
  AgentEventRepository(this._db);

  final MeowDatabase _db;

  /// Log an activity event. Insert-only, returns nothing on the hot path.
  Future<void> log({
    required String agentId,
    required String eventType,
    String? state,
    String? task,
    String? lastTool,
    String? lastResult,
  }) async {
    final db = await _db.database;
    await db.insert('agent_events', {
      'agent_id': agentId,
      'event_type': eventType,
      'state': state,
      'task': task,
      'last_tool': lastTool,
      'last_result': lastResult,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  /// Most recent [limit] events for an agent.
  Future<List<AgentEvent>> recent(
    String agentId, {
    int limit = 50,
  }) async {
    final db = await _db.database;
    final rows = await db.query(
      'agent_events',
      where: 'agent_id = ?',
      whereArgs: [agentId],
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(AgentEvent.fromRow).toList();
  }

  /// Filter by event type.
  Future<List<AgentEvent>> byType(
    String agentId,
    String eventType, {
    int limit = 50,
  }) async {
    final db = await _db.database;
    final rows = await db.query(
      'agent_events',
      where: 'agent_id = ? AND event_type = ?',
      whereArgs: [agentId, eventType],
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(AgentEvent.fromRow).toList();
  }

  /// Trim events older than [keep] count to bound storage growth.
  Future<int> pruneOlderThan(String agentId, {int keep = 1000}) async {
    final db = await _db.database;
    return db.rawDelete(
      '''
      DELETE FROM agent_events
      WHERE agent_id = ?
        AND id NOT IN (
          SELECT id FROM agent_events
          WHERE agent_id = ?
          ORDER BY created_at DESC
          LIMIT ?
        )
      ''',
      [agentId, agentId, keep],
    );
  }
}

// ---------------------------------------------------------------------------
// Riverpod Providers
// ---------------------------------------------------------------------------

final agentEventRepositoryProvider = Provider<AgentEventRepository>((ref) {
  final db = ref.read(meowDatabaseProvider);
  return AgentEventRepository(db);
});
