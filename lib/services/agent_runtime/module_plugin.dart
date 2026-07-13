import 'runtime_models.dart';

import '../../core/storage/agent_repository.dart' as core_agents;
import '../../core/storage/agent_memory_repository.dart' as core_memory;
import '../../core/storage/agent_skills_repository.dart' as core_skills;
import '../../core/storage/agent_soul_repository.dart' as core_soul;
import '../../core/storage/app_settings_repository.dart';
import '../../core/storage/module_entry_repository.dart';
import '../../core/storage/provider_repository.dart' as core_providers;
import '../../core/storage/secure_storage_service.dart';
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
    this.appSettings,
    this.moduleEntries,
    this.agentRepository,
    this.providerRepository,
    this.saveAgent,
    this.deleteAgent,
    this.attachments = const [],
    this.modelSupportsVision = false,
    this.currentUserMessage = '',
    this.currentSessionId = '',
    this.describeImage,
    this.allToolDefinitions = const [],
    this.coreAgentRepo,
    this.coreProviderRepo,
    this.coreSoulRepo,
    this.coreMemoryRepo,
    this.coreSkillsRepo,
    this.secureStorage,
  });

  final String agentName;
  final String agentId;
  final ModuleRepository moduleRepository;
  final AppSettingsRepository? appSettings;
  final ModuleEntryRepository? moduleEntries;
  final AgentRepository? agentRepository;
  final ProviderRepository? providerRepository;
  final Future<void> Function(AgentModel agent)? saveAgent;
  final Future<void> Function(String id)? deleteAgent;
  final List<AttachedFile> attachments;
  final bool modelSupportsVision;
  final String currentUserMessage;
  final String currentSessionId;
  final Future<String> Function({
    required AttachedFile image,
    required String prompt,
  })?
  describeImage;

  /// Every registered [ToolDefinition], for tools that introspect the catalog
  /// (e.g. `system.tools.list`). Supplied by the router.
  final Iterable<ToolDefinition> allToolDefinitions;

  // ---------------------------------------------------------------------------
  // Core/storage repositories (Phase 7 architecture).
  //
  // Domain tool plugins (agent.*, provider.*) read/write through these
  // directly to SQLite. All fields are optional so test-constructed contexts
  // can omit repos they don't need.
  // ---------------------------------------------------------------------------

  final core_agents.AgentRepository? coreAgentRepo;
  final core_providers.ProviderEntryRepository? coreProviderRepo;
  final core_soul.AgentSoulRepository? coreSoulRepo;
  final core_memory.AgentMemoryRepository? coreMemoryRepo;

  /// Skills repository for the skills module plugin (skills.* tools).
  final core_skills.AgentSkillsRepository? coreSkillsRepo;

  /// Secure storage for sensitive values (e.g. provider API keys). Domain
  /// plugins that persist secrets (provider.*) write the raw key here keyed by
  /// `meow.provider_key.<id>`, mirroring the UI [ProviderRepository] scheme, so
  /// the SQLite `api_key_ref` column never holds a plaintext key.
  final SecureStorageService? secureStorage;
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
  Set<String> get toolNames => toolDefinitions.map((d) => d.name).toSet();

  /// Whether this plugin owns [toolName].
  bool handles(String toolName) => toolNames.contains(toolName);

  /// Execute one of this module's tools. The router has already validated the
  /// tool exists, enforced confirmation/permission gates, and built [ctx].
  Future<ToolExecutionResult> dispatch(
    ToolCallRequest request,
    ModuleToolContext ctx,
  );
}
