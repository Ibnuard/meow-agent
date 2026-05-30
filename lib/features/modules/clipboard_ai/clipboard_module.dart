import '../../../services/agent_runtime/module_plugin.dart';
import '../../../services/agent_runtime/runtime_models.dart';
import 'clipboard_tools.dart';

class ClipboardModulePlugin extends ModulePlugin {
  const ClipboardModulePlugin();

  @override
  String get moduleId => 'clipboard_ai';

  @override
  String get catalogGroup => 'clipboard';

  @override
  List<String> get capabilityHints => const [
    'clipboard',
    'copy',
    'paste',
    'copied text',
  ];

  @override
  List<ToolDefinition> get toolDefinitions => const [
    ToolDefinition(
      name: 'clipboard.read',
      description: 'Read current clipboard text.',
      risk: 'safe',
      requiresConfirmation: false,
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'clipboard.write',
      description: 'Write text to clipboard.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {'text': 'string'},
    ),
  ];

  @override
  Future<ToolExecutionResult> dispatch(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) {
    final tools = ClipboardTools();
    switch (request.name) {
      case 'clipboard.read':
        return tools.executeRead();
      case 'clipboard.write':
        return tools.executeWrite(request.args);
      default:
        return Future.value(
          ToolExecutionResult(
            success: false,
            toolName: request.name,
            error: 'ClipboardModulePlugin cannot handle ${request.name}',
          ),
        );
    }
  }
}
