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
    ToolDefinition(
      name: 'app_agent.back',
      description:
          'Press the Android back button. Use to dismiss popups, menus, '
          'dialogs, or navigate to the previous screen. Does not require a node_id.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {
        'reason': 'string why back navigation is needed',
      },
    ),
    ToolDefinition(
      name: 'app_agent.find_by_text',
      description:
          'Search the current screen for nodes whose visible text or accessibility '
          'label (desc) matches the query. Returns up to 20 matched nodes with the '
          'same shape as inspect, ready to use with click/set_text. PREFER this '
          'over inspect+manual-scan when looking for a specific named item '
          '(chat name, contact, button label, group, etc).',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'query': 'string text or label to search for (case-insensitive)',
        'mode': 'string optional: "contains" (default) or "exact"',
        'reason': 'string optional why this search is needed',
      },
    ),
    ToolDefinition(
      name: 'app_agent.click_by_text',
      description:
          'Find and click a visible node by text or accessibility label in ONE atomic screen pass. '
          'This is more reliable than find_by_text followed by click because it avoids stale node ids and resolves clickable ancestors internally. '
          'Prefer this for app-generic buttons, tabs, menu items, list items, contacts, channels, videos, and search results when you know the visible label.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {
        'query': 'string visible text or accessibility label to click (case-insensitive)',
        'mode': 'string optional: "contains" (default) or "exact"',
        'reason': 'string optional why this target should be clicked',
      },
    ),
    ToolDefinition(
      name: 'app_agent.key',
      description:
          'Simulate an Android key event via Shizuku. '
          'Use keycode 66 (Enter / IME_ACTION_SEND) to commit typed text — '
          'sends a message, submits a search, or confirms an input. '
          'Also supports 4 (Back), 3 (Home), 24 (VolumeUp), 25 (VolumeDown). '
          'PREFER clicking a visible send/submit/search button first via '
          'find_by_text + click — use key only when no clickable button is '
          'available or when the soft-keyboard IME action is more reliable.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {
        'keycode':
            'int Android keycode. 66 = Enter / Send / IME action. 4 = Back. 3 = Home.',
        'reason': 'string optional reason for the key press',
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
      case 'app_agent.back':
        return service.back(request.args);
      case 'app_agent.find_by_text':
        return service.findByText(request.args);
      case 'app_agent.click_by_text':
        return service.clickByText(request.args);
      case 'app_agent.key':
        return service.key(request.args);
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
