import '../../features/settings/data/app_language_provider.dart';
import 'pending_action.dart';
import 'prompt_constants.dart';
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
        ? '\nPENDING ACTION (user was previously asked to confirm this):\n'
            'Tool: ${pendingAction.toolName}\n'
            'Args: ${pendingAction.toolArgs}\n'
            'Summary: ${pendingAction.userFacingSummary}\n'
            'Preview result: ${pendingAction.previewText}\n\n'
            '${PromptConstants.pendingActionInstructions}'
        : '';

    final memoryBlock = recentToolMemory.isNotEmpty
        ? '\n\n${PromptConstants.memoryHeader}\n$recentToolMemory\n\n'
            '${PromptConstants.memoryInstructions}'
        : '';

    final language = languageLabelFromCode(languageCode);

    return '''${PromptConstants.analyzeIntro}

${PromptConstants.systemRules(language)}

Identity context (from SOUL.md — user-editable):
${workspace.soul}

Available tools:
${availableTools.map((t) => '- $t').join('\n')}

Recent conversation:
$historyBlock
$pendingBlock$memoryBlock

User message: "$userMessage"

${PromptConstants.analyzeRequiresToolsRules}

${PromptConstants.analyzeExamples}

${PromptConstants.analyzeResponseFormat}''';
  }

  /// Create execution plan.
  static String planPrompt({
    required Map<String, dynamic> analysis,
    required List<String> availableTools,
  }) {
    return '''${PromptConstants.planIntro}

Analysis result:
${_jsonString(analysis)}

Available tools:
${availableTools.map((t) => '- $t').join('\n')}

${PromptConstants.planResponseFormat}''';
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
        ? '\n${PromptConstants.selectToolMemoryHeader}\n$recentToolMemory\n'
        : '';
    return '''${PromptConstants.selectToolIntro}

Execution plan:
${_jsonString(plan)}

Current step: $currentStep
Previous results (this turn):
${previousResults.isEmpty ? 'None yet.' : previousResults.map(_jsonString).join('\n')}
$memoryBlock
Available tools:
${availableTools.map((t) => '- $t').join('\n')}

${PromptConstants.selectToolResponseFormat}''';
  }

  /// Review tool result and decide next action.
  static String reviewPrompt({
    required ToolExecutionResult result,
    required Map<String, dynamic> plan,
    required int currentStep,
    required String userMessage,
  }) {
    return '''${PromptConstants.reviewIntro}

Original user request: "$userMessage"

Execution plan:
${_jsonString(plan)}

Current step: $currentStep

Tool result:
- Tool: ${result.toolName}
- Success: ${result.success}
- Data: ${result.data}
- Error: ${result.error ?? 'none'}

${PromptConstants.reviewRules}

${PromptConstants.reviewResponseFormat}''';
  }

  /// Attempt to repair malformed JSON from LLM.
  static String jsonRepairPrompt(String malformedJson) {
    return '${PromptConstants.jsonRepairIntro}\n\n$malformedJson';
  }

  static String _jsonString(Map<String, dynamic> json) {
    return json.entries.map((e) => '  ${e.key}: ${e.value}').join('\n');
  }
}
