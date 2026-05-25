import '../../features/settings/data/app_language_provider.dart';
import 'pending_action.dart';
import 'runtime_models.dart';

/// Builds prompt strings for each phase of the runtime loop.
class PromptTemplates {
  /// Analyze user intent.
  static String analyzePrompt({
    required String userMessage,
    required AgentWorkspace workspace,
    required List<String> availableTools,
    required String languageCode,
    List<Map<String, String>> recentMessages = const [],
    PendingAction? pendingAction,
    String recentToolMemory = '',
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

    final memoryBlock = recentToolMemory.isNotEmpty
        ? '''

Recent tool results (from prior turns, oldest first — use these to resolve references like "yang itu", "yang tadi", "note terakhir", "pakai id yang tadi"):
$recentToolMemory

When the user references something ambiguous, prefer matching against the LAST relevant entry above. Reuse IDs (noteId, package, notificationId, etc.) from these results instead of asking again.'''
        : '';

    return '''You are an AI agent runtime analyzer running on an Android device.

${_systemRules(languageCode)}

Identity context (from SOUL.md — user-editable):
${workspace.soul}

Available tools:
${availableTools.map((t) => '- $t').join('\n')}

Recent conversation:
$historyBlock
$pendingBlock$memoryBlock

User message: "$userMessage"

Rules for requires_tools:
- Set true if user wants to: open an app, open a URL, read/write clipboard, open settings, list apps
- Set true for phrases like: "buka [app]", "open [app]", "launch [app]", "buka [url]", "pergi ke [url]"
- Set false if user is chatting, asking questions, or requesting information only
- When in doubt and a tool exists that matches the request, set true

Examples that require tools:
- "buka wa" → app.resolve("wa") then app.open(packageName)
- "buka youtube" → app.resolve("youtube") then app.open(packageName)
- "buka toko ijo" → app.resolve("toko ijo") then app.open(packageName)
- "buka google.com" → intent.open_url
- "baca clipboard" → clipboard.read
- "tulis ke clipboard" → clipboard.write
- "buka pengaturan wifi" → settings.open
- "app apa yang terinstall" → app.list_installed

IMPORTANT: For opening apps, ALWAYS use app.resolve FIRST to convert friendly names to package names, THEN use app.open with the resolved package.

Respond with ONLY valid JSON, no markdown, no explanation:

{
  "intent": "short.intent.name",
  "goal": "one sentence describing what user wants",
  "requires_tools": true/false,
  "risk": "safe/sensitive/dangerous",
  "missing_info": []
}''';
  }

  /// System-level behavior rules. Always enforced regardless of SOUL.md content.
  static String _systemRules(String languageCode) {
    final language = languageLabelFromCode(languageCode);
    return '''SYSTEM RULES (always enforced):
- Default response language: $language, unless user explicitly switches.
- Be concise and practical. Avoid exaggerated or futuristic language.
- Ask the user before sensitive or destructive actions.
- Respect enabled permissions and modules. Do not assume capabilities.
- If a tool fails or requires permission, stop and inform the user clearly.
- If the user's identity (Name) in SOUL.md is still a placeholder, politely ask once and offer to fill it in. Do not ask repeatedly.
- When user provides identity info, update only the relevant SOUL.md field — never overwrite unrelated sections.''';
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
    String recentToolMemory = '',
  }) {
    final memoryBlock = recentToolMemory.isNotEmpty
        ? '\nRecent tool results from prior turns (use these IDs/values when user references "yang tadi", "itu", "note terakhir"):\n$recentToolMemory\n'
        : '';
    return '''You are an AI agent tool selector.

Execution plan:
${_jsonString(plan)}

Current step: $currentStep
Previous results (this turn):
${previousResults.isEmpty ? 'None yet.' : previousResults.map(_jsonString).join('\n')}
$memoryBlock
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

CRITICAL RULES for final_response:
- Reply in the SAME language as the user's original request (Indonesian if they used Indonesian).
- NEVER mention internal tool names like "clipboard.write", "app.open", "intent.open_url".
- NEVER say "the X tool executed successfully" or similar technical phrasing.
- Speak naturally as a helpful assistant who just did the task.
- Be concise (1-2 short sentences).
- If the tool succeeded, confirm what was done in human terms (e.g., "Sudah saya tulis ke clipboard." or "WhatsApp sudah dibuka.").
- If it failed, explain what went wrong in plain language and suggest a next step.

Decide what to do next. Respond with ONLY valid JSON, no markdown, no explanation:

If task is complete:
{
  "status": "done",
  "final_response": "natural human reply, no tool names"
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
