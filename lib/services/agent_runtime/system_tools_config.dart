part of 'system_tools.dart';

extension SystemToolsConfig on SystemTools {
  /// Read app configuration from SQLite. Synthesizes a `meow.json`-shaped
  /// object so existing prompt patterns keep working without rewrites.
  /// All sources are SQLite — no file I/O.
  Future<ToolExecutionResult> executeConfigRead(
    Map<String, dynamic> args,
  ) async {
    try {
      final settings = appSettings;
      if (settings == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'system.config.read',
          error: 'Settings store is not available.',
        );
      }

      final allSettings = await settings.getAll();
      final liveAgents = await loadAgents();
      final liveProviders = await loadProviders();
      final liveModules = await moduleRepository.getInstalled();

      // Join soul data per agent so the LLM sees persona in one call.
      final agentEntries = <Map<String, dynamic>>[];
      for (final a in liveAgents) {
        final base = a.toJson();
        final soul = coreSoulRepo != null ? await coreSoulRepo!.get(a.id) : null;
        base['soul'] = soul == null
            ? null
            : {
                'user_name': soul.userName ?? '',
                'user_nickname': soul.userNickname ?? '',
                'persona': soul.persona ?? '',
                'communication_style': soul.communicationStyle ?? '',
                'work_role': soul.workRole ?? '',
                'main_project': soul.mainProject ?? '',
                'design_preference': soul.designPreference ?? '',
                'preferred_language': soul.preferredLanguage ?? '',
                'timezone': soul.timezone ?? '',
              };
        agentEntries.add(base);
      }

      final synthetic = <String, dynamic>{
        'schemaVersion': 2,
        'prefs': {
          'theme': allSettings['prefs.theme'] ?? 'system',
          'language': allSettings['prefs.language'] ?? 'system',
        },
        'activeAgentId': allSettings['active.agent_id'],
        'activeProviderId': allSettings['active.provider_id'],
        'agents': agentEntries,
        'providers': liveProviders.map((p) => p.toPublicJson()).toList(),
        'modules': {
          for (final m in liveModules) m.id: m.toJson(),
        },
      };

      return ToolExecutionResult(
        success: true,
        toolName: 'system.config.read',
        data: {
          'config': synthetic,
          'schemaVersion': 2,
          'valid': true,
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'system.config.read',
        error: e.toString(),
      );
    }
  }

  /// Apply patch operations to SQLite-backed config. Restricted to the paths
  /// that map to `app_settings` keys or the `modules` table. Agents and
  /// providers must use their dedicated domain tools.
  Future<ToolExecutionResult> executeConfigPatch(
    Map<String, dynamic> args,
  ) async {
    try {
      final settings = appSettings;
      final entries = moduleEntries;
      if (settings == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'system.config.patch',
          error: 'Settings store is not available.',
        );
      }

      final rawOps = args['operations'];
      if (rawOps is! List) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'system.config.patch',
          error: 'operations is required and must be a list.',
        );
      }
      final ops = rawOps
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();

      final changedPaths = <String>[];
      for (final op in ops) {
        final opName = (op['op'] as String? ?? '').trim();
        final path = (op['path'] as String? ?? '').trim();
        final value = op['value'];

        if (path.startsWith('/agents') || path.startsWith('/providers')) {
          return const ToolExecutionResult(
            success: false,
            toolName: 'system.config.patch',
            error:
                'Agent and provider CRUD is not available via config patch. '
                'Use the dedicated tools: agent.create, agent.delete, agent.update, '
                'provider.create, provider.delete, provider.update.',
          );
        }

        switch (path) {
          case '/prefs/theme':
            await settings.set('prefs.theme', _coerceString(value));
            changedPaths.add(path);
            break;
          case '/prefs/language':
            await settings.set('prefs.language', _coerceString(value));
            changedPaths.add(path);
            break;
          case '/activeAgentId':
            if (opName == 'remove' || value == null) {
              await settings.remove('active.agent_id');
            } else {
              await settings.set('active.agent_id', _coerceString(value));
            }
            changedPaths.add(path);
            break;
          case '/activeProviderId':
            if (opName == 'remove' || value == null) {
              await settings.remove('active.provider_id');
            } else {
              await settings.set('active.provider_id', _coerceString(value));
            }
            changedPaths.add(path);
            break;
          default:
            // Module config writes — only when moduleEntries is wired.
            final moduleMatch = RegExp(
              r'^/modules/([^/]+)/(enabled|settings)$',
            ).firstMatch(path);
            if (moduleMatch != null && entries != null) {
              final moduleId = moduleMatch.group(1)!;
              final field = moduleMatch.group(2)!;
              if (field == 'enabled') {
                final v = value == true || value == 'true' || value == 1;
                await entries.setEnabled(moduleId, v);
                changedPaths.add(path);
              } else {
                if (value is Map) {
                  await entries.setConfig(
                    moduleId,
                    {'settings': Map<String, dynamic>.from(value)},
                  );
                  changedPaths.add(path);
                } else {
                  return ToolExecutionResult(
                    success: false,
                    toolName: 'system.config.patch',
                    error:
                        'Module settings value must be a JSON object: $path',
                  );
                }
              }
              break;
            }
            return ToolExecutionResult(
              success: false,
              toolName: 'system.config.patch',
              error:
                  'Unsupported config path: $path. Allowed paths: '
                  '/prefs/theme, /prefs/language, /activeAgentId, '
                  '/activeProviderId, /modules/<id>/enabled, '
                  '/modules/<id>/settings.',
            );
        }
      }

      return ToolExecutionResult(
        success: true,
        toolName: 'system.config.patch',
        data: {
          'changedPaths': changedPaths,
          'backupId': '',
          'configHash': '',
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'system.config.patch',
        error: e.toString(),
      );
    }
  }

  static String _coerceString(Object? value) {
    if (value == null) return '';
    if (value is String) return value;
    return value.toString();
  }
}
