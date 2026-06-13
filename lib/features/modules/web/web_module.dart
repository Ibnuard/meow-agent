import 'dart:convert';

import '../../../services/agent_runtime/module_plugin.dart';
import '../../../services/agent_runtime/runtime_models.dart';
import 'data/api_config.dart';
import 'data/api_store_repository.dart';
import 'domain/http_executor.dart';

/// Web/API module plugin.
///
/// Provides HTTP fetch and registered API call tools. Self-registering —
/// add to runtime_module_plugins.dart and done.
class WebModulePlugin extends ModulePlugin {
  const WebModulePlugin();

  @override
  String get moduleId => 'web';

  @override
  String get catalogGroup => 'web';

  @override
  List<String> get capabilityHints => const [
        'fetch',
        'http',
        'api',
        'request',
        'url',
        'endpoint',
        'rest',
        'get',
        'post',
        'webhook',
        'curl',
      ];

  @override
  List<ToolDefinition> get toolDefinitions => const [
        ToolDefinition(
          name: 'web.fetch',
          description:
              'Make an HTTP request to any public URL. Use for ad-hoc API calls, '
              'fetching web data, checking endpoints, or any one-off HTTP request. '
              'Supports GET, POST, PUT, PATCH, DELETE. HTTPS URLs only.',
          risk: 'moderate',
          requiresConfirmation: false,
          inputSchema: {
            'url': 'string (REQUIRED — full URL including https://)',
            'method':
                'string (optional, default GET — one of: GET, POST, PUT, PATCH, DELETE, HEAD)',
            'headers': 'object (optional — key-value pairs for request headers)',
            'body':
                'string (optional — request body for POST/PUT/PATCH, JSON string)',
          },
          isRetrieval: true,
        ),
        ToolDefinition(
          name: 'web.api.list',
          description:
              'List all registered APIs in the global API Store. Shows name, URL, '
              'method, and available dynamic parameters for each.',
          risk: 'safe',
          requiresConfirmation: false,
          inputSchema: {},
          isRetrieval: true,
        ),
        ToolDefinition(
          name: 'web.api.call',
          description:
              'Call a registered API from the API Store by name or ID. The API '
              'configuration (URL, auth, headers) is loaded from the store. '
              'Dynamic parameters are filled from the user\'s request context. '
              'Use @api: mention to reference a specific API.',
          risk: 'safe',
          requiresConfirmation: false,
          inputSchema: {
            'api':
                'string (REQUIRED — API name or ID from the store)',
            'params':
                'object (optional — values for dynamic query parameters, keys must match param names in the config)',
            'body_params':
                'object (optional — values for dynamic body fields)',
            'endpoint_override':
                'string (optional — append to the base URL, e.g. "/repos" appended to "https://api.github.com")',
          },
          isRetrieval: true,
        ),
        ToolDefinition(
          name: 'web.api.register',
          description:
              'Register a new API in the global API Store. Once registered, any '
              'agent can call it by name using web.api.call. Provide the name, '
              'URL, method, and optionally headers, query parameters, auth, and body. '
              'Use this when the user wants to save/store an API endpoint for reuse.',
          risk: 'moderate',
          requiresConfirmation: true,
          inputSchema: {
            'name': 'string (REQUIRED — display name, e.g. "GitHub Search API")',
            'url': 'string (REQUIRED — base URL including https://)',
            'method': 'string (optional, default GET)',
            'auth_type': 'string (optional — one of: none, bearer, apiKeyHeader, basic)',
            'auth_value': 'string (optional — token/key value for the chosen auth type)',
            'auth_header_name': 'string (optional — header name for apiKeyHeader type, e.g. "X-API-Key")',
            'headers': 'object (optional — static headers as key-value pairs)',
            'query_params': 'array (optional — each item: {key, value, mode:"fixed"|"dynamic", hint?, default?})',
            'body_raw': 'string (optional — raw JSON body template)',
          },
          isRetrieval: false,
        ),
        ToolDefinition(
          name: 'web.api.remove',
          description:
              'Remove a registered API from the global API Store by name or ID.',
          risk: 'destructive',
          requiresConfirmation: true,
          inputSchema: {
            'api': 'string (REQUIRED — API name or ID to remove)',
          },
          isRetrieval: false,
        ),
      ];

  @override
  Future<ToolExecutionResult> dispatch(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) async {
    switch (request.name) {
      case 'web.fetch':
        return _handleFetch(request);
      case 'web.api.list':
        return _handleApiList();
      case 'web.api.call':
        return _handleApiCall(request);
      case 'web.api.register':
        return _handleApiRegister(request);
      case 'web.api.remove':
        return _handleApiRemove(request);
      default:
        return ToolExecutionResult(
          toolName: request.name,
          success: false,
          error: 'Unknown tool: ${request.name}',
          data: const {},
        );
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Tool handlers
  // ─────────────────────────────────────────────────────────────────────────

  Future<ToolExecutionResult> _handleFetch(ToolCallRequest request) async {
    final url = request.args['url'] as String?;
    if (url == null || url.isEmpty) {
      return ToolExecutionResult(
        toolName: request.name,
        success: false,
        error: 'Missing required parameter: url',
        data: const {},
      );
    }

    final method =
        (request.args['method'] as String?)?.toUpperCase() ?? 'GET';
    final headersRaw = request.args['headers'];
    final headers = <String, String>{};
    if (headersRaw is Map) {
      headersRaw.forEach((k, v) => headers[k.toString()] = v.toString());
    }
    final body = request.args['body'] as String?;

    final executor = HttpExecutor();
    final result = await executor.execute(
      url: url,
      method: method,
      headers: headers,
      body: body,
    );

    if (result.error != null) {
      return ToolExecutionResult(
        toolName: request.name,
        success: false,
        error: result.error!,
        data: result.toJson(),
      );
    }

    return ToolExecutionResult(
      toolName: request.name,
      success: true,
      data: result.toJson(),
    );
  }

  Future<ToolExecutionResult> _handleApiList() async {
    final repo = ApiStoreRepository.instance;
    final apis = await repo.list();

    if (apis.isEmpty) {
      return ToolExecutionResult(
        toolName: 'web.api.list',
        success: true,
        data: {
          'count': 0,
          'apis': <Map<String, dynamic>>[],
          'message': 'No APIs registered in the store yet.',
        },
      );
    }

    final summaries = apis.map((a) {
      final dynamicParams = a.queryParams
          .where((p) => p.mode == ParamMode.dynamic)
          .map((p) => {'key': p.key, 'hint': p.hint ?? p.key})
          .toList();
      return {
        'id': a.id,
        'name': a.name,
        'url': a.url,
        'method': a.method,
        'dynamic_params': dynamicParams,
      };
    }).toList();

    return ToolExecutionResult(
      toolName: 'web.api.list',
      success: true,
      data: {'count': apis.length, 'apis': summaries},
    );
  }

  Future<ToolExecutionResult> _handleApiCall(ToolCallRequest request) async {
    final apiRef = request.args['api'] as String?;
    if (apiRef == null || apiRef.isEmpty) {
      return ToolExecutionResult(
        toolName: request.name,
        success: false,
        error: 'Missing required parameter: api (name or ID)',
        data: const {},
      );
    }

    final repo = ApiStoreRepository.instance;

    // Resolve by ID first, then by name.
    ApiConfig? config = await repo.findById(apiRef);
    config ??= await repo.findByName(apiRef);

    if (config == null) {
      // Try partial match.
      final all = await repo.list();
      final lower = apiRef.toLowerCase();
      final matches =
          all.where((a) => a.name.toLowerCase().contains(lower)).toList();
      if (matches.length == 1) {
        config = matches.first;
      } else if (matches.length > 1) {
        return ToolExecutionResult(
          toolName: request.name,
          success: false,
          error:
              'Multiple APIs match "$apiRef": ${matches.map((a) => a.name).join(", ")}. Please be more specific.',
          data: {
            'matches': matches.map((a) => {'id': a.id, 'name': a.name}).toList(),
          },
        );
      } else {
        return ToolExecutionResult(
          toolName: request.name,
          success: false,
          error: 'No API found matching "$apiRef" in the store.',
          data: const {},
        );
      }
    }

    // Resolve dynamic query params from request args.
    final paramsRaw = request.args['params'];
    final resolvedParams = <String, String>{};
    if (paramsRaw is Map) {
      paramsRaw.forEach((k, v) => resolvedParams[k.toString()] = v.toString());
    }

    // Fill dynamic params with defaults where not provided.
    for (final p in config.queryParams) {
      if (p.mode == ParamMode.dynamic && !resolvedParams.containsKey(p.key)) {
        final def = p.defaultValue ?? '';
        if (def.isNotEmpty) resolvedParams[p.key] = def;
      }
    }

    // Handle endpoint override (append path).
    String url = config.url;
    final endpointOverride = request.args['endpoint_override'] as String?;
    if (endpointOverride != null && endpointOverride.isNotEmpty) {
      if (url.endsWith('/') && endpointOverride.startsWith('/')) {
        url = '$url${endpointOverride.substring(1)}';
      } else if (!url.endsWith('/') && !endpointOverride.startsWith('/')) {
        url = '$url/$endpointOverride';
      } else {
        url = '$url$endpointOverride';
      }
    }

    // Build body from dynamic body params if provided.
    String? resolvedBody;
    final bodyParamsRaw = request.args['body_params'];
    if (bodyParamsRaw is Map && bodyParamsRaw.isNotEmpty) {
      // Merge dynamic body params into the tree.
      resolvedBody = _buildBodyWithDynamics(config, bodyParamsRaw);
    }

    // Execute.
    final executor = HttpExecutor();
    final configWithUrl = ApiConfig(
      id: config.id,
      name: config.name,
      url: url,
      method: config.method,
      auth: config.auth,
      headers: config.headers,
      queryParams: config.queryParams,
      bodyMode: config.bodyMode,
      bodyTree: config.bodyTree,
      bodyRaw: config.bodyRaw,
      createdAt: config.createdAt,
    );

    final result = await executor.executeFromConfig(
      config: configWithUrl,
      resolvedQueryParams: resolvedParams,
      resolvedBody: resolvedBody,
    );

    if (result.error != null) {
      return ToolExecutionResult(
        toolName: request.name,
        success: false,
        error: result.error!,
        data: {
          'api_name': config.name,
          ...result.toJson(),
        },
      );
    }

    return ToolExecutionResult(
      toolName: request.name,
      success: true,
      data: {
        'api_name': config.name,
        ...result.toJson(),
      },
    );
  }

  Future<ToolExecutionResult> _handleApiRegister(ToolCallRequest request) async {
    final name = request.args['name'] as String?;
    final url = request.args['url'] as String?;

    if (name == null || name.isEmpty) {
      return ToolExecutionResult(
        toolName: request.name,
        success: false,
        error: 'Missing required parameter: name',
        data: const {},
      );
    }
    if (url == null || url.isEmpty) {
      return ToolExecutionResult(
        toolName: request.name,
        success: false,
        error: 'Missing required parameter: url',
        data: const {},
      );
    }

    // Check for duplicate name.
    final repo = ApiStoreRepository.instance;
    final existing = await repo.findByName(name);
    if (existing != null) {
      return ToolExecutionResult(
        toolName: request.name,
        success: false,
        error: 'An API named "$name" already exists (id: ${existing.id}). Use a different name or remove the existing one first.',
        data: {'existing_id': existing.id},
      );
    }

    final method =
        (request.args['method'] as String?)?.toUpperCase() ?? 'GET';

    // Parse auth.
    final authTypeStr = request.args['auth_type'] as String? ?? 'none';
    final authValue = request.args['auth_value'] as String? ?? '';
    final authHeaderName = request.args['auth_header_name'] as String?;
    final authType = ApiAuthType.values.firstWhere(
      (e) => e.name == authTypeStr,
      orElse: () => ApiAuthType.none,
    );
    final auth = ApiAuth(
      type: authType,
      value: authValue,
      headerName: authHeaderName,
    );

    // Parse headers.
    final headersRaw = request.args['headers'];
    final headers = <ApiParam>[];
    if (headersRaw is Map) {
      headersRaw.forEach((k, v) {
        headers.add(ApiParam(key: k.toString(), value: v.toString()));
      });
    }

    // Parse query params.
    final queryParamsRaw = request.args['query_params'];
    final queryParams = <ApiParam>[];
    if (queryParamsRaw is List) {
      for (final item in queryParamsRaw) {
        if (item is Map) {
          queryParams.add(ApiParam(
            key: (item['key'] ?? '').toString(),
            value: (item['value'] ?? '').toString(),
            mode: item['mode'] == 'dynamic' ? ParamMode.dynamic : ParamMode.fixed,
            hint: item['hint'] as String?,
            defaultValue: item['default'] as String?,
          ));
        }
      }
    }

    // Parse body.
    final bodyRaw = request.args['body_raw'] as String?;
    final bodyMode = bodyRaw != null && bodyRaw.isNotEmpty
        ? BodyMode.raw
        : BodyMode.none;

    final config = ApiConfig(
      id: ApiConfig.generateId(),
      name: name,
      url: url,
      method: method,
      auth: auth,
      headers: headers,
      queryParams: queryParams,
      bodyMode: bodyMode,
      bodyRaw: bodyRaw,
    );

    await repo.save(config);

    return ToolExecutionResult(
      toolName: request.name,
      success: true,
      data: {
        'id': config.id,
        'name': config.name,
        'url': config.url,
        'method': config.method,
        'message': 'API "$name" registered successfully. Any agent can now call it with web.api.call.',
      },
    );
  }

  Future<ToolExecutionResult> _handleApiRemove(ToolCallRequest request) async {
    final apiRef = request.args['api'] as String?;
    if (apiRef == null || apiRef.isEmpty) {
      return ToolExecutionResult(
        toolName: request.name,
        success: false,
        error: 'Missing required parameter: api (name or ID)',
        data: const {},
      );
    }

    final repo = ApiStoreRepository.instance;

    // Resolve by ID first, then by name.
    ApiConfig? config = await repo.findById(apiRef);
    config ??= await repo.findByName(apiRef);

    if (config == null) {
      return ToolExecutionResult(
        toolName: request.name,
        success: false,
        error: 'No API found matching "$apiRef" in the store.',
        data: const {},
      );
    }

    await repo.remove(config.id);

    return ToolExecutionResult(
      toolName: request.name,
      success: true,
      data: {
        'id': config.id,
        'name': config.name,
        'message': 'API "${config.name}" removed from the store.',
      },
    );
  }

  /// Build body JSON with dynamic field overrides.
  String? _buildBodyWithDynamics(ApiConfig config, Map<dynamic, dynamic> overrides) {
    if (config.bodyMode == BodyMode.raw && config.bodyRaw != null) {
      // For raw mode, try to parse and inject overrides.
      try {
        final parsed = jsonDecode(config.bodyRaw!) as Map<String, dynamic>;
        overrides.forEach((k, v) => parsed[k.toString()] = v);
        return jsonEncode(parsed);
      } catch (_) {
        return config.bodyRaw;
      }
    }
    if (config.bodyMode == BodyMode.tree && config.bodyTree.isNotEmpty) {
      final map = _treeToJsonWithOverrides(config.bodyTree, overrides);
      return jsonEncode(map);
    }
    if (overrides.isNotEmpty) {
      return jsonEncode(
        Map.fromEntries(
          overrides.entries.map((e) => MapEntry(e.key.toString(), e.value)),
        ),
      );
    }
    return null;
  }

  Map<String, dynamic> _treeToJsonWithOverrides(
    List<BodyNode> nodes,
    Map<dynamic, dynamic> overrides,
  ) {
    final map = <String, dynamic>{};
    for (final node in nodes) {
      if (node.mode == ParamMode.dynamic && overrides.containsKey(node.key)) {
        map[node.key] = overrides[node.key];
      } else {
        map[node.key] = _nodeToValue(node);
      }
    }
    return map;
  }

  dynamic _nodeToValue(BodyNode node) {
    switch (node.type) {
      case 'object':
        final map = <String, dynamic>{};
        for (final child in node.children) {
          map[child.key] = _nodeToValue(child);
        }
        return map;
      case 'array':
        return node.items.map(_nodeToValue).toList();
      case 'number':
        return num.tryParse(node.value ?? '0') ?? 0;
      case 'boolean':
        return node.value?.toLowerCase() == 'true';
      default:
        // For dynamic params, use default if value empty.
        if (node.mode == ParamMode.dynamic) {
          return node.defaultValue ?? node.value ?? '';
        }
        return node.value ?? '';
    }
  }
}
