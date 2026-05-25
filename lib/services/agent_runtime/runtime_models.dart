import '../../features/chat/data/chat_history_service.dart';

/// Feature flag for Agent Runtime v1.
const bool enableAgentRuntimeV1 = true;

/// Runtime states for the agentic loop.
enum AgentRuntimeState {
  idle,
  analyzing,
  planning,
  selectingTool,
  waitingConfirmation,
  executingTool,
  reviewing,
  askingUser,
  done,
  failed,
}

/// Where a runtime request originated from.
///
/// Used by prompt builders and runtime guards to know whether a real user is
/// reading the response (chat) or whether the run is a background automation
/// without a user in the loop (workflow).
enum RequestSource {
  chat,
  workflow,
}

/// Request to run the agent runtime.
class AgentRuntimeRequest {
  const AgentRuntimeRequest({
    required this.agentId,
    required this.userMessage,
    this.agentName = '',
    this.recentMessages = const [],
    this.metadata = const {},
    this.source = RequestSource.chat,
  });

  final String agentId;
  final String agentName;
  final String userMessage;
  final List<ChatMessage> recentMessages;
  final Map<String, dynamic> metadata;
  final RequestSource source;
}

/// Response from the agent runtime.
class AgentRuntimeResponse {
  const AgentRuntimeResponse({
    required this.finalMessage,
    required this.success,
    required this.state,
    this.events = const [],
    this.pendingTool,
    this.pendingToolArgs,
    this.actions = const [],
  });

  final String finalMessage;
  final bool success;
  final AgentRuntimeState state;
  final List<RuntimeEvent> events;
  /// Tool name awaiting confirmation (only set when state == waitingConfirmation).
  final String? pendingTool;
  /// Tool args awaiting confirmation.
  final Map<String, dynamic>? pendingToolArgs;
  /// Optional contextual action buttons to render after the final message.
  final List<ResultAction> actions;
}

/// A single event logged during runtime execution.
class RuntimeEvent {
  RuntimeEvent({
    required this.type,
    required this.message,
    this.data,
  })  : id = DateTime.now().microsecondsSinceEpoch.toString(),
        createdAt = DateTime.now();

  final String id;
  final DateTime createdAt;
  final String type; // state_change, llm_decision, tool_call, tool_result, error
  final String message;
  final Map<String, dynamic>? data;
}

/// A tool call requested by the LLM.
class ToolCallRequest {
  const ToolCallRequest({
    required this.name,
    this.args = const {},
    required this.risk,
    required this.requiresConfirmation,
  });

  final String name;
  final Map<String, dynamic> args;
  final String risk; // safe, sensitive, dangerous
  final bool requiresConfirmation;

  factory ToolCallRequest.fromJson(Map<String, dynamic> json) {
    return ToolCallRequest(
      name: json['name'] as String? ?? '',
      args: (json['args'] as Map<String, dynamic>?) ?? {},
      risk: json['risk'] as String? ?? 'safe',
      requiresConfirmation: json['requires_confirmation'] as bool? ?? false,
    );
  }
}

/// A user-facing action button shown after a tool result.
/// Used to deep-link to relevant screens (e.g., open calendar after creating event).
class ResultAction {
  const ResultAction({
    required this.label,
    required this.labelId,
    required this.icon,
    required this.type,
    required this.target,
    this.params = const {},
  });

  /// English label.
  final String label;

  /// Indonesian label.
  final String labelId;

  /// Material icon name (e.g., 'calendar_month_rounded').
  final String icon;

  /// Action type: 'navigate' | 'open_folder' | 'open_url'.
  final String type;

  /// Route path or URI.
  final String target;

  /// Optional params for the action.
  final Map<String, dynamic> params;

  Map<String, dynamic> toJson() => {
        'label': label,
        'labelId': labelId,
        'icon': icon,
        'type': type,
        'target': target,
        'params': params,
      };

  factory ResultAction.fromJson(Map<String, dynamic> json) => ResultAction(
        label: json['label'] as String? ?? '',
        labelId: json['labelId'] as String? ?? '',
        icon: json['icon'] as String? ?? '',
        type: json['type'] as String? ?? 'navigate',
        target: json['target'] as String? ?? '',
        params: (json['params'] as Map<String, dynamic>?) ?? const {},
      );
}

/// Result of a tool execution.
class ToolExecutionResult {
  const ToolExecutionResult({
    required this.success,
    required this.toolName,
    this.data,
    this.error,
    this.actions = const [],
  });

  final bool success;
  final String toolName;
  final Map<String, dynamic>? data;
  final String? error;

  /// Optional contextual action buttons rendered after the result.
  final List<ResultAction> actions;
}

/// Registered tool definition with metadata.
class ToolDefinition {
  const ToolDefinition({
    required this.name,
    required this.description,
    required this.risk,
    required this.requiresConfirmation,
    this.inputSchema = const {},
  });

  final String name;
  final String description;
  final String risk;
  final bool requiresConfirmation;
  final Map<String, String> inputSchema;
}

/// Agent workspace files loaded from storage.
class AgentWorkspace {
  const AgentWorkspace({
    this.soul = '',
    this.memory = '',
    this.skills = '',
    this.heartbeat = '',
  });

  final String soul;
  final String memory;
  final String skills;
  final String heartbeat;
}
