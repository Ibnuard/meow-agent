import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/local_storage_service.dart';
import 'agent_model.dart';
import 'workspace_service.dart';

/// CRUD repository for agents.
class AgentRepository {
  AgentRepository({
    required LocalStorageService local,
    required WorkspaceService workspace,
  })  : _local = local,
        _workspace = workspace;

  static const _kAgents = 'meow.agents_json';

  final LocalStorageService _local;
  final WorkspaceService _workspace;

  List<AgentModel> loadAll() {
    final raw = _local.readString(_kAgents);
    if (raw == null) return [];
    return AgentModel.decodeList(raw);
  }

  /// Saves an agent. If it's a new agent (not yet in the list), also
  /// creates its workspace folder with template files.
  Future<void> save(AgentModel agent) async {
    final all = loadAll();
    final idx = all.indexWhere((a) => a.id == agent.id);
    final isNew = idx < 0;

    if (isNew) {
      all.add(agent);
    } else {
      all[idx] = agent;
    }
    await _local.writeString(_kAgents, AgentModel.encodeList(all));

    // Create workspace for new agents.
    if (isNew) {
      await _workspace.createWorkspace(
        agentId: agent.id,
        agentName: agent.name,
      );
    }
  }

  /// Deletes an agent and its workspace folder.
  Future<void> delete(String id) async {
    final all = loadAll();
    all.removeWhere((a) => a.id == id);
    await _local.writeString(_kAgents, AgentModel.encodeList(all));
    await _workspace.deleteWorkspace(id);
  }

  /// Ensures every saved agent has a workspace folder.
  /// Creates missing workspaces for agents that existed before the
  /// workspace system was introduced.
  Future<void> syncWorkspaces() async {
    final all = loadAll();
    for (final agent in all) {
      final path = await _workspace.getWorkspacePath(agent.id);
      if (path == null) {
        await _workspace.createWorkspace(
          agentId: agent.id,
          agentName: agent.name,
        );
      }
    }
  }
}

final agentRepositoryProvider = Provider<AgentRepository>((ref) {
  return AgentRepository(
    local: ref.watch(localStorageProvider),
    workspace: ref.watch(workspaceServiceProvider),
  );
});

/// Reactive list of all saved agents.
class AgentListNotifier extends StateNotifier<List<AgentModel>> {
  AgentListNotifier(this._repo) : super(_repo.loadAll()) {
    // Sync workspaces for any existing agents missing their folder.
    _repo.syncWorkspaces();
  }

  final AgentRepository _repo;

  Future<void> save(AgentModel agent) async {
    await _repo.save(agent);
    state = _repo.loadAll();
  }

  Future<void> delete(String id) async {
    await _repo.delete(id);
    state = _repo.loadAll();
  }

  void reload() {
    state = _repo.loadAll();
  }
}

final agentListProvider =
    StateNotifierProvider<AgentListNotifier, List<AgentModel>>(
  (ref) => AgentListNotifier(ref.watch(agentRepositoryProvider)),
);

/// Convenience: has at least one agent been set up?
final hasAgentsProvider = Provider<bool>((ref) {
  return ref.watch(agentListProvider).isNotEmpty;
});
