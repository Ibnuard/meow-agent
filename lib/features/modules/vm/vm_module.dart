import '../../../services/agent_runtime/module_plugin.dart';
import '../../../services/agent_runtime/runtime_models.dart';
import 'vm_models.dart';
import 'vm_plugins.dart';
import 'vm_repository.dart';
import 'vm_runtime_service.dart';

/// Agent-facing surface for the VM module.
///
/// Per AGENTS.md (#1 accuracy, #4 efficient ≠ stingy, #6 validation):
///
/// * `vm.status` — read current runtime state. Always safe.
/// * `vm.list_plugins` — see which language toolchains are installed
///   inside the runtime. The agent uses this to decide whether the user's
///   request is satisfiable (e.g. "build a Vite app" → check `node`).
/// * `vm.run_command` — execute a single shell command and return
///   stdout/stderr/exit_code. Only works when the runtime is running.
///
/// Lifecycle (install rootfs, start/stop service, install plugins) is
/// user-only: those decisions need device-level consent and observable UI.
/// The agent must ask the user to act in the VM Runtime screen.
class VmModulePlugin extends ModulePlugin {
  const VmModulePlugin();

  @override
  String get moduleId => 'vm';

  @override
  String get catalogGroup => 'vm';

  @override
  List<String> get capabilityHints => const [
    'vm',
    'linux',
    'shell',
    'terminal',
    'run command',
    'bash',
    'plugins',
    'toolchain',
    'node',
    'python',
    'git',
  ];

  @override
  List<ToolDefinition> get toolDefinitions => const [
    ToolDefinition(
      name: 'vm.status',
      description:
          'Read the local Linux runtime status. Use this before vm.run_command '
          'to confirm the runtime is installed and running. If status is not '
          '"running", tell the user to open the VM Runtime screen and start it.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {},
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'vm.list_plugins',
      description:
          'List the available runtime plugins (language toolchains and CLIs) '
          'and whether each one is installed. Use this BEFORE planning work '
          'that needs a toolchain (e.g. node for web, python for scripts). '
          'If a plugin you need is missing, ask the user to install it from '
          'the VM Runtime screen — never try to install it yourself.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {},
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'vm.run_command',
      description:
          'Run a shell command inside the local VM runtime and return '
          'stdout, stderr, and exit_code. Only works after vm.status reports '
          '"running". Required plugins must be installed first; check with '
          'vm.list_plugins.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {
        'command': 'string (REQUIRED - command to run inside the VM session)',
        'timeout_ms':
            'number (optional - max execution time in ms, default 60000)',
      },
      isRetrieval: true,
    ),
  ];

  @override
  Future<ToolExecutionResult> dispatch(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) async {
    const service = VmRuntimeService();
    switch (request.name) {
      case 'vm.status':
        final snapshot = await service.status();
        return _snapshotResult(request.name, snapshot);

      case 'vm.list_plugins':
        return _listPluginsResult(request.name);

      case 'vm.run_command':
        final command = request.args['command'] as String? ?? '';
        if (command.trim().isEmpty) {
          return _error(request.name, 'Missing required parameter: command');
        }
        final timeoutMs = _readInt(request.args['timeout_ms']) ?? 60000;
        final result = await service.runCommand(command, timeoutMs: timeoutMs);
        return ToolExecutionResult(
          toolName: request.name,
          success: result.success,
          error: result.success ? null : (result.message.isNotEmpty
              ? result.message
              : (result.stderr.isNotEmpty ? result.stderr : 'Command failed')),
          data: result.toJson(),
        );

      default:
        return _error(request.name, 'Unknown tool: ${request.name}');
    }
  }

  /// Build the `vm.list_plugins` payload from the curated catalog plus
  /// persisted install state. The agent never sees opaque ids: each entry
  /// includes name, description, tags, and install status.
  Future<ToolExecutionResult> _listPluginsResult(String toolName) async {
    final repo = VmRuntimeRepository();
    final states = await repo.readPluginStates();
    final entries = VmPluginCatalog.available.map((plugin) {
      final state = states[plugin.id];
      return {
        'id': plugin.id,
        'name': plugin.name,
        'description': plugin.description,
        'tags': plugin.tags,
        'estimated_size_mb': plugin.estimatedSizeMb,
        'status': (state?.status ?? VmPluginStatus.unknown).wireName,
        if (state != null && state.version.isNotEmpty)
          'version': state.version,
      };
    }).toList(growable: false);

    return ToolExecutionResult(
      toolName: toolName,
      success: true,
      data: {
        'plugins': entries,
        'installed_count': entries
            .where((e) => e['status'] == VmPluginStatus.installed.wireName)
            .length,
        'total_count': entries.length,
      },
    );
  }

  ToolExecutionResult _snapshotResult(
    String toolName,
    VmRuntimeSnapshot snapshot,
  ) {
    final data = snapshot.toJson();
    final nativeAvailable = data['native_runtime_available'] == true;
    final statusRead = toolName == 'vm.status';
    return ToolExecutionResult(
      toolName: toolName,
      success: statusRead || nativeAvailable,
      error: statusRead || nativeAvailable ? null : data['message'] as String?,
      data: data,
    );
  }

  ToolExecutionResult _error(String toolName, String message) {
    return ToolExecutionResult(
      toolName: toolName,
      success: false,
      error: message,
      data: const {},
    );
  }

  int? _readInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}
