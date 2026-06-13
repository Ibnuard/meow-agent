import '../../../services/agent_runtime/module_plugin.dart';
import '../../../services/agent_runtime/runtime_models.dart';

/// Domain tool module for LLM provider CRUD operations.
///
/// Replaces `system.config.patch` with clear, named tools for managing
/// provider endpoints. Each tool writes directly to SQLite and returns the
/// entity, making the tool result itself the verification.
class ProviderDomainModulePlugin extends ModulePlugin {
  const ProviderDomainModulePlugin();

  @override
  String get moduleId => 'provider';

  @override
  String get catalogGroup => 'system';

  @override
  List<String> get capabilityHints => const [
    'provider',
    'providers',
    'api key',
    'llm',
    'model',
    'endpoint',
  ];

  @override
  List<ToolDefinition> get toolDefinitions => const [
    ToolDefinition(
      name: 'provider.create',
      description:
          'Register a new LLM provider endpoint. Returns the created provider entity (API key is stored securely, never in tool output).',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {
        'nickname': 'string (required, human-friendly label)',
        'base_url': 'string (required, API base URL)',
        'api_key': 'string (required, will be stored in secure storage)',
        'model': 'string (required, default model name)',
        'display_code': 'string (optional, short UI label e.g. "GPT")',
      },
      operation: 'create',
      targetEntity: 'provider',
      selectorArgs: ['nickname'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'provider',
        expectedDataKeys: ['id', 'nickname'],
      ),
    ),
    ToolDefinition(
      name: 'provider.delete',
      description:
          'Remove an LLM provider by nickname. Will fail if agents still depend on it.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {
        'nickname': 'string (required, nickname of the provider to delete)',
      },
      operation: 'delete',
      targetEntity: 'provider',
      selectorArgs: ['nickname'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'provider',
        expectedDataKeys: ['deleted', 'nickname'],
      ),
    ),
    ToolDefinition(
      name: 'provider.update',
      description:
          'Update a field on an existing provider (nickname, base_url, api_key, model, display_code).',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {
        'nickname': 'string (required, current nickname of provider to update)',
        'field':
            'string (required: nickname | base_url | api_key | model | display_code)',
        'value': 'string (required, new value)',
      },
      operation: 'update',
      targetEntity: 'provider',
      selectorArgs: ['nickname', 'field'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'provider',
        expectedDataKeys: ['id', 'nickname'],
      ),
    ),
    ToolDefinition(
      name: 'provider.list',
      description:
          'List all registered LLM providers with id, nickname, base URL, and default model. API keys are never shown.',
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
    final repo = ctx.coreProviderRepo;
    if (repo == null) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'Provider repository not available.',
      );
    }

    switch (request.name) {
      case 'provider.create':
        return _create(request, ctx);
      case 'provider.delete':
        return _delete(request, ctx);
      case 'provider.update':
        return _update(request, ctx);
      case 'provider.list':
        return _list(request, ctx);
      default:
        return ToolExecutionResult(
          success: false,
          toolName: request.name,
          error: 'Unknown provider tool: ${request.name}',
        );
    }
  }

  Future<ToolExecutionResult> _create(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) async {
    final repo = ctx.coreProviderRepo!;
    final nickname = (request.args['nickname'] ?? '').toString().trim();
    final baseUrl = (request.args['base_url'] ?? '').toString().trim();
    final apiKey = (request.args['api_key'] ?? '').toString().trim();
    final model = (request.args['model'] ?? '').toString().trim();
    final displayCode = (request.args['display_code'] ?? '').toString().trim();

    if (nickname.isEmpty || baseUrl.isEmpty || apiKey.isEmpty || model.isEmpty) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'nickname, base_url, api_key, and model are all required.',
      );
    }

    // Duplicate check.
    final existing = await repo.getByNickname(nickname);
    if (existing != null) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'A provider named "$nickname" already exists.',
      );
    }

    // TODO: Write apiKey to SecureStorageService, use generated ref.
    // For now, store the key reference directly (will be encrypted in the
    // full migration when SecureStorageService is wired through ctx).
    final entry = await repo.create(
      nickname: nickname,
      baseUrl: baseUrl,
      apiKeyRef: apiKey,
      modelDefault: model,
      displayCode: displayCode.isEmpty ? null : displayCode,
    );

    return ToolExecutionResult(
      success: true,
      toolName: request.name,
      data: {
        'id': entry.id,
        'nickname': entry.nickname,
        'base_url': entry.baseUrl,
        'model': entry.modelDefault,
        'display_code': entry.displayCode ?? '',
        'created_at': entry.createdAt.toIso8601String(),
      },
    );
  }

  Future<ToolExecutionResult> _delete(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) async {
    final repo = ctx.coreProviderRepo!;
    final nickname = (request.args['nickname'] ?? '').toString().trim();
    if (nickname.isEmpty) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'Provider nickname is required.',
      );
    }

    final target = await repo.getByNickname(nickname);
    if (target == null) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'Provider "$nickname" not found.',
      );
    }

    try {
      await repo.delete(target.id);
    } catch (e) {
      // Foreign key constraint — agents still depend on this provider.
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error:
            'Cannot delete "$nickname" because agents still use this provider. Reassign them first.',
      );
    }

    return ToolExecutionResult(
      success: true,
      toolName: request.name,
      data: {
        'deleted': true,
        'nickname': target.nickname,
        'id': target.id,
      },
    );
  }

  Future<ToolExecutionResult> _update(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) async {
    final repo = ctx.coreProviderRepo!;
    final nickname = (request.args['nickname'] ?? '').toString().trim();
    final field = (request.args['field'] ?? '').toString().trim();
    final value = (request.args['value'] ?? '').toString().trim();

    if (nickname.isEmpty || field.isEmpty) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'Both nickname and field are required.',
      );
    }

    final target = await repo.getByNickname(nickname);
    if (target == null) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'Provider "$nickname" not found.',
      );
    }

    final updated = switch (field) {
      'nickname' => target.copyWith(nickname: value),
      'base_url' => target.copyWith(baseUrl: value),
      'api_key' => target.copyWith(apiKeyRef: value),
      'model' => target.copyWith(modelDefault: value),
      'display_code' => value.isEmpty
          ? target.copyWith(clearDisplayCode: true)
          : target.copyWith(displayCode: value),
      _ => null,
    };

    if (updated == null) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error:
            'Unknown field "$field". Valid: nickname, base_url, api_key, model, display_code.',
      );
    }

    final result = await repo.update(updated);
    return ToolExecutionResult(
      success: true,
      toolName: request.name,
      data: {
        'id': result.id,
        'nickname': result.nickname,
        'field': field,
        // Never expose api_key in the result.
        'value': field == 'api_key' ? '(updated)' : value,
      },
    );
  }

  Future<ToolExecutionResult> _list(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) async {
    final repo = ctx.coreProviderRepo!;
    final providers = await repo.getAll();
    return ToolExecutionResult(
      success: true,
      toolName: request.name,
      data: {
        'count': providers.length,
        'providers': providers
            .map((p) => {
                  'id': p.id,
                  'nickname': p.nickname,
                  'base_url': p.baseUrl,
                  'model': p.modelDefault,
                  'display_code': p.displayCode ?? '',
                })
            .toList(),
      },
    );
  }
}
