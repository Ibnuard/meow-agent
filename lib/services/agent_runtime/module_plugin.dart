import 'runtime_models.dart';

import '../../features/agents/data/agent_model.dart';
import '../../features/agents/data/agent_repository.dart';
import '../../features/modules/data/module_repository.dart';
import '../../features/providers/data/provider_repository.dart';

/// Shared dependencies handed to a [ModulePlugin] when it dispatches a tool.
///
/// Carries everything the existing per-module tool helpers (NotesTools,
/// FilesTools, SystemTools, ...) need to construct themselves, so a plugin can
/// wrap the current handlers WITHOUT rewriting them. The [ToolRouter] builds
/// one of these per dispatch from its own live fields, so agent name/id stay
/// current across turns.
class ModuleToolContext {
  const ModuleToolContext({
    required this.agentName,
    required this.agentId,
    required this.moduleRepository,
    this.agentRepository,
    this.providerRepository,
    this.saveAgent,
    this.deleteAgent,
    this.allToolDefinitions = const [],
  });

  final String agentName;
  final String agentId;
  final ModuleRepository moduleRepository;
  final AgentRepository? agentRepository;
  final ProviderRepository? providerRepository;
  final Future<void> Function(AgentModel agent)? saveAgent;
  final Future<void> Function(String id)? deleteAgent;

  /// Every registered [ToolDefinition], for tools that introspect the catalog
  /// (e.g. `system.tools.list`). Supplied by the router.
  final Iterable<ToolDefinition> allToolDefinitions;
}

/// A self-registering feature module.
///
/// Each module owns its tool surface in ONE place: the [ToolDefinition]s it
/// exposes, how to dispatch each one, its catalog group, and English-only
/// capability hints used for language-generic shortlisting (Stage 4).
///
/// The [ModuleRegistry] collects all plugins; the [ToolRouter] derives its
/// registry + dispatch from them. Adding a module = implement this interface
/// in one file and add it to the registry's plugin list — no edits to the
/// router's registry map, dispatch switch, or the catalog's group map.
abstract class ModulePlugin {
  const ModulePlugin();

  /// Stable module id (matches the ModuleRegistry/Store id where applicable).
  String get moduleId;

  /// Catalog group key used by tool shortlisting (e.g. 'notes', 'files').
  String get catalogGroup;

  /// The tools this module owns. Names must be unique across all plugins.
  List<ToolDefinition> get toolDefinitions;

  /// English-only verbs/nouns that hint when this group is relevant. Used as a
  /// low-confidence tiebreaker for shortlisting; never a hard gate. Optional.
  List<String> get capabilityHints => const [];

  /// Tool names owned by this module (derived from [toolDefinitions]).
  Set<String> get toolNames =>
      toolDefinitions.map((d) => d.name).toSet();

  /// Whether this plugin owns [toolName].
  bool handles(String toolName) => toolNames.contains(toolName);

  /// Execute one of this module's tools. The router has already validated the
  /// tool exists, enforced confirmation/permission gates, and built [ctx].
  Future<ToolExecutionResult> dispatch(
    ToolCallRequest request,
    ModuleToolContext ctx,
  );
}
