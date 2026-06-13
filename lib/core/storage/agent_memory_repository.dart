import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'agent_soul_repository.dart' show AgentSoulRepository;
import 'meow_database.dart';
import 'meow_database_provider.dart';

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

/// Long-term memory entry. Replaces individual MEMORY.md lines.
class AgentMemoryEntry {
  const AgentMemoryEntry({
    required this.id,
    required this.agentId,
    required this.category,
    required this.content,
    required this.createdAt,
  });

  final int id;
  final String agentId;
  final String category;
  final String content;
  final DateTime createdAt;

  factory AgentMemoryEntry.fromRow(Map<String, dynamic> row) =>
      AgentMemoryEntry(
        id: row['id'] as int,
        agentId: row['agent_id'] as String,
        category: row['category'] as String,
        content: row['content'] as String,
        createdAt: DateTime.parse(row['created_at'] as String),
      );
}

// ---------------------------------------------------------------------------
// Repository
// ---------------------------------------------------------------------------

/// Append-only memory store per agent. Replaces MEMORY.md.
///
/// Designed for fast retrieval — recent N, by category, or LIKE search are
/// all single-table queries on indexed columns. No markdown parsing.
class AgentMemoryRepository {
  AgentMemoryRepository(this._db);

  final MeowDatabase _db;
  final _byAgentControllers = <String, StreamController<List<AgentMemoryEntry>>>{};

  Stream<List<AgentMemoryEntry>> watch(
    String agentId, {
    int limit = 100,
  }) async* {
    yield await recent(agentId, limit: limit);
    final ctrl = _byAgentControllers.putIfAbsent(
      agentId,
      () => StreamController<List<AgentMemoryEntry>>.broadcast(),
    );
    yield* ctrl.stream;
  }

  /// Most recent [limit] entries for an agent, newest first.
  Future<List<AgentMemoryEntry>> recent(
    String agentId, {
    int limit = 100,
  }) async {
    final db = await _db.database;
    final rows = await db.query(
      'agent_memory',
      where: 'agent_id = ?',
      whereArgs: [agentId],
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(AgentMemoryEntry.fromRow).toList();
  }

  /// Filter by category (fact | preference | bookmark | session).
  Future<List<AgentMemoryEntry>> byCategory(
    String agentId,
    String category, {
    int limit = 100,
  }) async {
    final db = await _db.database;
    final rows = await db.query(
      'agent_memory',
      where: 'agent_id = ? AND category = ?',
      whereArgs: [agentId, category],
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(AgentMemoryEntry.fromRow).toList();
  }

  /// Substring search over content. Case-insensitive.
  Future<List<AgentMemoryEntry>> search(
    String agentId,
    String query, {
    int limit = 50,
  }) async {
    if (query.trim().isEmpty) return const [];
    final db = await _db.database;
    final rows = await db.query(
      'agent_memory',
      where: 'agent_id = ? AND LOWER(content) LIKE ?',
      whereArgs: [agentId, '%${query.trim().toLowerCase()}%'],
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(AgentMemoryEntry.fromRow).toList();
  }

  /// Append a new entry. Returns the persisted entity with assigned id.
  Future<AgentMemoryEntry> append({
    required String agentId,
    required String content,
    String category = 'fact',
  }) async {
    final cat = AgentSoulRepository.memoryCategories.contains(category)
        ? category
        : 'fact';
    final now = DateTime.now();
    final db = await _db.database;
    final id = await db.insert('agent_memory', {
      'agent_id': agentId,
      'category': cat,
      'content': content,
      'created_at': now.toIso8601String(),
    });
    final entry = AgentMemoryEntry(
      id: id,
      agentId: agentId,
      category: cat,
      content: content,
      createdAt: now,
    );
    _notify(agentId);
    return entry;
  }

  Future<void> delete(int id, {required String agentId}) async {
    final db = await _db.database;
    await db.delete(
      'agent_memory',
      where: 'id = ? AND agent_id = ?',
      whereArgs: [id, agentId],
    );
    _notify(agentId);
  }

  Future<void> clearAgent(String agentId) async {
    final db = await _db.database;
    await db.delete(
      'agent_memory',
      where: 'agent_id = ?',
      whereArgs: [agentId],
    );
    _notify(agentId);
  }

  void _notify(String agentId) async {
    final ctrl = _byAgentControllers[agentId];
    if (ctrl == null) return;
    ctrl.add(await recent(agentId));
  }

  void dispose() {
    for (final c in _byAgentControllers.values) {
      c.close();
    }
    _byAgentControllers.clear();
  }
}

// ---------------------------------------------------------------------------
// Riverpod Providers
// ---------------------------------------------------------------------------

final agentMemoryRepositoryProvider = Provider<AgentMemoryRepository>((ref) {
  final db = ref.read(meowDatabaseProvider);
  final repo = AgentMemoryRepository(db);
  ref.onDispose(repo.dispose);
  return repo;
});

final agentMemoryStreamProvider =
    StreamProvider.family<List<AgentMemoryEntry>, String>((ref, agentId) {
  return ref.read(agentMemoryRepositoryProvider).watch(agentId);
});
