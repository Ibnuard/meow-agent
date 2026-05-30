part of 'system_tools.dart';

/// Export/import execute methods extracted from [SystemTools].
extension SystemToolsExport on SystemTools {
  // ─── system.export_all ─────────────────────────────────────────────────────

  /// Returns a JSON-serializable snapshot of agents, providers (no secrets),
  /// and module settings. The runtime caller can write this to a file.
  Future<ToolExecutionResult> executeExportAll() async {
    try {
      final agents = loadAgents();
      final providers = await loadProviders();
      final modules = await moduleRepository.getInstalled();
      final snapshot = {
        'version': 1,
        'exportedAt': DateTime.now().toIso8601String(),
        'agents': agents.map((a) => a.toJson()).toList(),
        'providers': providers.map((p) => p.toPublicJson()).toList(),
        'modules': modules.map((m) => m.toJson()).toList(),
      };
      return ToolExecutionResult(
        success: true,
        toolName: 'system.export_all',
        data: {
          'snapshot': snapshot,
          'counts': {
            'agents': agents.length,
            'providers': providers.length,
            'modules': modules.length,
          },
          'note':
              'Provider API keys are NOT included. Re-enter them after import.',
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'system.export_all',
        error: e.toString(),
      );
    }
  }

  // ─── system.import ─────────────────────────────────────────────────────────

  /// Restore from a snapshot produced by [executeExportAll]. Modes:
  /// - merge (default): adds missing agents and modules; existing entries are
  ///   left alone.
  /// - replace: clears existing agents/modules first.
  Future<ToolExecutionResult> executeImport(Map<String, dynamic> args) async {
    try {
      final snapshot = args['snapshot'];
      if (snapshot is! Map) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'system.import',
          error: 'snapshot is required and must be an object.',
        );
      }
      final mode = ((args['mode'] as String?) ?? 'merge').toLowerCase();
      if (mode != 'merge' && mode != 'replace') {
        return const ToolExecutionResult(
          success: false,
          toolName: 'system.import',
          error: 'mode must be "merge" or "replace".',
        );
      }

      final stats = <String, int>{
        'agentsAdded': 0,
        'modulesUpdated': 0,
        'modulesAdded': 0,
      };

      // Agents.
      final repo = agentRepository;
      final save = saveAgent;
      if ((repo != null || save != null) && snapshot['agents'] is List) {
        final existing = loadAgents();
        final existingNames = existing.map((a) => a.name.toLowerCase()).toSet();
        if (mode == 'replace') {
          for (final a in existing) {
            if (a.id == agentId) continue; // Cannot delete self.
            if (deleteAgent != null) {
              await deleteAgent!(a.id);
            } else {
              await repo!.delete(a.id);
            }
          }
          existingNames.clear();
        }
        for (final raw in (snapshot['agents'] as List)) {
          if (raw is! Map) continue;
          final m = Map<String, dynamic>.from(raw);
          final agent = AgentModel.fromJson(m);
          if (mode == 'merge' &&
              existingNames.contains(agent.name.toLowerCase())) {
            continue;
          }
          if (save != null) {
            await save(agent);
          } else {
            await repo!.save(agent);
          }
          stats['agentsAdded'] = (stats['agentsAdded'] ?? 0) + 1;
        }
      }

      // Modules.
      if (snapshot['modules'] is List) {
        final existingModules = await moduleRepository.getInstalled();
        final existingIds = existingModules.map((m) => m.id).toSet();
        for (final raw in (snapshot['modules'] as List)) {
          if (raw is! Map) continue;
          final m = ModuleModel.fromJson(Map<String, dynamic>.from(raw));
          if (existingIds.contains(m.id)) {
            await moduleRepository.update(m);
            stats['modulesUpdated'] = (stats['modulesUpdated'] ?? 0) + 1;
          } else {
            await moduleRepository.install(m);
            stats['modulesAdded'] = (stats['modulesAdded'] ?? 0) + 1;
          }
        }
      }

      return ToolExecutionResult(
        success: true,
        toolName: 'system.import',
        data: {
          'mode': mode,
          'stats': stats,
          'note':
              'Providers must be re-added manually because API keys are not in snapshots.',
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'system.import',
        error: e.toString(),
      );
    }
  }
}