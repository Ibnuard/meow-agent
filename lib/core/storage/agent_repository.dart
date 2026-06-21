import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'meow_database.dart';
import 'meow_database_provider.dart';

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

/// Immutable value object representing an agent.
class Agent {
  const Agent({
    required this.id,
    required this.name,
    required this.providerId,
    this.model,
    this.maxContext = 8191,
    this.autoCompact = true,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String providerId;
  final String? model;
  final int maxContext;
  final bool autoCompact;
  final DateTime createdAt;
  final DateTime updatedAt;

  Agent copyWith({
    String? name,
    String? providerId,
    String? model,
    int? maxContext,
    bool? autoCompact,
    DateTime? updatedAt,
    bool clearModel = false,
  }) {
    return Agent(
      id: id,
      name: name ?? this.name,
      providerId: providerId ?? this.providerId,
      model: clearModel ? null : (model ?? this.model),
      maxContext: maxContext ?? this.maxContext,
      autoCompact: autoCompact ?? this.autoCompact,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toRow() => {
    'id': id,
    'name': name,
    'provider_id': providerId,
    'model': model,
    'max_context': maxContext,
    'auto_compact': autoCompact ? 1 : 0,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  factory Agent.fromRow(Map<String, dynamic> row) => Agent(
    id: row['id'] as String,
    name: row['name'] as String,
    providerId: row['provider_id'] as String,
    model: row['model'] as String?,
    maxContext: (row['max_context'] as int?) ?? 8191,
    autoCompact: (row['auto_compact'] as int?) != 0,
    createdAt: DateTime.parse(row['created_at'] as String),
    updatedAt: DateTime.parse(row['updated_at'] as String),
  );
}

// ---------------------------------------------------------------------------
// Repository
// ---------------------------------------------------------------------------

/// Reactive repository for agent CRUD backed by `meow_core.db`.
///
/// Every mutation (`create`, `update`, `delete`) writes to SQLite and
/// immediately notifies all watchers via a broadcast [StreamController].
/// This guarantees that downstream consumers (UI, runtime verifier) always
/// see the freshest state — the stale-Riverpod bug is structurally impossible.
class AgentRepository {
  AgentRepository(this._db);

  final MeowDatabase _db;
  final _controller = StreamController<List<Agent>>.broadcast();

  /// Real-time stream of all agents. Emits after every mutation.
  Stream<List<Agent>> watchAll() async* {
    yield await getAll();
    yield* _controller.stream;
  }

  Future<List<Agent>> getAll() async {
    final db = await _db.database;
    final rows = await db.query('agents', orderBy: 'created_at ASC');
    return rows.map(Agent.fromRow).toList();
  }

  Future<Agent?> getById(String id) async {
    final db = await _db.database;
    final rows = await db.query('agents', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return Agent.fromRow(rows.first);
  }

  Future<Agent?> getByName(String name) async {
    final db = await _db.database;
    final rows = await db.query(
      'agents',
      where: 'LOWER(name) = ?',
      whereArgs: [name.trim().toLowerCase()],
    );
    if (rows.isEmpty) return null;
    return Agent.fromRow(rows.first);
  }

  /// Create a new agent. Returns the created entity with its generated ID.
  ///
  /// Also creates a default [agent_soul] row so identity fields are always
  /// queryable without null-checking the join.
  Future<Agent> create({
    required String name,
    required String providerId,
    String? model,
    int maxContext = 8191,
    bool autoCompact = true,
  }) async {
    final now = DateTime.now();
    final agent = Agent(
      id: const Uuid().v4(),
      name: name.trim(),
      providerId: providerId,
      model: model,
      maxContext: maxContext,
      autoCompact: autoCompact,
      createdAt: now,
      updatedAt: now,
    );
    final db = await _db.database;
    await db.transaction((txn) async {
      await txn.insert('agents', agent.toRow());
      // Seed soul row so the runtime never faces a missing-row edge case.
      await txn.insert('agent_soul', {
        'agent_id': agent.id,
        'updated_at': now.toIso8601String(),
      });
    });
    _notify();
    return agent;
  }

  /// Update an existing agent. Returns the updated entity.
  Future<Agent> update(Agent agent) async {
    final updated = agent.copyWith(updatedAt: DateTime.now());
    final db = await _db.database;
    await db.update(
      'agents',
      updated.toRow(),
      where: 'id = ?',
      whereArgs: [updated.id],
    );
    _notify();
    return updated;
  }

  /// Delete an agent by ID. Cascade deletes soul/memory/events automatically.
  Future<void> delete(String id) async {
    final db = await _db.database;
    await db.delete('agents', where: 'id = ?', whereArgs: [id]);
    _notify();
  }

  /// Refresh listeners (e.g. after bulk import).
  void notify() => _notify();

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

final agentRepositoryProvider = Provider<AgentRepository>((ref) {
  final db = ref.read(meowDatabaseProvider);
  final repo = AgentRepository(db);
  ref.onDispose(repo.dispose);
  return repo;
});

/// Reactive stream of all agents — always fresh after any mutation.
final agentStreamProvider = StreamProvider<List<Agent>>((ref) {
  return ref.read(agentRepositoryProvider).watchAll();
});

/// Synchronous snapshot for contexts that need a non-async read (e.g. UI
/// build methods, runtime engine initialization).
final agentListSyncProvider = Provider<List<Agent>>((ref) {
  return ref.watch(agentStreamProvider).value ?? [];
});
