import '../../../core/storage/agent_repository.dart' as core_agents;
import '../../../core/storage/agent_soul_repository.dart';
import '../../../services/agent_runtime/module_plugin.dart';
import '../../../services/agent_runtime/runtime_models.dart';
import '../../../services/agent_runtime/target_reference_utils.dart';

/// Domain tool module for agent CRUD operations.
///
/// Replaces the generic `system.config.patch` approach with clear, named
/// tools that the LLM can call without reasoning about JSON paths.
/// Each tool writes directly to the core SQLite DB and returns the entity
/// it wrote — the tool result IS the verification.
class AgentDomainModulePlugin extends ModulePlugin {
  const AgentDomainModulePlugin();

  @override
  String get moduleId => 'agent';

  @override
  String get catalogGroup => 'system';

  @override
  List<String> get capabilityHints => const [
    'agent',
    'agents',
    'create agent',
    'delete agent',
    'rename agent',
    'list agents',
  ];

  @override
  List<ToolDefinition> get toolDefinitions => const [
    ToolDefinition(
      name: 'agent.create',
      description:
          'Create a new agent with a name and optional persona. Returns the created agent entity. The runtime auto-creates the agent soul record.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {
        'name': 'string (required, unique agent display name)',
        'persona': 'string (optional, personality/instructions for the agent)',
        'provider_id':
            'string (optional, provider to assign. If omitted uses the current agent provider)',
        'model': 'string (optional, model override)',
      },
      operation: 'create',
      targetEntity: 'agent',
      selectorArgs: ['name'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'agent',
        expectedDataKeys: ['id', 'name'],
      ),
    ),
    ToolDefinition(
      name: 'agent.delete',
      description:
          'Delete an existing agent by name. Cascade-removes its soul, memory, and events. Cannot delete the currently active agent.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {
        'name': 'string (required, name of the agent to delete)',
      },
      operation: 'delete',
      targetEntity: 'agent',
      selectorArgs: ['name'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'agent',
        expectedDataKeys: ['deleted', 'name'],
      ),
    ),
    ToolDefinition(
      name: 'agent.update',
      description:
          'Update a field on an existing agent. Agent fields: name, model, max_context, auto_compact, provider_id. Soul/persona fields: persona, communication_style, work_role, main_project, design_preference, preferred_language, timezone, user_name, user_nickname. Use this for ANY agent (peer or self) — for current-agent persona shortcuts, system.profile.update also works.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {
        'name': 'string (required, current name of the agent to update)',
        'field':
            'string (required: name | model | max_context | auto_compact | provider_id | persona | communication_style | work_role | main_project | design_preference | preferred_language | timezone | user_name | user_nickname)',
        'value': 'string (required, new value for the field)',
      },
      operation: 'update',
      targetEntity: 'agent',
      selectorArgs: ['name', 'field'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'agent',
        expectedDataKeys: ['id', 'name'],
      ),
    ),
    ToolDefinition(
      name: 'agent.soul.read',
      description:
          'Read the soul/persona record of any agent by name. Returns persona, communication_style, work_role, main_project, design_preference, preferred_language, timezone, user_name, user_nickname. Use this when the user asks about another agent\'s personality or configuration. Pass your own agent name to read self.',
      risk: 'safe',
      requiresConfirmation: false,
      isRetrieval: true,
      inputSchema: {
        'name':
            'string (required, agent display name; pass your own name to read self)',
      },
    ),
    ToolDefinition(
      name: 'agent.list',
      description:
          'List all registered agents with id, name, provider, model, and a short persona summary (truncated to 120 chars).',
      risk: 'safe',
      requiresConfirmation: false,
      isRetrieval: true,
    ),
  ];

  @override
  Future<ToolExecutionResult> dispatch(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) async {
    final repo = ctx.coreAgentRepo;
    if (repo == null) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'Agent repository not available.',
      );
    }

    switch (request.name) {
      case 'agent.create':
        return _create(request, ctx);
      case 'agent.delete':
        return _delete(request, ctx);
      case 'agent.update':
        return _update(request, ctx);
      case 'agent.list':
        return _list(request, ctx);
      case 'agent.soul.read':
        return _soulRead(request, ctx);
      default:
        return ToolExecutionResult(
          success: false,
          toolName: request.name,
          error: 'Unknown agent tool: ${request.name}',
        );
    }
  }

  Future<ToolExecutionResult> _create(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) async {
    final repo = ctx.coreAgentRepo!;
    final name = (request.args['name'] ?? '').toString().trim();
    if (name.isEmpty) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'Agent name is required.',
      );
    }

    // Duplicate check.
    final existing = await repo.getByName(name);
    if (existing != null) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'An agent named "$name" already exists.',
      );
    }

    // Resolve provider: explicit arg → current agent's provider.
    var providerId = (request.args['provider_id'] ?? '').toString().trim();
    if (providerId.isEmpty) {
      final currentAgent = await repo.getById(ctx.agentId);
      providerId = currentAgent?.providerId ?? '';
    }
    if (providerId.isEmpty) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'No provider available. Create a provider first.',
      );
    }

    // Resolve model: explicit arg → current agent's model → provider default.
    // Without this, the new agent shows "no model" in the UI and relies on a
    // silent fallback at chat time — confusing for users.
    var model = (request.args['model'] ?? '').toString().trim();
    if (model.isEmpty) {
      final currentAgent = await repo.getById(ctx.agentId);
      model = currentAgent?.model ?? '';
    }
    if (model.isEmpty && ctx.coreProviderRepo != null) {
      final provider = await ctx.coreProviderRepo!.getById(providerId);
      model = provider?.modelDefault ?? '';
    }

    final agent = await repo.create(
      name: name,
      providerId: providerId,
      model: model.isEmpty ? null : model,
    );

    // If persona was provided, write it to the soul.
    final persona = (request.args['persona'] ?? '').toString().trim();
    if (persona.isNotEmpty && ctx.coreSoulRepo != null) {
      await ctx.coreSoulRepo!.updateField(
        agentId: agent.id,
        field: 'persona',
        value: persona,
      );
    }

    return ToolExecutionResult(
      success: true,
      toolName: request.name,
      data: {
        'id': agent.id,
        'name': agent.name,
        'provider_id': agent.providerId,
        'model': agent.model ?? '',
        'created_at': agent.createdAt.toIso8601String(),
      },
    );
  }

  Future<ToolExecutionResult> _delete(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) async {
    final repo = ctx.coreAgentRepo!;
    final name = (request.args['name'] ?? '').toString().trim();
    if (name.isEmpty) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'Agent name is required.',
      );
    }

    final target = await repo.getByName(name);
    if (target == null) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'Agent "$name" not found.',
      );
    }

    // Cannot delete self.
    if (target.id == ctx.agentId) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'Cannot delete the currently active agent.',
      );
    }

    await repo.delete(target.id);
    return ToolExecutionResult(
      success: true,
      toolName: request.name,
      data: {
        'deleted': true,
        'name': target.name,
        'id': target.id,
      },
    );
  }

  Future<ToolExecutionResult> _update(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) async {
    final repo = ctx.coreAgentRepo!;
    final name = (request.args['name'] ?? '').toString().trim();
    final field = (request.args['field'] ?? '').toString().trim();
    final value = (request.args['value'] ?? '').toString().trim();

    if (name.isEmpty || field.isEmpty) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'Both name and field are required.',
      );
    }

    final target = await repo.getByName(name);
    if (target == null) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'Agent "$name" not found.',
      );
    }

    // Soul/persona fields route through AgentSoulRepository.
    final soulFields = AgentSoulRepository.profileFields.toSet();
    // 'name' is ambiguous — it means agent-rename (registry table), not
    // user_name (soul). Callers use 'user_name' for the soul field.
    soulFields.remove('name');
    soulFields.remove('nickname');

    if (soulFields.contains(field) ||
        field == 'user_name' ||
        field == 'user_nickname') {
      final soulRepo = ctx.coreSoulRepo;
      if (soulRepo == null) {
        return ToolExecutionResult(
          success: false,
          toolName: request.name,
          error: 'Soul repository is not available.',
        );
      }
      await soulRepo.updateField(
        agentId: target.id,
        field: field,
        value: value,
      );
      return ToolExecutionResult(
        success: true,
        toolName: request.name,
        data: {
          'id': target.id,
          'name': target.name,
          'field': field,
          'value': value,
          'scope': 'soul',
        },
      );
    }

    // Agent-table fields.
    final updated = switch (field) {
      'name' => target.copyWith(name: value),
      'model' => value.isEmpty
          ? target.copyWith(clearModel: true)
          : target.copyWith(model: value),
      'max_context' => target.copyWith(
        maxContext: int.tryParse(value) ?? target.maxContext,
      ),
      'auto_compact' => target.copyWith(
        autoCompact: value == 'true' || value == '1',
      ),
      'provider_id' => target.copyWith(providerId: value),
      _ => null,
    };

    if (updated == null) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error:
            'Unknown field "$field". Valid agent fields: name, model, max_context, auto_compact, provider_id. '
            'Valid soul fields: persona, communication_style, work_role, main_project, design_preference, '
            'preferred_language, timezone, user_name, user_nickname.',
      );
    }

    final result = await repo.update(updated);
    return ToolExecutionResult(
      success: true,
      toolName: request.name,
      data: {
        'id': result.id,
        'name': result.name,
        'field': field,
        'value': value,
        'scope': 'agent',
      },
    );
  }

  Future<ToolExecutionResult> _soulRead(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) async {
    final repo = ctx.coreAgentRepo!;
    final soulRepo = ctx.coreSoulRepo;
    if (soulRepo == null) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'Soul repository is not available.',
      );
    }

    final requestedName = (request.args['name'] ?? '').toString().trim();

    // Self-resolution guard.
    //
    // "What is your personality?" maps to agent.soul.read(name: "<self>"), but
    // the model can supply a stale peer name leaked from a prior turn, an empty
    // value, or the agent's UUID (when no display name was set). In all of
    // those cases we must read the CURRENT agent's soul unless the user clearly
    // named a different existing agent in their literal message. This keeps an
    // identity question pinned to the active agent instead of echoing a peer.
    final selfId = ctx.agentId.trim();
    final selfName = ctx.agentName.trim();
    final userNamedThisAgent = requestedName.isNotEmpty &&
        TargetReferenceUtils.messageMentionsExactAgent(
          ctx.currentUserMessage,
          requestedName,
        );
    final looksLikeSelfReference = requestedName.isEmpty ||
        TargetReferenceUtils.isCurrentAgentReference(requestedName) ||
        (selfId.isNotEmpty && requestedName == selfId) ||
        (selfName.isNotEmpty &&
            requestedName.toLowerCase() == selfName.toLowerCase());

    // Resolve the target agent. Prefer an explicit, user-named peer; otherwise
    // fall back to the active agent by id.
    final agent = await _resolveSoulTarget(
      repo: repo,
      requestedName: requestedName,
      selfId: selfId,
      userNamedThisAgent: userNamedThisAgent,
      looksLikeSelfReference: looksLikeSelfReference,
    );

    if (agent == null) {
      final label = requestedName.isEmpty ? selfName : requestedName;
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: label.isEmpty
            ? 'Agent not found.'
            : 'Agent "$label" not found.',
      );
    }

    final soul = await soulRepo.get(agent.id);
    return ToolExecutionResult(
      success: true,
      toolName: request.name,
      data: {
        'agent_id': agent.id,
        'agent_name': agent.name,
        'is_self': agent.id == selfId,
        'user_name': soul?.userName ?? '',
        'user_nickname': soul?.userNickname ?? '',
        'persona': soul?.persona ?? '',
        'communication_style': soul?.communicationStyle ?? '',
        'work_role': soul?.workRole ?? '',
        'main_project': soul?.mainProject ?? '',
        'design_preference': soul?.designPreference ?? '',
        'preferred_language': soul?.preferredLanguage ?? '',
        'timezone': soul?.timezone ?? '',
      },
    );
  }

  /// Resolve which agent's soul to read, with self as the safe default.
  ///
  /// See [_soulRead] for the rationale. Extracted so the conditional cascade
  /// keeps type inference on the repository's `Agent` return type.
  Future<core_agents.Agent?> _resolveSoulTarget({
    required core_agents.AgentRepository repo,
    required String requestedName,
    required String selfId,
    required bool userNamedThisAgent,
    required bool looksLikeSelfReference,
  }) async {
    if (userNamedThisAgent && !looksLikeSelfReference) {
      return repo.getByName(requestedName);
    }
    if (looksLikeSelfReference && selfId.isNotEmpty) {
      return repo.getById(selfId);
    }
    if (requestedName.isNotEmpty) {
      // A concrete name the user did not echo this turn — try it, but fall
      // back to self rather than failing a self-ish identity question.
      return await repo.getByName(requestedName) ??
          (selfId.isNotEmpty ? await repo.getById(selfId) : null);
    }
    if (selfId.isNotEmpty) return repo.getById(selfId);
    return null;
  }

  Future<ToolExecutionResult> _list(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) async {
    final repo = ctx.coreAgentRepo!;
    final soulRepo = ctx.coreSoulRepo;
    final agents = await repo.getAll();

    final entries = <Map<String, dynamic>>[];
    for (final a in agents) {
      final soul = soulRepo != null ? await soulRepo.get(a.id) : null;
      final persona = soul?.persona ?? '';
      entries.add({
        'id': a.id,
        'name': a.name,
        'provider_id': a.providerId,
        'model': a.model ?? '',
        'persona': persona.length > 120
            ? '${persona.substring(0, 117)}...'
            : persona,
        'communication_style': soul?.communicationStyle ?? '',
        'work_role': soul?.workRole ?? '',
        // POV marker: lets the reviewer / direct-response LLM tell itself
        // apart from peer agents when answering "what other agents exist /
        // besides you" questions. Without this, the LLM sees its own row in
        // the list and mentions itself as a "different agent".
        'is_self': a.id == ctx.agentId,
      });
    }

    // Resolve self name once. Tolerant of empty registry / missing self.
    String selfName = '';
    for (final a in agents) {
      if (a.id == ctx.agentId) {
        selfName = a.name;
        break;
      }
    }

    return ToolExecutionResult(
      success: true,
      toolName: request.name,
      data: {
        'count': agents.length,
        'self_id': ctx.agentId,
        'self_name': selfName,
        'agents': entries,
        // Inline POV note so the LLM never has to infer self-vs-other from
        // the entries alone. The reviewer rules already enforce first-person
        // POV; this just makes the data side unambiguous.
        'pov_note':
            'You ARE the entry where is_self=true. When the user asks about '
            'OTHER agents or agents BESIDES you, list only entries where '
            'is_self=false. When asked about your own persona, use the '
            'is_self=true entry and speak in first person ("I am ...").',
      },
    );
  }
}
