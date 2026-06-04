import '../../../services/agent_runtime/module_plugin.dart';
import '../../../services/agent_runtime/runtime_models.dart';
import 'app_agent_service.dart';

class AppAgentModulePlugin extends ModulePlugin {
  const AppAgentModulePlugin();

  @override
  String get moduleId => 'super_power';

  @override
  String get catalogGroup => 'app_agent';

  @override
  List<String> get capabilityHints => const [
    'app automation',
    'control app',
    'tap',
    'type',
    'scroll',
    'screen',
    'ui',
    'accessibility',
  ];

  @override
  List<ToolDefinition> get toolDefinitions => const [
    ToolDefinition(
      name: 'app_agent.inspect',
      description:
          'Read the current Android screen as a pruned accessibility node tree. '
          'Use this before choosing any app_agent click, set_text, or scroll action. '
          'Nodes include id, class, text, content description, bounds, and flags.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'reason': 'string optional short reason for inspecting the screen',
      },
    ),
    ToolDefinition(
      name: 'app_agent.click',
      description:
          'Click a node from the latest app_agent.inspect result by node_id. '
          'Only use node ids that came from the current screen.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {
        'node_id': 'int node id from app_agent.inspect',
        'reason': 'string why this node should be clicked',
      },
    ),
    ToolDefinition(
      name: 'app_agent.set_text',
      description:
          'Set text into an editable node from the latest app_agent.inspect result. '
          'Use for search boxes, message inputs, and forms.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {
        'node_id': 'int editable node id from app_agent.inspect',
        'text': 'string text to enter',
        'reason': 'string why this text should be entered',
      },
    ),
    ToolDefinition(
      name: 'app_agent.scroll',
      description:
          'Scroll a scrollable node from the latest app_agent.inspect result. '
          'Use direction "down" to see more content below or "up" to go back.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {
        'node_id': 'int scrollable node id from app_agent.inspect',
        'direction': 'string "down" or "up"',
        'reason': 'string why scrolling is needed',
      },
    ),
  ];

  @override
  Future<ToolExecutionResult> dispatch(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) {
    final service = AppAgentService();
    switch (request.name) {
      case 'app_agent.inspect':
        return service.inspect(request.args);
      case 'app_agent.click':
        return service.click(request.args);
      case 'app_agent.set_text':
        return service.setText(request.args);
      case 'app_agent.scroll':
        return service.scroll(request.args);
      default:
        return Future.value(
          ToolExecutionResult(
            success: false,
            toolName: request.name,
            error: 'AppAgentModulePlugin cannot handle ${request.name}',
          ),
        );
    }
  }
}
