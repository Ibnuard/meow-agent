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
          '"agent_workspace_dir" (per-agent ext4 dir — ALL source code, builds, '
          'npm/bun install, git, and dev servers go here), '
          '"agent_export_dir" (shared storage target for vm.export). '
          'NEVER cd into "workspace_path" or "rootfs_path": those are HOST '
          'paths and do not exist inside the VM.',
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
          'so it survives across VM commands. Use vm.status first for paths: '
          'cwd MUST be under agent_workspace_dir (the per-agent ext4 dir where '
          'source, node_modules, and build output live). Set ready_path to the '
          'exact page/file path and expected_text to brand/title text when '
          'serving static HTML, so a directory listing does not count as '
          'success. Failure includes log_tail/readiness details. Use this '
          'instead of vm.run_command for any dev/web server.',
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
    ToolDefinition(
      name: 'vm.write_file',
      description:
          'Write a source file directly into the per-agent VM workspace '
          '(ext4 — supports symlinks, so npm/bun install and git work). This '
          'is the CORRECT way to create project source code for any task that '
          'builds or serves code in the VM. The file lands at '
          'agent_workspace_dir/<relative_path>. Prefer this over files.create '
          'for code projects: files.create writes to shared storage (FUSE) '
          'where npm/bun install and git FAIL. relative_path is relative to '
          'the per-agent workspace, e.g. "my-app/src/index.js".',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'relative_path':
            'string (REQUIRED - path within the agent workspace, e.g. "my-app/index.html")',
        'content': 'string (REQUIRED - full file contents)',
      },
      isRetrieval: false,
    ),
    ToolDefinition(
      name: 'vm.export',
      description:
          'Copy a finished/revised project from the per-agent VM workspace to '
          'the shared MeowAgent folder so the user can see it in the device '
          'file manager. Skips node_modules, .git, dist, build, .next, .cache '
          'and symlinks. The VM workspace remains the single source of truth — '
          'export produces a static snapshot for the user to browse. Ask the '
          'user before exporting (the runtime renders an approve/cancel card). '
          'After the first export, offer to re-export whenever you revise the '
          'project so the shared copy stays current.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {
        'project_dir':
            'string (optional - project subfolder within the agent workspace, e.g. "my-app"; omit to export the whole workspace)',
      },
      isRetrieval: false,
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
        return _snapshotResultWithAgent(request.name, snapshot, ctx.agentName);

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

      case 'vm.write_file':
        final relativePath =
            (request.args['relative_path'] ?? '').toString().trim();
        final content = (request.args['content'] ?? '').toString();
        if (relativePath.isEmpty) {
          return _error(request.name, 'Missing required parameter: relative_path');
        }
        if (ctx.agentName.trim().isEmpty) {
          return _error(request.name, 'Agent identity is unavailable.');
        }
        final result = await service.writeWorkspaceFile(
          agentName: ctx.agentName,
          relativePath: relativePath,
          content: content,
        );
        return ToolExecutionResult(
          toolName: request.name,
          success: result['success'] == true,
          error: result['success'] == true ? null : result['message']?.toString(),
          data: result,
        );

      case 'vm.export':
        final projectDir = (request.args['project_dir'] ?? '').toString().trim();
        if (ctx.agentName.trim().isEmpty) {
          return _error(request.name, 'Agent identity is unavailable.');
        }
        final result = await service.exportProject(
          agentName: ctx.agentName,
          projectDir: projectDir,
        );
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

  ToolExecutionResult _snapshotResultWithAgent(
    String toolName,
    VmRuntimeSnapshot snapshot,
    String agentName,
  ) {
    final data = Map<String, dynamic>.from(snapshot.toJson());
    final safeName = agentName
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .trim();
    if (safeName.isNotEmpty) {
      data['agent_workspace_dir'] = '/root/workspace/$safeName';
      data['agent_export_dir'] = '/root/meow/Agents/$safeName';
    }
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
