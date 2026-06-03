part of 'system_tools.dart';

/// Provider/module/tool introspection & toggle execute methods extracted from
/// [SystemTools].
extension SystemToolsIntrospection on SystemTools {
  // ─── system.providers.list ─────────────────────────────────────────────────

  Future<ToolExecutionResult> executeProvidersList() async {
    try {
      final providers = await loadProviders();
      return ToolExecutionResult(
        success: true,
        toolName: 'system.providers.list',
        data: {
          'count': providers.length,
          'providers': providers.map((p) => p.toPublicJson()).toList(),
          'apiKeysIncluded': false,
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'system.providers.list',
        error: e.toString(),
      );
    }
  }

  // ─── system.modules.list ───────────────────────────────────────────────────

  Future<ToolExecutionResult> executeModulesList() async {
    try {
      final installed = await moduleRepository.getInstalled();
      final installedById = {for (final module in installed) module.id: module};
      final available = ModuleRegistry.available.map((spec) {
        final installedModule = installedById[spec.id];
        return {
          'id': spec.id,
          'name': spec.name,
          'description': spec.description,
          'installed': installedModule != null,
          'enabled': installedModule?.enabled ?? false,
          'settings': installedModule?.settings ?? spec.settings,
        };
      }).toList();

      return ToolExecutionResult(
        success: true,
        toolName: 'system.modules.list',
        data: {
          'availableCount': ModuleRegistry.available.length,
          'installedCount': installed.length,
          'enabledCount': installed.where((m) => m.enabled).length,
          'modules': available,
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'system.modules.list',
        error: e.toString(),
      );
    }
  }

  // ─── system.tools.list ─────────────────────────────────────────────────────

  Future<ToolExecutionResult> executeToolsList() async {
    try {
      final policy = ToolPermissionPolicy(
        moduleRepository,
        permissionManager: PermissionManager(),
      );
      final tools = <Map<String, dynamic>>[];
      for (final def in toolDefinitions) {
        final check = await policy.check(def.name);
        tools.add({
          'name': def.name,
          'description': def.description,
          'risk': def.risk,
          'requiresConfirmation': def.requiresConfirmation,
          'inputSchema': def.inputSchema,
          'available': check.allowed,
          'moduleId': check.requirement?.moduleId,
          'blockedReason': check.reason?.name,
          'blockedSetting': check.requirement?.settingKey,
        });
      }

      return ToolExecutionResult(
        success: true,
        toolName: 'system.tools.list',
        data: {
          'count': tools.length,
          'availableCount': tools.where((t) => t['available'] == true).length,
          'tools': tools,
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'system.tools.list',
        error: e.toString(),
      );
    }
  }

  // ─── system.modules.toggle ─────────────────────────────────────────────────

  /// Enable/disable an installed module or one of its setting toggles.
  /// When [settingKey] is omitted, toggles the module-level enabled flag.
  Future<ToolExecutionResult> executeModulesToggle(
    Map<String, dynamic> args,
  ) async {
    try {
      final moduleId = (args['moduleId'] as String? ?? '').trim();
      if (moduleId.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'system.modules.toggle',
          error: 'moduleId is required.',
        );
      }
      final installed = await moduleRepository.getInstalled();
      final mod = installed.where((m) => m.id == moduleId).firstOrNull;
      if (mod == null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'system.modules.toggle',
          error: 'Module not installed: $moduleId',
        );
      }
      final settingKey = (args['settingKey'] as String? ?? '').trim();
      final enabledArg = args['enabled'];
      if (settingKey.isEmpty) {
        // Toggle module-level enabled.
        final newEnabled = enabledArg is bool ? enabledArg : !mod.enabled;
        await moduleRepository.update(mod.copyWith(enabled: newEnabled));
        return ToolExecutionResult(
          success: true,
          toolName: 'system.modules.toggle',
          data: {
            'moduleId': moduleId,
            'enabled': newEnabled,
            'level': 'module',
          },
        );
      }
      // Toggle individual setting.
      if (!mod.settings.containsKey(settingKey)) {
        return ToolExecutionResult(
          success: false,
          toolName: 'system.modules.toggle',
          error:
              'Setting "$settingKey" not found on module $moduleId. Available: ${mod.settings.keys.join(", ")}',
        );
      }
      final current = mod.settings[settingKey] ?? false;
      final newValue = enabledArg is bool ? enabledArg : !current;
      final newSettings = {...mod.settings, settingKey: newValue};
      await moduleRepository.update(mod.copyWith(settings: newSettings));
      return ToolExecutionResult(
        success: true,
        toolName: 'system.modules.toggle',
        data: {
          'moduleId': moduleId,
          'settingKey': settingKey,
          'enabled': newValue,
          'level': 'setting',
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'system.modules.toggle',
        error: e.toString(),
      );
    }
  }
}