part of 'system_tools.dart';

/// Provider/module/tool introspection & toggle execute methods extracted from
/// [SystemTools].
extension SystemToolsIntrospection on SystemTools {
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
}
