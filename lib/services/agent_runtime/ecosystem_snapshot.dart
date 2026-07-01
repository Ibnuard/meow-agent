import '../../features/agents/data/agent_model.dart';
import '../../features/modules/data/module_model.dart';
import '../../features/modules/data/module_repository.dart';
import '../../features/modules/workflows/workflow_model.dart';
import '../../features/modules/workflows/workflow_repository.dart';
import '../../features/providers/data/provider_config.dart';
import '../../features/providers/data/provider_repository.dart';

/// Read-only world model the Reflector consults before deciding strategy.
///
/// Built once per runtime turn from the existing repos. No new I/O — the data
/// is already cached upstream. The structure intentionally inverts the natural
/// foreign-key direction (e.g. `agent.usedByWorkflows` instead of forcing the
/// reflector to scan all workflows itself) so the compact prompt block is
/// enough on its own.
class EcosystemSnapshot {
  EcosystemSnapshot({
    required this.agents,
    required this.workflows,
    required this.providers,
    required this.modules,
    required this.builtAt,
  });

  final List<EcosystemAgent> agents;
  final List<EcosystemWorkflow> workflows;
  final List<EcosystemProvider> providers;
  final List<EcosystemModule> modules;
  final DateTime builtAt;

  bool get isEmpty =>
      agents.isEmpty &&
      workflows.isEmpty &&
      providers.isEmpty &&
      modules.isEmpty;

  /// Heuristic: should the reflector receive the snapshot?
  /// True if any cross-entity relationship exists (workflows referencing
  /// agents) OR if there are 2+ agents/providers (potential rename/delete
  /// impact). Providers included so provider-management tasks (rename,
  /// switch, list) can see the available endpoints even on single-agent
  /// setups. Falls through to false for trivial single-agent, single-
  /// provider, all-modules-enabled setups so we don't burn tokens.
  bool get isRelevantForReflection =>
      agents.length >= 2 ||
      providers.length >= 2 ||
      workflows.isNotEmpty ||
      modules.any((m) => !m.enabled);

  /// Compact prompt-friendly format. Targets <300 tokens.
  String toCompactString() {
    final buf = StringBuffer()
      ..writeln('ECOSYSTEM SNAPSHOT (built ${_hhmm(builtAt)} local):');

    if (agents.isEmpty) {
      buf.writeln('Agents: none');
    } else {
      buf.writeln('Agents (${agents.length}):');
      for (final a in agents) {
        final used = a.usedByWorkflows.isEmpty
            ? ''
            : ' · used_by:[${a.usedByWorkflows.join(", ")}]';
        buf.writeln(
          '  - ${a.name} [id=${a.id}] · provider:${a.providerNickname}$used',
        );
      }
    }

    if (workflows.isNotEmpty) {
      buf.writeln('Workflows (${workflows.length}):');
      for (final w in workflows) {
        final stepInfo = w.stepAgentIds.isEmpty
            ? ''
            : ' · step_agents:[${w.stepAgentIds.join(", ")}]';
        buf.writeln(
          '  - ${w.title} [id=${w.id}] · agent:${w.agentName} · trigger:${w.triggerSummary} · enabled:${w.enabled}$stepInfo',
        );
      }
    }

    if (providers.isNotEmpty) {
      buf.writeln(
        'Providers (${providers.length}): ${providers.map((p) => p.nickname).join(", ")}',
      );
    }

    if (modules.isNotEmpty) {
      final enabled = modules.where((m) => m.enabled).length;
      buf.writeln(
        'Modules ($enabled/${modules.length} enabled): '
        '${modules.map((m) => m.enabled ? m.id : "${m.id}(off)").join(", ")}',
      );
    }

    return buf.toString().trim();
  }

  static String _hhmm(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

class EcosystemAgent {
  const EcosystemAgent({
    required this.id,
    required this.name,
    required this.providerNickname,
    this.usedByWorkflows = const [],
  });

  final String id;
  final String name;
  final String providerNickname;

  /// Workflow titles that reference this agent. Used by the reflector to
  /// detect impact when the user asks to delete or rename the agent.
  final List<String> usedByWorkflows;
}

class EcosystemWorkflow {
  const EcosystemWorkflow({
    required this.id,
    required this.title,
    required this.agentId,
    required this.agentName,
    required this.triggerSummary,
    required this.enabled,
    this.stepAgentIds = const [],
  });

  final String id;
  final String title;
  final String agentId;
  final String agentName;
  final String triggerSummary;
  final bool enabled;

  /// Agent IDs referenced inside multi-step workflow steps (in addition to
  /// the primary [agentId]). Used by impact analysis to detect cross-references
  /// hidden inside chained workflows so deleting that agent surfaces a warning.
  final List<String> stepAgentIds;
}

class EcosystemProvider {
  const EcosystemProvider({required this.id, required this.nickname});

  final String id;
  final String nickname;
}

class EcosystemModule {
  const EcosystemModule({required this.id, required this.enabled});

  final String id;
  final bool enabled;
}

/// Builds an [EcosystemSnapshot] from the existing repos held by the runtime.
///
/// Pure read; never mutates the source data. Intentionally permissive about
/// failures — if any repo throws, the offending section is skipped and the
/// snapshot is still returned so the reflector can keep working with what
/// it has.
class EcosystemSnapshotBuilder {
  EcosystemSnapshotBuilder({
    required this.moduleRepository,
    required this.providerRepository,
    required this.workflowRepository,
  });

  final ModuleRepository moduleRepository;
  final ProviderRepository providerRepository;
  final WorkflowRepository workflowRepository;

  Future<EcosystemSnapshot> build({required List<AgentModel> agents}) async {
    final modules = await _safeLoadModules();
    final providers = await _safeLoadProviders();
    final workflows = await _safeLoadWorkflows();

    final providerById = <String, ProviderConfig>{
      for (final p in providers) p.id: p,
    };
    final agentById = <String, AgentModel>{for (final a in agents) a.id: a};

    final workflowEntries = <EcosystemWorkflow>[
      for (final w in workflows)
        EcosystemWorkflow(
          id: w.id,
          title: w.title,
          agentId: w.agentId,
          agentName: agentById[w.agentId]?.name ?? '(deleted agent)',
          triggerSummary: w.trigger.summary,
          enabled: w.enabled,
          stepAgentIds: [
            if (w.isChained)
              for (final step in w.steps)
                if (step.agentId != null) step.agentId!,
          ],
        ),
    ];

    // Pre-compute reverse index: agent.id -> workflow titles using it.
    // Covers BOTH the primary workflow agent AND agents referenced inside
    // chained multi-step workflow steps (user's test-2 scenario).
    final usedByByAgent = <String, List<String>>{};
    for (final w in workflowEntries) {
      usedByByAgent.putIfAbsent(w.agentId, () => []).add(w.title);
      for (final stepAgentId in w.stepAgentIds) {
        if (stepAgentId != w.agentId) {
          usedByByAgent
              .putIfAbsent(stepAgentId, () => [])
              .add('${w.title} (step)');
        }
      }
    }

    final agentEntries = <EcosystemAgent>[
      for (final a in agents)
        EcosystemAgent(
          id: a.id,
          name: a.name,
          providerNickname: providerById[a.providerId]?.nickname ?? '(unknown)',
          usedByWorkflows: usedByByAgent[a.id] ?? const [],
        ),
    ];

    final providerEntries = [
      for (final p in providers)
        EcosystemProvider(id: p.id, nickname: p.nickname),
    ];

    final moduleEntries = [
      for (final m in modules) EcosystemModule(id: m.id, enabled: m.enabled),
    ];

    return EcosystemSnapshot(
      agents: agentEntries,
      workflows: workflowEntries,
      providers: providerEntries,
      modules: moduleEntries,
      builtAt: DateTime.now(),
    );
  }

  Future<List<ModuleModel>> _safeLoadModules() async {
    try {
      return await moduleRepository.getInstalled();
    } catch (_) {
      return const [];
    }
  }

  Future<List<ProviderConfig>> _safeLoadProviders() async {
    try {
      return await providerRepository.loadAll();
    } catch (_) {
      return const [];
    }
  }

  Future<List<WorkflowModel>> _safeLoadWorkflows() async {
    try {
      return await workflowRepository.list();
    } catch (_) {
      return const [];
    }
  }
}
