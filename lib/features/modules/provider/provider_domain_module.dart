import '../../../services/agent_runtime/module_plugin.dart';
import '../../../services/agent_runtime/runtime_models.dart';

/// Domain tool module for LLM provider CRUD operations.
///
/// Replaces `system.config.patch` with clear, named tools for managing
/// provider endpoints. Each tool writes directly to SQLite and returns the
/// entity, making the tool result itself the verification.
class ProviderDomainModulePlugin extends ModulePlugin {
  const ProviderDomainModulePlugin();

  /// Secure-storage key prefix for provider API keys. MUST match the UI
  /// [ProviderRepository._kApiKeyPrefix] so both paths resolve the same key.
  static const _kApiKeyPrefix = 'meow.provider_key.';

  /// Placeholder ref written to the DB before the real id-keyed ref is patched
  /// in. Never used to look up a key (the row is updated immediately after).
  static const _pendingRef = 'pending_secure_ref';

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

    // Persist the raw key in secure storage and store only an opaque ref in
    // SQLite — mirrors the UI ProviderRepository scheme so the runtime (which
    // reads keys via secure storage) can resolve a tool-created provider, and
    // the key never lands in plaintext in the DB.
    //
    // The id is generated by repo.create, so we create first (with a temporary
    // placeholder ref), then write the key and patch the ref to the canonical
    // `meow.provider_key.<id>` form.
    final entry = await repo.create(
      nickname: nickname,
      baseUrl: baseUrl,
      apiKeyRef: _pendingRef,
      modelDefault: model,
      displayCode: displayCode.isEmpty ? null : displayCode,
    );

    final secure = ctx.secureStorage;
    final keyRef = '$_kApiKeyPrefix${entry.id}';
    if (secure != null) {
      await secure.write(keyRef, apiKey);
      await repo.update(entry.copyWith(apiKeyRef: keyRef));
    } else {
      // No secure storage available (e.g. a test context): fail loudly rather
      // than silently persisting a plaintext key.
      await repo.delete(entry.id);
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'Secure storage unavailable; cannot store the API key safely.',
      );
    }

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

    // Best-effort cleanup of the secured API key.
    await ctx.secureStorage?.delete('$_kApiKeyPrefix${target.id}');

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

    // The api_key field is special: the raw value goes to secure storage, not
    // the DB. The ref column stays as the canonical id-keyed ref.
    if (field == 'api_key') {
      if (value.isEmpty) {
        return ToolExecutionResult(
          success: false,
          toolName: request.name,
          error: 'api_key value cannot be empty.',
        );
      }
      final secure = ctx.secureStorage;
      if (secure == null) {
        return ToolExecutionResult(
          success: false,
          toolName: request.name,
          error: 'Secure storage unavailable; cannot update the API key safely.',
        );
      }
      final keyRef = '$_kApiKeyPrefix${target.id}';
      await secure.write(keyRef, value);
      // Ensure the ref column points at the canonical key (older rows may have
      // held a plaintext key here before this fix).
      final result = await repo.update(target.copyWith(apiKeyRef: keyRef));
      return ToolExecutionResult(
        success: true,
        toolName: request.name,
        data: {
          'id': result.id,
          'nickname': result.nickname,
          'field': field,
          'value': '(updated)',
        },
      );
    }

    final updated = switch (field) {
      'nickname' => target.copyWith(nickname: value),
      'base_url' => target.copyWith(baseUrl: value),
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
        'value': value,
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
