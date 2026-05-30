import '../../agents/data/agent_repository.dart';
import '../../chat/data/chat_history_service.dart';
import '../../chat/data/unread_service.dart';
import '../../../services/agent_runtime/module_plugin.dart';
import '../../../services/agent_runtime/runtime_models.dart';

class ChatModulePlugin extends ModulePlugin {
  const ChatModulePlugin();

  @override
  String get moduleId => 'chat';

  @override
  String get catalogGroup => 'chat';

  @override
  List<String> get capabilityHints => const [
    'chat',
    'message',
    'send to chat',
    'chat bubble',
    'digest',
    'report',
  ];

  @override
  List<ToolDefinition> get toolDefinitions => const [
    ToolDefinition(
      name: 'chat.send',
      description:
          'Send a message from the agent into a chat UI as an assistant message. Use when user explicitly asks to "kirim ke chat", "send to chat", or to deliver a markdown-formatted result (summary, digest, report) as a chat bubble rather than just a notification. Content supports full markdown. By default the message lands in the running agent\'s own chat - omit agentId unless the user explicitly names a different agent.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {
        'content': 'string (required, markdown body of the message)',
        'agentId':
            'string (optional, internal agent id only - NOT a display name like "Meow Agent" or "user". Omit to deliver to the current agent\'s chat, which is the right default in workflows.)',
      },
    ),
  ];

  @override
  Future<ToolExecutionResult> dispatch(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) {
    switch (request.name) {
      case 'chat.send':
        return _executeSend(request.args, ctx);
      default:
        return Future.value(
          ToolExecutionResult(
            success: false,
            toolName: request.name,
            error: 'ChatModulePlugin cannot handle ${request.name}',
          ),
        );
    }
  }

  Future<ToolExecutionResult> _executeSend(
    Map<String, dynamic> args,
    ModuleToolContext ctx,
  ) async {
    try {
      final content = (args['content'] ?? '').toString().trim();
      if (content.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'chat.send',
          error: 'Missing required field: content.',
        );
      }

      final targetAgentId = _resolveTargetAgentId(args, ctx);
      if (targetAgentId == null || targetAgentId.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'chat.send',
          error: 'No target agent resolved for chat.send.',
        );
      }

      final service = ChatHistoryService();
      final messageId = await service.addMessage(
        targetAgentId,
        ChatMessage(role: 'assistant', content: content),
      );

      await UnreadService.instance.increment(targetAgentId);

      return ToolExecutionResult(
        success: true,
        toolName: 'chat.send',
        data: {
          'agentId': targetAgentId,
          'messageId': messageId,
          'length': content.length,
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'chat.send',
        error: e.toString(),
      );
    }
  }

  String? _resolveTargetAgentId(
    Map<String, dynamic> args,
    ModuleToolContext ctx,
  ) {
    final rawTarget = (args['agentId'] ?? args['agent'] ?? args['target'] ?? '')
        .toString()
        .trim();
    final repository = ctx.agentRepository;
    if (rawTarget.isNotEmpty && repository != null) {
      final resolved = _resolveFromRepository(rawTarget, repository);
      if (resolved != null) return resolved;
    }
    return ctx.agentId.isNotEmpty ? ctx.agentId : null;
  }

  String? _resolveFromRepository(String rawTarget, AgentRepository repository) {
    final all = repository.loadAll();
    final byId = all.where((a) => a.id == rawTarget).firstOrNull;
    if (byId != null) return byId.id;

    final lower = rawTarget.toLowerCase();
    final byName = all
        .where((a) => a.name.trim().toLowerCase() == lower)
        .firstOrNull;
    return byName?.id;
  }
}
