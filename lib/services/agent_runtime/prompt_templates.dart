import '../../features/settings/data/app_language_provider.dart';
import 'action_map.dart';
import 'goal_tree.dart';
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
    bool isWorkflowAutoExecute = false,
    String activeTaskContext = '',
    String agentName = '',
    String agentId = '',
  }) {
    final historyBlock = recentMessages.isNotEmpty
        ? recentMessages.map((m) => '${m['role']}: ${m['content']}').join('\n')
        : 'No prior conversation.';

    final pendingBlock = pendingAction != null
        ? '\nPENDING ACTION (user was previously asked to confirm this):\n'
              'Tool: ${pendingAction.toolName}\n'
              'Args: ${pendingAction.toolArgs}\n'
              'Summary: ${pendingAction.userFacingSummary}\n'
              'Debug: ${pendingAction.debugDescriptor}\n\n'
              '${PromptConstants.pendingActionInstructions}\n'
              'If the user asks for a different action instead of confirming/rejecting/previewing this pending action, set task_relation="new_task" and analyze the new request on its own.'
        : '';

    final memoryBlock = recentToolMemory.isNotEmpty
        ? '\n\n${PromptConstants.memoryHeader}\n$recentToolMemory\n\n'
              '${PromptConstants.memoryInstructions}'
        : '';

    final sourceModeBlock = isWorkflowAutoExecute
        ? '\n\nWORKFLOW EXECUTION MODE:\n'
              '- This run is a scheduled workflow. There is no user available for real-time interaction.\n'
              '- The user pre-approved sensitive actions when creating this workflow.\n'
              '- ALWAYS set requires_tools=true if the prompt describes an action (open app, send intent, etc.).\n'
              '- NEVER set requires_tools=false to ask for permission — execute directly via the appropriate tool.\n'
              '- If a required detail is genuinely missing, set requires_tools=false and put the failure reason in missing_info, but do NOT phrase it as a confirmation question.\n'
        : '';

    final activeTaskBlock = activeTaskContext.isNotEmpty
        ? '\n\nACTIVE TASK CONTEXT (a task is already in flight for this agent):\n'
              '$activeTaskContext\n\n'
              'Use this context to set task_relation before anything else. If the new user message is a standalone request or unrelated action, set task_relation="new_task". '
              'If it edits or refines the same goal (a parameter, name, or scope change), set task_relation="revision". '
              'If it just answers a clarify/affirms ("ok", "yes", "lanjut"), set task_relation="continuation".'
        : '';

    final language = languageLabelFromCode(languageCode);

    final selfIdentityBlock = agentName.isEmpty
        ? ''
        : '\n${PromptConstants.selfIdentity(agentName: agentName, agentId: agentId)}\n';

    final vmBlock = PromptConstants.toolsIncludeVm(availableTools)
        ? '\n${PromptConstants.vmWorkflowRules}\n'
        : '';

    return '''${PromptConstants.analyzeIntro}

${PromptConstants.systemRules(language, isWorkflowAutoExecute: isWorkflowAutoExecute)}

${PromptConstants.systemMarkdownMap}
$selfIdentityBlock$vmBlock
Identity context (user profile stored in database):
${workspace.soul}

Available tools:
${availableTools.join('\n')}

Recent conversation:
$historyBlock
$pendingBlock$memoryBlock$sourceModeBlock$activeTaskBlock

User message: "$userMessage"

${PromptConstants.policyAsk}

${PromptConstants.analyzeRequiresToolsRules}

${PromptConstants.analyzeCrossDomainAmbiguityRule}

${PromptConstants.analyzeExamples}

${PromptConstants.analyzeResponseFormat}''';
  }

  /// Create execution plan.
  static String planPrompt({
    required Map<String, dynamic> analysis,
    required List<String> availableTools,
    List<String> resolvedTargetLabels = const [],
  }) {
    final resolvedBlock = resolvedTargetLabels.isEmpty
        ? ''
        : '\nResolved targets (snapshot-matched, authoritative):\n'
              '${resolvedTargetLabels.map((l) => '- $l').join('\n')}\n'
              'Emit ONE subgoal per resolved target above. Use these labels '
              'verbatim. Do NOT invent additional targets.\n';
    // VM workflow rules (ext4 vs FUSE, scaffolder cwd) — the planner builds the
    // goal tree and must know that scaffold/install/serve steps belong inside
    // agent_workspace_dir, not /root or files.create. Without this the plan can
    // route a "build a Vite project" task through the wrong filesystem and the
    // executor can't recover.
    final vmBlock = PromptConstants.toolsIncludeVm(availableTools)
        ? '\n${PromptConstants.vmWorkflowRules}\n'
        : '';
    return '''${PromptConstants.planIntro}
$vmBlock
Analysis result:
${_jsonString(analysis)}
$resolvedBlock
Available tools:
${availableTools.join('\n')}

${PromptConstants.planResponseFormat}''';
  }

  /// Select next tool or decide final response.
  static String selectToolPrompt({
    required Map<String, dynamic> plan,
    required int currentStep,
    required List<Map<String, dynamic>> previousResults,
    required List<String> availableTools,
    String userMessage = '',
    String recentToolMemory = '',
    bool isWorkflowAutoExecute = false,
    GoalTree? goalTree,
    List<Map<String, String>> recentMessages = const [],
    String agentName = '',
    String agentId = '',
  }) {
    final memoryBlock = recentToolMemory.isNotEmpty
        ? '\n${PromptConstants.selectToolMemoryHeader}\n$recentToolMemory\n'
        : '';
    final sourceModeBlock = isWorkflowAutoExecute
        ? '\nWORKFLOW EXECUTION MODE:\n'
              '- This run is a scheduled workflow. There is no user available for real-time interaction.\n'
              '- The user pre-approved sensitive actions when creating this workflow.\n'
              '- Do NOT return status=done with text asking for permission or confirmation.\n'
              '- If the plan step needs a tool and arguments are clear, return status=tool_required.\n'
              '- Set requires_confirmation=false in the tool JSON — runtime approval is already granted.\n'
        : '';
    final goalBlock = goalTree == null || goalTree.isEmpty
        ? ''
        : '\nGoal tree state:\n${goalTree.toCompactString()}\n'
              'Active subgoal: ${goalTree.nextActionable?.id ?? 'none'} '
              '— ${goalTree.nextActionable?.label ?? 'all subgoals are terminal'}\n'
              'Pick the tool that advances the active subgoal. If all subgoals are terminal, return status=done.\n';
    // Conversation history block. Critical for chained workflows: the previous
    // step's output arrives here as the most recent assistant turn. When this
    // step's instruction says "send / save / forward the result", the tool
    // arguments (e.g. chat.send content) MUST be drawn from this history —
    // never invented. Without this block the selector hallucinates plausible
    // but wrong content.
    final historyBlock = recentMessages.isEmpty
        ? ''
        : '\nConversation history (CONTEXT ONLY — does NOT prove this task '
              'was executed; use it for argument values like names, content, '
              'or references to "the result", "this", "it"):\n'
              '${recentMessages.map((m) => '${m['role']}: ${m['content']}').join('\n')}\n'
              'When filling a tool argument that carries content (message '
              'body, note text, file body): if the instruction is to '
              'forward / relay / send the data as-is, copy the relevant text '
              'from the history VERBATIM. If the instruction is to respond / '
              'react / reply / comment / compose / rephrase, WRITE NEW '
              'original text that builds on the history (do not just resend '
              'it). In BOTH cases stay grounded — never invent items, names, '
              'numbers, or facts that are not present in the history above.\n';
    // The literal current instruction is the authoritative source of intent.
    // The execution plan and history below are DERIVED and may paraphrase or
    // carry entities from prior turns. When they conflict with the words the
    // user actually just typed, the literal instruction wins — this is what
    // keeps the selector pinned to the current request instead of drifting to
    // a prior-turn entity/goal.
    final literalInstructionBlock = userMessage.trim().isEmpty
        ? ''
        : '\nLITERAL CURRENT INSTRUCTION (authoritative — this is exactly what '
              'the user just asked; prefer the entities, target, and intent '
              'named HERE over anything in the plan, history, or memory below '
              'when they conflict):\n"$userMessage"\n';
    final vmBlock = PromptConstants.toolsIncludeVm(availableTools)
        ? '\n${PromptConstants.vmWorkflowRules}\n'
        : '';
    return '''${PromptConstants.selectToolIntro}
${agentName.isEmpty ? '' : '\n${PromptConstants.selfIdentity(agentName: agentName, agentId: agentId)}\n'}
${PromptConstants.policyMinimal}
$literalInstructionBlock$vmBlock
${_actionMapBlock(availableTools)}
Execution plan:
${_jsonString(plan)}

Current step: $currentStep
Previous results (this turn):
${previousResults.isEmpty ? 'None yet.' : previousResults.map(_jsonString).join('\n')}
$historyBlock$goalBlock$memoryBlock$sourceModeBlock
Available tools:
${availableTools.join('\n')}

${PromptConstants.selectToolResponseFormat}''';
  }

  /// Review tool result and decide next action.
  static String reviewPrompt({
    required ToolExecutionResult result,
    required Map<String, dynamic> plan,
    required int currentStep,
    required String userMessage,
    List<Map<String, dynamic>> previousResults = const [],
    String language = 'English',
    GoalTree? goalTree,
    List<Map<String, String>> recentMessages = const [],
    String agentName = '',
    String agentId = '',
  }) {
    final selfIdentityBlock = agentName.isEmpty
        ? ''
        : '\n${PromptConstants.selfIdentity(agentName: agentName, agentId: agentId)}\n';
    final goalBlock = goalTree == null || goalTree.isEmpty
        ? ''
        : '\nGoal tree state (BEFORE this review):\n${goalTree.toCompactString()}\n'
              'Active subgoal: ${goalTree.nextActionable?.id ?? 'none'}\n'
              'You MUST emit "subgoal_update" for the active subgoal. '
              'Only return status=done when every subgoal is terminal and every completion criterion is satisfied.\n';
    final historyBlock = recentMessages.isEmpty
        ? ''
        : '\nConversation history (authoritative data — when writing any '
              'final_response or summary, ground it strictly on this; do NOT '
              'invent items, names, numbers, or jokes not present here):\n'
              '${recentMessages.map((m) => '${m['role']}: ${m['content']}').join('\n')}\n';
    final previousResultsBlock = '\nPrevious results (this turn):\n'
        '${previousResults.isEmpty ? 'None yet.' : previousResults.map(_jsonString).join('\n')}\n';
    return '''${PromptConstants.reviewIntro}
$selfIdentityBlock
${PromptConstants.policyGround}

${PromptConstants.policyRecover}

${PromptConstants.policyVoice}

Original user request: "$userMessage"

Execution plan:
${_jsonString(plan)}
$previousResultsBlock$historyBlock$goalBlock
Current step: $currentStep

Tool result:
- Tool: ${result.toolName}
- Success: ${result.success}
- Data: ${result.data}
- Error: ${result.error ?? 'none'}

${PromptConstants.reviewRulesFor(language)}

${PromptConstants.reviewResponseFormat}''';
  }

  /// Attempt to repair malformed JSON from LLM.
  static String jsonRepairPrompt(String malformedJson) {
    return '${PromptConstants.jsonRepairIntro}\n\n$malformedJson';
  }

  static String _jsonString(Map<String, dynamic> json) {
    return json.entries.map((e) => '  ${e.key}: ${e.value}').join('\n');
  }

  /// Render the canonical action map block, filtered to only the domains
  /// represented in [availableTools]. Empty string when no relevant entries
  /// — caller must handle the empty case (the prompt context handles it
  /// gracefully because the policy text refers to "below" but renders nothing).
  ///
  /// Domain is derived from the tool name prefix before the first `.`. Tool
  /// definitions in [availableTools] arrive as multiline strings starting
  /// with the tool name on the first non-empty line.
  static String _actionMapBlock(List<String> availableTools) {
    final domains = <String>{};
    for (final def in availableTools) {
      final firstLine = def.split('\n').firstWhere(
            (l) => l.trim().isNotEmpty,
            orElse: () => '',
          );
      // Tool names look like "system.config.patch" or "app_agent.click".
      // Extract the leading token before the first dot.
      final match = RegExp(r'([a-z_]+)\.').firstMatch(firstLine);
      if (match != null) {
        var domain = match.group(1)!;
        if (domain == 'db') domain = 'database';
        if (domain == 'sqlite') domain = 'system';
        domains.add(domain);
      }
    }
    if (domains.isEmpty) return '';
    return renderForPrompt(domains.toList());
  }
}
