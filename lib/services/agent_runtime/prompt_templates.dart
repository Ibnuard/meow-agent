import 'pending_action.dart';
import 'runtime_models.dart';

/// Builds prompt strings for each phase of the runtime loop.
class PromptTemplates {
  /// Analyze user intent.
  static String analyzePrompt({
    required String userMessage,
    required AgentWorkspace workspace,
    required List<String> availableTools,
    List<Map<String, String>> recentMessages = const [],
    PendingAction? pendingAction,
  }) {
    final historyBlock = recentMessages.isNotEmpty
        ? recentMessages
            .map((m) => '${m['role']}: ${m['content']}')
            .join('\n')
        : 'No prior conversation.';

    final pendingBlock = pendingAction != null
        ? '''
PENDING ACTION (user was previously asked to confirm this):
Tool: ${pendingAction.toolName}
Args: ${pendingAction.toolArgs}
Summary: ${pendingAction.userFacingSummary}
Preview result: ${pendingAction.previewText}

If user refers to "hasilnya", "itu", "yang tadi", "disini" — they mean this pending action.
If user asks to preview, show, or just see the result — set requires_tools to false and answer using the preview.
If user rejects — set requires_tools to false.
If user confirms — set requires_tools to true.'''
        : '';

    return '''You are an AI agent runtime analyzer.

Your identity:
${workspace.soul}

Available tools:
${availableTools.map((t) => '- $t').join('\n')}

Recent conversation:
$historyBlock
$pendingBlock

User message: "$userMessage"

Analyze the user's intent and respond with ONLY valid JSON, no markdown, no explanation.
If the user is just chatting, asking questions, or continuing a conversation, set requires_tools to false.
Only set requires_tools to true if the user explicitly wants to use a system tool (clipboard, file, etc).

{
  "intent": "short.intent.name",
  "goal": "one sentence describing what user wants",
  "requires_tools": true/false,
  "risk": "safe/sensitive/dangerous",
  "missing_info": []
}''';
  }

  /// Create execution plan.
  static String planPrompt({
    required Map<String, dynamic> analysis,
    required List<String> availableTools,
  }) {
    return '''You are an AI agent planner.

Analysis result:
${_jsonString(analysis)}

Available tools:
${availableTools.map((t) => '- $t').join('\n')}

Create a short execution plan (max 5 steps). Respond with ONLY valid JSON, no markdown, no explanation:

{
  "steps": [
    {
      "id": 1,
      "description": "what to do",
      "tool": "tool.name or null if no tool needed"
    }
  ]
}''';
  }

  /// Select next tool or decide final response.
  static String selectToolPrompt({
    required Map<String, dynamic> plan,
    required int currentStep,
    required List<Map<String, dynamic>> previousResults,
    required List<String> availableTools,
  }) {
    return '''You are an AI agent tool selector.

Execution plan:
${_jsonString(plan)}

Current step: $currentStep
Previous results:
${previousResults.isEmpty ? 'None yet.' : previousResults.map(_jsonString).join('\n')}

Available tools:
${availableTools.map((t) => '- $t').join('\n')}

Decide the next action. Respond with ONLY valid JSON, no markdown, no explanation.

If a tool is needed:
{
  "status": "tool_required",
  "tool": {
    "name": "tool.name",
    "args": {},
    "risk": "safe/sensitive",
    "requires_confirmation": true/false
  },
  "reason": "why this tool is needed"
}

If the task is complete and you can give a final answer:
{
  "status": "done",
  "final_response": "your response to the user"
}

If you need more info from the user:
{
  "status": "ask_user",
  "question": "what you need to know"
}''';
  }

  /// Review tool result and decide next action.
  static String reviewPrompt({
    required ToolExecutionResult result,
    required Map<String, dynamic> plan,
    required int currentStep,
    required String userMessage,
  }) {
    return '''You are an AI agent reviewer.

Original user request: "$userMessage"

Execution plan:
${_jsonString(plan)}

Current step: $currentStep

Tool result:
- Tool: ${result.toolName}
- Success: ${result.success}
- Data: ${result.data}
- Error: ${result.error ?? 'none'}

Decide what to do next. Respond with ONLY valid JSON, no markdown, no explanation:

If task is complete:
{
  "status": "done",
  "final_response": "your final response to the user incorporating the tool results"
}

If more steps needed:
{
  "status": "continue",
  "reason": "why we need to continue"
}

If tool failed and should retry:
{
  "status": "retry",
  "reason": "why retry might work"
}

If you need user input:
{
  "status": "ask_user",
  "question": "what you need"
}

If unrecoverable:
{
  "status": "failed",
  "error": "what went wrong"
}''';
  }

  /// Attempt to repair malformed JSON from LLM.
  static String jsonRepairPrompt(String malformedJson) {
    return '''The following text was supposed to be valid JSON but has errors.
Fix it and return ONLY the corrected valid JSON, nothing else:

$malformedJson''';
  }

  static String _jsonString(Map<String, dynamic> json) {
    return json.entries.map((e) => '  ${e.key}: ${e.value}').join('\n');
  }
}
