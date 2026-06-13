import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/agent_repository.dart' as core_agents;
import '../../../core/storage/core_storage_providers.dart';
import 'agent_model.dart';

/// CRUD repository for agents — backed by `meow_core.db`.
///
/// Replaces the previous meow.json + shared_preferences implementation.
/// All reads/writes go through the single SQLite source of truth. The
/// Riverpod [agentListProvider] sees changes immediately because
/// [AgentListNotifier.save] / [AgentListNotifier.delete] reload after write,
/// and [AgentListNotifier] also subscribes to the core repo's broadcast
/// stream so writes from tool plugins (`agent.create` etc.) reach the UI
/// without an explicit reload call.
class AgentRepository {
  AgentRepository({required MeowDatabase db}) : _db = db;

  final MeowDatabase _db;

  Future<List<AgentModel>> loadAll() async {
    final db = await _db.database;
    final rows = await db.query('agents', orderBy: 'created_at ASC');
    return rows.map(_fromRow).toList();
  }

  Future<AgentModel?> getById(String id) async {
    final db = await _db.database;
    final rows = await db.query('agents', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Future<AgentModel?> getByName(String name) async {
    final db = await _db.database;
    final rows = await db.query(
      'agents',
      where: 'LOWER(name) = ?',
      whereArgs: [name.trim().toLowerCase()],
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Saves an agent. Upserts: inserts if new, updates if existing.
  /// Also creates a default `agent_soul` row for new agents.
  Future<void> save(AgentModel agent) async {
    final db = await _db.database;
    final existing = await getById(agent.id);
    final now = DateTime.now().toIso8601String();

    if (existing == null) {
      // New agent — insert + seed soul row.
      await db.transaction((txn) async {
        await txn.insert('agents', {
          'id': agent.id,
          'name': agent.name,
          'provider_id': agent.providerId,
          'model': agent.model.isEmpty ? null : agent.model,
          'max_context': agent.maxContextLength,
          'auto_compact': agent.autoCompact ? 1 : 0,
          'icon_key': agent.iconKey,
          'color_key': agent.colorKey,
          'created_at': now,
          'updated_at': now,
        });
        await txn.insert('agent_soul', {
          'agent_id': agent.id,
          'updated_at': now,
        });
      });
    } else {
      // Update existing.
      await db.update(
        'agents',
        {
          'name': agent.name,
          'provider_id': agent.providerId,
          'model': agent.model.isEmpty ? null : agent.model,
          'max_context': agent.maxContextLength,
          'auto_compact': agent.autoCompact ? 1 : 0,
          'icon_key': agent.iconKey,
          'color_key': agent.colorKey,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [agent.id],
      );
    }
  }

  /// Deletes an agent. Cascade deletes soul/memory/events automatically.
  Future<void> delete(String id) async {
    final db = await _db.database;
    await db.delete('agents', where: 'id = ?', whereArgs: [id]);
  }

  static AgentModel _fromRow(Map<String, dynamic> row) => AgentModel(
    id: row['id'] as String,
    name: (row['name'] as String?) ?? '',
    providerId: (row['provider_id'] as String?) ?? '',
    model: (row['model'] as String?) ?? '',
    maxContextLength: (row['max_context'] as int?) ?? 8191,
    autoCompact: (row['auto_compact'] as int?) != 0,
    iconKey: row['icon_key'] as String?,
    colorKey: row['color_key'] as String?,
  );
}

final agentRepositoryProvider = Provider<AgentRepository>((ref) {
  return AgentRepository(db: ref.read(meowDatabaseProvider));
});

/// Reactive list of all saved agents.
///
/// Backed by SQLite (`meow_core.db`). The notifier subscribes to the core
/// repository's broadcast stream so writes from anywhere (UI, LLM tool
/// plugins, background workflows) reach UI immediately. Direct UI mutations
/// via [save] / [delete] also reload synchronously to give callers a guarantee
/// the state reflects the write before the future resolves.
class AgentListNotifier extends StateNotifier<List<AgentModel>> {
  AgentListNotifier(this._repo, core_agents.AgentRepository coreRepo)
    : super(const []) {
    _ready = _load();
    // Listen to mutations from any path (LLM tools, other widgets) so UI
    // updates without an explicit reload call.
    _coreSub = coreRepo.watchAll().listen((_) => _load());
  }

  final AgentRepository _repo;
  late final Future<void> _ready;
  StreamSubscription<List<core_agents.Agent>>? _coreSub;

  /// Resolves once the initial DB read has populated [state].
  Future<void> get ready => _ready;

  Future<void> _load() async {
    final fresh = await _repo.loadAll();
    if (mounted) state = fresh;
  }

  Future<void> save(AgentModel agent) async {
    await _repo.save(agent);
    await _load();
  }

  Future<void> delete(String id) async {
    await _repo.delete(id);
    await _load();
  }

  Future<void> reload() async {
    await _load();
  }

  @override
  void dispose() {
    _coreSub?.cancel();
    super.dispose();
  }
}

final agentListProvider =
    StateNotifierProvider<AgentListNotifier, List<AgentModel>>(
      (ref) => AgentListNotifier(
        ref.watch(agentRepositoryProvider),
        ref.watch(coreAgentRepositoryProvider),
      ),
    );

/// Convenience: has at least one agent been set up?
final hasAgentsProvider = Provider<bool>((ref) {
  return ref.watch(agentListProvider).isNotEmpty;
});
