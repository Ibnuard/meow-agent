import '../../core/storage/meow_config_repository.dart';
import '../permission/permission_manager.dart';
import '../../features/agents/data/agent_model.dart';
import '../../features/agents/data/agent_repository.dart';
import '../../features/modules/data/module_repository.dart';
import '../../features/modules/files/files_tools.dart';
import '../../features/providers/data/provider_repository.dart';
import 'module_plugin.dart';
import 'module_registry.dart';
import 'runtime_models.dart';
import 'runtime_module_plugins.dart';
import 'tool_permission_policy.dart';

/// Routes tool calls to their implementations.
///
/// Tool ownership now lives in self-registering [ModulePlugin]s. The router
/// only validates, enforces confirmation/permission gates, and hands dispatch
/// to the owning plugin.
class ToolRouter {
  ToolRouter({
    this.agentName = '',
    this.agentId = '',
    ModuleRepository? moduleRepository,
    this.configRepository,
    this.agentRepository,
    this.providerRepository,
    this.saveAgent,
    this.deleteAgent,
  }) : moduleRepository = moduleRepository ?? ModuleRepository();

  final ModuleRepository moduleRepository;
  final MeowConfigRepository? configRepository;
  final AgentRepository? agentRepository;
  final ProviderRepository? providerRepository;
  final Future<void> Function(AgentModel agent)? saveAgent;
  final Future<void> Function(String id)? deleteAgent;

  /// The current agent name - used by workspace-scoped tools (files module).
  String agentName;

  /// The current agent id - used by data-scoped tools (workflows, chat, etc.).
  String agentId;

  /// Attachments available for the current runtime turn.
  List<AttachedFile> attachments = const [];

  /// Whether the active provider/model declares image input support.
  bool modelSupportsVision = false;

  /// User message for the current turn, used as the default image prompt.
  String currentUserMessage = '';

  Future<String> Function({
    required AttachedFile image,
    required String prompt,
  })?
  describeImage;

  final ModuleRegistry _moduleRegistry = buildRuntimeModuleRegistry();

  /// Catalog groups derived from the plugin list. Kept as a router getter for
  /// callers/tests that need to compare the active registry with shortlisting.
  Map<String, Set<String>> get catalogGroups =>
      _moduleRegistry.buildCatalogGroups();

  late final Map<String, ToolDefinition> _registry = _moduleRegistry
      .buildRegistry();

  /// Get all registered tool names.
  List<String> get registeredTools => _registry.keys.toList();

  /// Check if a tool is registered.
  bool isRegistered(String name) => _registry.containsKey(name);

  /// Get the authoritative definition for a tool.
  /// Risk level comes from HERE, not from LLM output.
  ToolDefinition? getDefinition(String name) => _registry[name];

  /// Build formatted tool descriptions for the LLM prompt.
  /// Format: "- toolName: description. Risk: X. [Args: ...] [Requires confirmation.]"
  List<String> buildAllToolDescriptions() {
    final descriptions = <String>[];
    for (final def in _registry.values) {
      if (def.hiddenFromModel) continue;
      descriptions.add(_formatToolDescription(def));
    }
    return descriptions;
  }

  /// Build formatted descriptions for a selected subset of tools.
  ///
  /// Unknown names are ignored so callers can safely pass policy-generated
  /// sets across app versions.
  List<String> buildToolDescriptions(Set<String> names) {
    final descriptions = <String>[];
    for (final def in _registry.values) {
      if (def.hiddenFromModel) continue;
      if (names.contains(def.name)) {
        descriptions.add(_formatToolDescription(def));
      }
    }
    return descriptions;
  }

  /// Slim format for the analyzer phase: just `name: description`.
  ///
  /// The analyzer only decides intent + whether tools are needed; it does not
  /// pick arguments or evaluate risk. Schema, risk, and confirmation metadata
  /// add tokens without changing analyzer accuracy, so we drop them here.
  List<String> buildAnalyzerToolDescriptions(Set<String> names) {
    final descriptions = <String>[];
    for (final def in _registry.values) {
      if (def.hiddenFromModel) continue;
      if (names.contains(def.name)) {
        descriptions.add('- ${def.name}: ${def.description}');
      }
    }
    return descriptions;
  }

  /// Slim descriptions for every registered tool.
  List<String> buildAllAnalyzerToolDescriptions() {
    final descriptions = <String>[];
    for (final def in _registry.values) {
      if (def.hiddenFromModel) continue;
      descriptions.add('- ${def.name}: ${def.description}');
    }
    return descriptions;
  }

  String _formatToolDescription(ToolDefinition def) {
    final parts = StringBuffer();
    parts.write('- ${def.name}: ${def.description} Risk: ${def.risk}.');
    if (def.requiresConfirmation) {
      parts.write(' Requires confirmation.');
    }
    if (def.inputSchema.isNotEmpty) {
      final args = def.inputSchema.entries
          .map((e) => '${e.key} (${e.value})')
          .join(', ');
      parts.write(' Args: $args.');
    }
    return parts.toString();
  }

  /// Validate a tool call request against the registry.
  /// Returns null if valid, or an error message if invalid.
  String? validate(ToolCallRequest request) {
    if (!isRegistered(request.name)) {
      return 'Unknown tool: ${request.name}. Not registered.';
    }
    return null;
  }

  Future<ToolExecutionResult?> permissionDeniedResult(String toolName) {
    return ToolPermissionPolicy(
      moduleRepository,
      permissionManager: PermissionManager(),
    ).deniedResult(toolName);
  }

  /// Returns true when this is a `files.*` call whose target path lands
  /// outside the calling agent's own workspace. The runtime escalates such
  /// calls to a confirmation gate even when the registered risk is `safe`.
  Future<bool> requiresCrossWorkspaceConfirmation(
    ToolCallRequest request,
  ) async {
    if (!request.name.startsWith('files.')) return false;
    final files = _filesTools();
    final candidatePaths = <String>[];
    final path = request.args['path'];
    if (path is String && path.trim().isNotEmpty) {
      candidatePaths.add(path.trim());
    }
    final from = request.args['from'];
    if (from is String && from.trim().isNotEmpty) {
      candidatePaths.add(from.trim());
    }
    final to = request.args['to'];
    if (to is String && to.trim().isNotEmpty) {
      candidatePaths.add(to.trim());
    }
    for (final p in candidatePaths) {
      if (await files.isCrossWorkspacePath(p)) return true;
    }
    return false;
  }

  /// Execute a tool. Returns the result.
  /// IMPORTANT: Does NOT execute if tool requires confirmation.
  Future<ToolExecutionResult> execute(ToolCallRequest request) async {
    final definition = _registry[request.name];
    if (definition == null) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'Tool not found: ${request.name}',
      );
    }

    final denied = await permissionDeniedResult(request.name);
    if (denied != null) return denied;

    // Enforce confirmation from registry definition, not LLM.
    if (definition.requiresConfirmation) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'REQUIRES_CONFIRMATION',
      );
    }

    return _dispatch(request);
  }

  /// Force-execute a tool (user already confirmed). Bypasses confirmation.
  Future<ToolExecutionResult> forceExecute(ToolCallRequest request) async {
    final definition = _registry[request.name];
    if (definition == null) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'Tool not found: ${request.name}',
      );
    }
    final denied = await permissionDeniedResult(request.name);
    if (denied != null) return denied;
    return _dispatch(request);
  }

  Future<ToolExecutionResult> _dispatch(ToolCallRequest request) async {
    final plugin = _moduleRegistry.pluginFor(request.name);
    if (plugin == null) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'No implementation for tool: ${request.name}',
      );
    }
    return plugin.dispatch(request, _moduleContext());
  }

  /// Build the shared context handed to a [ModulePlugin] for dispatch.
  /// Reads live router fields so agent name/id stay current across turns.
  ModuleToolContext _moduleContext() => ModuleToolContext(
    agentName: agentName,
    agentId: agentId,
    moduleRepository: moduleRepository,
    configRepository: configRepository,
    agentRepository: agentRepository,
    providerRepository: providerRepository,
    saveAgent: saveAgent,
    deleteAgent: deleteAgent,
    attachments: attachments,
    modelSupportsVision: modelSupportsVision,
    currentUserMessage: currentUserMessage,
    describeImage: describeImage,
    allToolDefinitions: _registry.values,
  );

  FilesTools _filesTools() =>
      FilesTools(agentName: agentName, moduleRepository: moduleRepository);
}
