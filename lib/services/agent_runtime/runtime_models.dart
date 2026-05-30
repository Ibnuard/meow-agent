import 'package:uuid/uuid.dart';

import '../../features/chat/data/chat_history_service.dart';

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

  /// Workflow-only terminal state: a step needed a sensitive/confirmation
  /// action but the workflow's "Allow sensitive actions" toggle was off.
  /// The runner converts this into a step failure that destroys the chain.
  blockedSensitive,
}

/// Where a runtime request originated from.
///
/// Used by prompt builders and runtime guards to know whether a real user is
/// reading the response (chat) or whether the run is a background automation
/// without a user in the loop (workflow).
enum RequestSource { chat, workflow }

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
  RuntimeEvent({required this.type, required this.message, this.data})
    : id = const Uuid().v4(),
      createdAt = DateTime.now();

  final String id;
  final DateTime createdAt;
  final String
  type; // state_change, llm_decision, tool_call, tool_result, error
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
    required this.icon,
    required this.type,
    required this.target,
    this.params = const {},
  });

  /// Label (English canonical form — UI localizes via LanguageRegistry).
  final String label;

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
    'icon': icon,
    'type': type,
    'target': target,
    'params': params,
  };

  factory ResultAction.fromJson(Map<String, dynamic> json) => ResultAction(
    label: json['label'] as String? ?? '',
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
    this.operation = '',
    this.targetEntity = '',
    this.selectorArgs = const [],
    this.policies = const [],
    this.postconditions = const {},
    this.isRetrieval = false,
    this.verificationProbe,
  });

  final String name;
  final String description;
  final String risk;
  final bool requiresConfirmation;
  final Map<String, String> inputSchema;
  final String operation;
  final String targetEntity;
  final List<String> selectorArgs;
  final List<String> policies;
  final Map<String, String> postconditions;

  /// True for read-only / informational tools (read, list, search, status,
  /// summary, classify, etc). Replaces the old hardcoded `_isRetrievalTool`
  /// whitelist in the engine.
  ///
  /// Retrieval tools are EXEMPT from the post-execute mutation verifier and
  /// are also the only ones that may legitimately answer the user from a
  /// single tool call.
  final bool isRetrieval;

  /// Optional spec describing how to verify a mutating tool actually
  /// landed in the ecosystem after execution. Drives the generic
  /// PostExecuteValidator (replacing the agent-only
  /// `_verifyAgentRegistryCompletion`).
  ///
  /// `null` means "no automatic post-execute verification" — typically used
  /// for retrieval tools or tools whose outcome is not snapshot-observable.
  final ToolVerificationProbe? verificationProbe;

  bool get hasRuntimeMetadata =>
      operation.isNotEmpty ||
      targetEntity.isNotEmpty ||
      selectorArgs.isNotEmpty ||
      policies.isNotEmpty ||
      postconditions.isNotEmpty ||
      verificationProbe != null;

  String get runtimeMetadataSummary {
    if (!hasRuntimeMetadata) return '';
    final parts = [
      if (operation.isNotEmpty) 'operation:$operation',
      if (targetEntity.isNotEmpty) 'target:$targetEntity',
      if (selectorArgs.isNotEmpty) 'selectors:${selectorArgs.join("|")}',
      if (policies.isNotEmpty) 'policies:${policies.join("|")}',
      if (postconditions.isNotEmpty)
        'postconditions:${postconditions.entries.map((e) => '${e.key}=${e.value}').join("|")}',
      if (verificationProbe != null) 'verify:${verificationProbe!.kind}',
    ];
    return parts.join(', ');
  }
}

/// Specifies how the runtime should verify a mutating tool's outcome.
///
/// The runtime evaluates the probe AFTER the tool reports success. If the
/// probe fails, the runtime treats the operation as unverified and triggers
/// the recovery flow (re-reflect → re-plan) instead of trusting the LLM.
///
/// This is the "anti-halu" gate: tool said it worked, but did it actually?
class ToolVerificationProbe {
  const ToolVerificationProbe({
    required this.kind,
    this.entityType = '',
    this.expectPresent = true,
    this.selectorArgKey = '',
    this.expectedDataKeys = const [],
  });

  /// Probe kind:
  /// - `snapshot_contains` — rebuild ecosystem snapshot, expect entity present
  /// - `snapshot_absent`   — rebuild snapshot, expect entity absent (delete)
  /// - `tool_result_data`  — trust tool result data has expected shape
  /// - `none`              — no probe (alias for null)
  final String kind;

  /// Snapshot entity type to look up (`agent`, `workflow`, `provider`, ...).
  final String entityType;

  /// True for create/update probes (entity must exist after).
  /// False for delete probes (entity must NOT exist after).
  final bool expectPresent;

  /// Tool arg key whose value is the entity selector (typically a name).
  /// Falls back to `name` / `title` heuristics when empty.
  final String selectorArgKey;

  /// For `tool_result_data` probes: the runtime asserts that every key in
  /// this list exists in `result.data` with a non-null, non-empty value.
  ///
  /// Use this for non-snapshot entities (notes, calendar events, files,
  /// profile fields) where the tool's own result payload is the only
  /// observable proof of mutation. Example: `['noteId']` for notes.create.
  final List<String> expectedDataKeys;

  /// Helper for common create/update verification.
  static const ToolVerificationProbe createOrUpdate = ToolVerificationProbe(
    kind: 'snapshot_contains',
    expectPresent: true,
  );

  /// Helper for common delete verification.
  static const ToolVerificationProbe delete = ToolVerificationProbe(
    kind: 'snapshot_absent',
    expectPresent: false,
  );
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
