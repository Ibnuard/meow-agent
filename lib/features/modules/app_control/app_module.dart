import '../../../services/agent_runtime/module_plugin.dart';
import '../../../services/agent_runtime/runtime_models.dart';
import 'app_tools.dart';

class AppModulePlugin extends ModulePlugin {
  const AppModulePlugin();

  @override
  String get moduleId => 'app_control';

  @override
  String get catalogGroup => 'app';

  @override
  List<String> get capabilityHints => const [
    'app',
    'apps',
    'open',
    'launch',
    'settings',
    'url',
    'browser',
  ];

  @override
  List<ToolDefinition> get toolDefinitions => const [
    ToolDefinition(
      name: 'app.resolve',
      description:
          'Resolve a friendly app name (e.g. "wa", "toko ijo", "youtube") to a package name. ALWAYS call this first before app.open.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'query': 'string (friendly name to resolve)'},
    ),
    ToolDefinition(
      name: 'app.open',
      description:
          'Open an installed app by exact package name. Use app.resolve first to get the package name.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {'package': 'string (exact package name from app.resolve)'},
    ),
    ToolDefinition(
      name: 'app.list_installed',
      description: 'List all installed launchable apps.',
      risk: 'safe',
      requiresConfirmation: false,
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'settings.open',
      description: 'Open Android system settings.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'action': 'string'},
    ),
    ToolDefinition(
      name: 'intent.open_url',
      description: 'Open a URL in the default browser.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {'url': 'string'},
    ),
  ];

  @override
  Future<ToolExecutionResult> dispatch(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) {
    final tools = AppTools();
    switch (request.name) {
      case 'app.resolve':
        return tools.executeResolve(request.args);
      case 'app.open':
        return tools.executeOpen(request.args);
      case 'app.list_installed':
        return tools.executeListInstalled();
      case 'settings.open':
        return tools.executeOpenSettings(request.args);
      case 'intent.open_url':
        return tools.executeOpenUrl(request.args);
      default:
        return Future.value(
          ToolExecutionResult(
            success: false,
            toolName: request.name,
            error: 'AppModulePlugin cannot handle ${request.name}',
          ),
        );
    }
  }
}
