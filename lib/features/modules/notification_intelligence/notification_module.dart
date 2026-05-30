import '../../../services/agent_runtime/module_plugin.dart';
import '../../../services/agent_runtime/runtime_models.dart';
import 'notification_tools.dart';

class NotificationModulePlugin extends ModulePlugin {
  const NotificationModulePlugin();

  @override
  String get moduleId => 'notification_intelligence';

  @override
  String get catalogGroup => 'notification';

  @override
  List<String> get capabilityHints => const [
    'notification',
    'notifications',
    'alert',
    'digest',
    'summarize',
    'reply suggestion',
  ];

  @override
  List<ToolDefinition> get toolDefinitions => const [
    ToolDefinition(
      name: 'notification.status',
      description:
          'Check whether notification access is granted. Use this BEFORE other notification.* tools to verify availability.',
      risk: 'safe',
      requiresConfirmation: false,
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'notification.read_recent',
      description:
          'Read the most recent Android notifications from the read-only cache. Returns app name, title, text, timestamp.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {'limit': 'int (optional, default 10, max 100)'},
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'notification.summarize',
      description:
          'Summarize recent notifications grouped by app. USE when user asks "ringkas notifikasi" or "ada notif apa".',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {'limit': 'int (optional, default 25, max 100)'},
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'notification.classify',
      description:
          'Classify which recent notifications look important (urgent wording, mentions, deadlines). Read-only.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {'limit': 'int (optional, default 15, max 100)'},
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'notification.reply_suggestion',
      description:
          'Generate a SUGGESTED reply for a notification. DOES NOT SEND. User must copy or send manually.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {
        'notificationId': 'string (required, id from notification.read_recent)',
        'tone': 'string (optional: casual | formal | friendly. Default casual)',
      },
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'notification.open_app',
      description:
          'Open the source app of a specific notification. Resolves package then uses app.open flow.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'notificationId': 'string (required, id from notification.read_recent)',
      },
    ),
    ToolDefinition(
      name: 'notification.create_local',
      description:
          'Push a local Android notification from the agent to the user. Use for reminders, digests, alerts, or anything that should reach the user even if the app is backgrounded. Style controls importance: silent (low), normal (default), alarm (high + vibration). NOT for chat replies - use chat.send for that.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {
        'title': 'string (required)',
        'body': 'string (required, supports plain text)',
        'style': 'string (optional: silent | normal | alarm. default normal)',
      },
    ),
  ];

  @override
  Future<ToolExecutionResult> dispatch(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) {
    final tools = NotificationTools(moduleRepository: ctx.moduleRepository);
    switch (request.name) {
      case 'notification.status':
        return tools.executeStatus();
      case 'notification.read_recent':
        return tools.executeReadRecent(request.args);
      case 'notification.summarize':
        return tools.executeSummarize(request.args);
      case 'notification.classify':
        return tools.executeClassify(request.args);
      case 'notification.reply_suggestion':
        return tools.executeReplySuggestion(request.args);
      case 'notification.open_app':
        return tools.executeOpenApp(request.args);
      case 'notification.create_local':
        return tools.executeCreateLocal(request.args);
      default:
        return Future.value(
          ToolExecutionResult(
            success: false,
            toolName: request.name,
            error: 'NotificationModulePlugin cannot handle ${request.name}',
          ),
        );
    }
  }
}
