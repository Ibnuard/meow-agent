import 'action_map.dart';
import 'goal_tree.dart';
import 'prompt_constants.dart';
import 'runtime_models.dart';

/// Builds prompt strings for each phase of the runtime loop.
class PromptTemplates {
  /// Build a stable context prefix that is byte-identical across all phases
  /// in a single turn (analyze, selectTool, review). When passed as
  /// [LlmJsonCaller.call]'s `stableContext` parameter, the provider can
  /// cache this prefix and reuse it across multi-phase LLM calls.
  ///
  /// Contains: self-identity, soul, and skills — the parts that never change
  /// within a turn. Tool definitions are NOT included here because the
  /// analyze phase doesn't have them (they arrive later after tool narrowing).
  ///
  /// See REVIEWED.md Level 2: Stable Prompt Prefix.
  static String buildStableContext({
    required String soul,
    required String skills,
    String agentName = '',
    String agentId = '',
  }) {
    final selfIdentity = agentName.isEmpty
        ? ''
        : PromptConstants.selfIdentity(agentName: agentName, agentId: agentId);
    final skillsBlock = skills.isEmpty ? '' : '\n$skills\n';
    return '''$selfIdentity
Identity context (user profile stored in database):
$soul
$skillsBlock''';
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
    final selectedSkillContext = (plan['_selected_skill_context'] ?? '')
        .toString()
        .trim();
    final selectedSkillBlock = selectedSkillContext.isEmpty
        ? ''
        : '\nSelected skill context:\n$selectedSkillContext\n';
    return '''${PromptConstants.selectToolIntro}
${agentName.isEmpty ? '' : '\n${PromptConstants.selfIdentity(agentName: agentName, agentId: agentId)}\n'}
${PromptConstants.policyMinimal}
$literalInstructionBlock$vmBlock
${_actionMapBlock(availableTools)}
Execution plan:
${_jsonString(plan)}
$selectedSkillBlock

Current step: $currentStep
Previous results (this turn):
${_formatPreviousResults(previousResults)}
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
    final previousResultsBlock =
        '\nPrevious results (this turn):\n'
        '${_formatPreviousResults(previousResults)}\n';
    final selectedSkillContext = (plan['_selected_skill_context'] ?? '')
        .toString()
        .trim();
    final selectedSkillBlock = selectedSkillContext.isEmpty
        ? ''
        : '\nSelected skill context:\n$selectedSkillContext\n';
    return '''${PromptConstants.reviewIntro}
$selfIdentityBlock
${PromptConstants.policyGround}

${PromptConstants.policyRecover}

${PromptConstants.policyVoice}

Original user request: "$userMessage"

Execution plan:
${_jsonString(plan)}
$selectedSkillBlock
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
    return json.entries
        .where((e) => !e.key.startsWith('_'))
        .map((e) => '  ${e.key}: ${e.value}')
        .join('\n');
  }

  /// Render the per-turn previous-results list into a bounded prompt block.
  ///
  /// Without this the accumulated history is re-serialized in full into every
  /// selector and reviewer prompt, growing unbounded up to `maxSteps×3` entries
  /// and inflating tokens (and confusing the model) as a complex task
  /// progresses. Keep the most recent [_fullResultsWindow] entries in full
  /// (the selector/reviewer need their structured data to chain steps), and
  /// compress older entries into one-line summaries — enough to recall what
  /// already happened without re-doing it, without the cost.
  static const int _fullResultsWindow = 4;

  static String _formatPreviousResults(
    List<Map<String, dynamic>> previousResults,
  ) {
    if (previousResults.isEmpty) return 'None yet.';
    if (previousResults.length <= _fullResultsWindow) {
      return previousResults.map(_jsonString).join('\n');
    }
    final older = previousResults.sublist(
      0,
      previousResults.length - _fullResultsWindow,
    );
    final recent = previousResults.sublist(
      previousResults.length - _fullResultsWindow,
    );
    final olderSummary = older.map((e) {
      final step = e['step'] ?? '?';
      final tool = e['tool'] ?? '?';
      final note = (e['note'] ?? '').toString().trim();
      final result = e['result'];
      String outcome;
      if (result is Map) {
        outcome = result.containsKey('error')
            ? 'failed'
            : (result['success'] == false ? 'failed' : 'ok');
      } else {
        outcome = note.isEmpty ? 'ok' : 'ok';
      }
      return '  - step $step: $tool → $outcome'
          '${note.isEmpty ? '' : ' ($note)'}';
    }).join('\n');
    return 'Earlier (compressed):\n$olderSummary\n\nLatest:\n${recent.map(_jsonString).join('\n')}';
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
      final firstLine = def
          .split('\n')
          .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
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
