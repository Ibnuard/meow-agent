part of 'system_tools.dart';

extension SystemToolsConfig on SystemTools {
  Future<ToolExecutionResult> executeConfigRead(
    Map<String, dynamic> args,
  ) async {
    try {
      final repo = configRepository;
      if (repo == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'system.config.read',
          error: 'Config repository is not available.',
        );
      }
      final config = await repo.read();
      return ToolExecutionResult(
        success: true,
        toolName: 'system.config.read',
        data: {
          'config': config,
          'schemaVersion': config['schemaVersion'],
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

  Future<ToolExecutionResult> executeConfigPatch(
    Map<String, dynamic> args,
  ) async {
    try {
      final repo = configRepository;
      if (repo == null) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'system.config.patch',
          error: 'Config repository is not available.',
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
      final result = await repo.patch(ops);
      return ToolExecutionResult(
        success: true,
        toolName: 'system.config.patch',
        data: {
          'backupId': result.backupId,
          'changedPaths': result.changedPaths,
          'configHash': result.configHash,
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
}
