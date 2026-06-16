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
          '"running", tell the user to open the VM Runtime screen and start it. '
          'The result includes IN-GUEST paths you MUST use for shell commands: '
          '"vm_working_dir" (internal, for builds/installs/git) and '
          '"agent_files_dir" (where files created via the files module live, '
          'e.g. landing pages — read/serve from here). NEVER cd into '
          '"workspace_path" or "rootfs_path": those are HOST paths and do not '
          'exist inside the VM.',
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
          'Run a finite shell command inside the local VM runtime and return '
          'stdout, stderr, and exit_code. Use this for build/check/file tasks '
          'that exit. For long-running web/dev servers, use vm.start_server '
          'instead — it spawns and verifies the server natively.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {
        'command': 'string (REQUIRED - command to run inside the VM session)',
        'timeout_ms':
            'number (optional - max execution time in ms, default 60000)',
      },
      isRetrieval: false,
    ),
    ToolDefinition(
      name: 'vm.start_server',
      description:
          'Start a long-running server process inside the VM and verify HTTP '
          'readiness before reporting success. Generic: works for bun, node, '
          'python, php, vite, etc. Spawned natively outside the interactive shell, '
          'so it survives across VM commands. Use vm.status first for paths: serve '
          'files from agent_files_dir, build/install in vm_working_dir. Set '
          'ready_path to the exact page/file path and expected_text to brand/title '
          'text when serving static HTML, so a directory listing does not count as '
          'success. Failure includes log_tail/readiness details. Use this instead '
          'of vm.run_command for any dev/web server.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {
        'name': 'string (REQUIRED - stable server name, e.g. bejo)',
        'command': 'string (REQUIRED - foreground server command, no nohup/&)',
        'cwd': 'string (REQUIRED - in-VM working directory)',
        'port': 'number (REQUIRED - TCP port to verify)',
        'ready_timeout_ms':
            'number (optional - wait for HTTP readiness, default 10000)',
        'ready_path':
            'string (optional - HTTP path to verify, default /; set to the target file path to avoid directory-listing false success)',
        'expected_text':
            'string (optional - text that must appear in the HTTP body before success; use brand/title text for static pages)',
      },
      isRetrieval: false,
    ),
    ToolDefinition(
      name: 'vm.stop_server',
      description:
          'Stop a server previously started with vm.start_server by name.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {
        'name': 'string (REQUIRED - server name)',
      },
      isRetrieval: false,
    ),
    ToolDefinition(
      name: 'vm.list_servers',
      description:
          'List servers started by vm.start_server, including pid, port, url, '
          'alive, listening, cwd, and log_path.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {},
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

      case 'vm.start_server':
        final name = (request.args['name'] ?? '').toString().trim();
        final command = (request.args['command'] ?? '').toString().trim();
        final cwd = (request.args['cwd'] ?? '').toString().trim();
        final port = _readInt(request.args['port']) ?? -1;
        if (name.isEmpty) return _error(request.name, 'Missing required parameter: name');
        if (command.isEmpty) return _error(request.name, 'Missing required parameter: command');
        if (cwd.isEmpty) return _error(request.name, 'Missing required parameter: cwd');
        if (port <= 0 || port > 65535) return _error(request.name, 'Invalid required parameter: port');
        final readyTimeoutMs = _readInt(request.args['ready_timeout_ms']) ?? 10000;
        final readyPath = (request.args['ready_path'] ?? '/').toString().trim();
        final expectedText = (request.args['expected_text'] ?? '').toString();
        final result = await service.startServer(
          name: name,
          command: command,
          cwd: cwd,
          port: port,
          readyTimeoutMs: readyTimeoutMs,
          readyPath: readyPath.isEmpty ? '/' : readyPath,
          expectedText: expectedText,
        );
        return ToolExecutionResult(
          toolName: request.name,
          success: result.success,
          error: result.success ? null : result.message,
          data: result.toJson(),
        );

      case 'vm.stop_server':
        final name = (request.args['name'] ?? '').toString().trim();
        if (name.isEmpty) return _error(request.name, 'Missing required parameter: name');
        final result = await service.stopServer(name);
        return ToolExecutionResult(
          toolName: request.name,
          success: result.success,
          error: result.success ? null : result.message,
          data: result.toJson(),
        );

      case 'vm.list_servers':
        final result = await service.listServers();
        return ToolExecutionResult(
          toolName: request.name,
          success: result['success'] == true,
          error: result['success'] == true ? null : result['message']?.toString(),
          data: result,
        );

      default:
        return _error(request.name, 'Unknown tool: ${request.name}');
    }
  }

  /// Build the `vm.list_plugins` payload from the curated catalog plus
  /// persisted install state. For plugins with unknown status, do a live
  /// probe to detect manual installs (e.g. via terminal).
  Future<ToolExecutionResult> _listPluginsResult(String toolName) async {
    final repo = VmRuntimeRepository();
    final service = const VmRuntimeService();
    final states = await repo.readPluginStates();
    final entries = <Map<String, dynamic>>[];

    for (final plugin in VmPluginCatalog.available) {
      var state = states[plugin.id];
      // Live-probe plugins with unknown/notInstalled status to catch
      // manual installs done via the terminal.
      if (state == null ||
          state.status == VmPluginStatus.unknown ||
          state.status == VmPluginStatus.notInstalled) {
        final probe = await service.probePlugin(
          pluginId: plugin.id,
          versionCommand: plugin.versionCommand,
        );
        if (probe.success && probe.stdout.trim().isNotEmpty) {
          state = VmPluginState(
            pluginId: plugin.id,
            status: VmPluginStatus.installed,
            version: probe.stdout.trim(),
          );
          await repo.savePluginState(state);
        }
      }
      entries.add({
        'id': plugin.id,
        'name': plugin.name,
        'description': plugin.description,
        'tags': plugin.tags,
        'estimated_size_mb': plugin.estimatedSizeMb,
        'status': (state?.status ?? VmPluginStatus.unknown).wireName,
        if (state != null && state.version.isNotEmpty)
          'version': state.version,
      });
    }

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
