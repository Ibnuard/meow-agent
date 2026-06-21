import 'prompt_analyze.dart';
import 'prompt_context.dart';
import 'prompt_execute.dart';
import 'prompt_plan.dart';
import 'prompt_policy.dart';
import 'prompt_reflect.dart';
import 'prompt_system.dart';
import 'prompt_workflow.dart';

/// Centralized prompt constants for the Meow Agent runtime.
///
/// All LLM prompt strings live in per-phase files for easy discovery.
/// This class provides backward-compatible static accessors that delegate
/// to the split files.
///
/// Phase files:
/// - [prompt_system.dart]  — system-level rules & intro gate
/// - [prompt_analyze.dart] — analyzer (intent, language, tool groups)
/// - [prompt_reflect.dart] — reflector (strategy, goal tree, targets)
/// - [prompt_plan.dart]    — planner (goal tree building)
/// - [prompt_execute.dart] — tool selector & reviewer
/// - [prompt_context.dart] — chat, compactor, repair, pending, memory
class PromptConstants {
  PromptConstants._();

  /// Bump when prompt semantics change materially. Logged with each LLM
  /// decision for A/B traceability across deployments.
  static const String promptVersion = '2026-06-v3';

  // ─── System-level (logic with caching stays here) ──────────────────────────

  /// Cache for systemRules — keyed by `language|isWorkflowAutoExecute`.
  static final Map<String, String> _systemRulesCache = {};

  /// System rules always enforced regardless of agent persona content.
  static String systemRules(String language, {bool isWorkflowAutoExecute = false}) {
    final cacheKey = '$language|$isWorkflowAutoExecute';
    final cached = _systemRulesCache[cacheKey];
    if (cached != null) return cached;
    final built = _buildSystemRules(language, isWorkflowAutoExecute);
    _systemRulesCache[cacheKey] = built;
    return built;
  }

  /// Rules identical across interactive and workflow runs. Extracted once to
  /// avoid drift between the two systemRules variants (was duplicated prose).
  static const String _sharedSystemRules =
      '''- Respect enabled permissions and modules. Do not assume capabilities.
- CAPABILITY BOUNDARY (CRITICAL): Your abilities are STRICTLY limited to the tools listed in your tool schema. If NO tool exists for an action (e.g. sending SMS, making phone calls, opening camera, installing apps), you MUST immediately and honestly tell the user you cannot do it. NEVER say "let me try" or "I'll attempt" for actions without a corresponding tool. NEVER list capabilities you do not have tools for. Being persistent means trying harder with AVAILABLE tools — it does NOT mean hallucinating capabilities that do not exist.
- CONFIG ARCHITECTURE: Configurational state (modules, active selections, user preferences) is managed through the config tool — read config then patch it. Agent and provider CRUD uses dedicated domain tools (agent.create/delete/update, provider.create/delete/update). Never invent config state. The runtime backs up, validates, atomically writes, reloads, and restores from backup if invalid. See CANONICAL ACTION PATHS for which tool owns each entity.
- MINI APPS POLICY: When creating, listing, or updating Mini Apps, present them as native-like custom applications. NEVER mention to the user that they are coded/built using HTML, CSS, JS, or WebViews. Keep the experience and your responses feeling native. Do not use terms like "source code", "web", or "HTML/CSS/JS" when talking to the user. Mini Apps run inside a WebView container on the device and can interact directly with the device features and the User Database (meow_user.db) through the window.meow SDK.
When generating Mini App code:
  * For styling, ALWAYS use Tailwind CSS by including `<script src="https://cdn.tailwindcss.com"></script>` in the `<head>`. Create beautiful, modern UI elements that prioritize the user's design preference (found under Design Preference in the Soul section of their profile); if none is specified, default to a glassmorphism style. The UI elements should match the Meow Agent aesthetic (rounded corners, soft shadows, slate/indigo/cyan/violet/rose color palettes). The host application supports dark mode: you MUST ensure that every Mini App design fully supports dark mode (either by using Tailwind's `dark:` selectors/classes or by implementing a sleek, dark-themed interface by default so that it looks stunning and remains perfectly readable in both light and dark modes).
  * AVOID calling native dialogs or native picker components (such as browser `alert()`, `confirm()`, native `<input type="date">`, or `<input type="time">`). Instead, ALWAYS build custom, highly-polished inline components using Tailwind CSS:
    - Custom styled HTML modal dialogs/banners for alerts and confirmations.
    - Custom inline dropdowns/selection sheets.
    - Custom Tailwind-based date pickers and time pickers.
    This guarantees that the styling, transitions, and theme (dark mode, colors, typography) are completely unified and feel premium without popping up disjointed OS-level prompt dialogs.
  * Utilize the following window.meow JavaScript SDK interfaces to integrate with native features and persist user data:
    * window.meow.db.query(sql, params) -> Promise for custom database SELECT queries.
    * window.meow.db.insert(table, data) -> Promise to insert an object key-value map.
    * window.meow.db.update(table, data, where, whereArgs) -> Promise to update rows.
    * window.meow.db.delete(table, where, whereArgs) -> Promise to delete rows.
    * window.meow.db.execute(sql, params) -> Promise to execute raw SQL (e.g. CREATE TABLE IF NOT EXISTS).
    * window.meow.notes.create(title, content, tags), list(limit), get(id) -> Promise to access notes.
    * window.meow.api.call(apiId, params) -> Promise to invoke registered API Store config.
    * window.meow.haptics.vibrate() -> Trigger light haptic vibration.
    * window.meow.navigation.pop(), push(route) -> Manage screens.
To edit or revise a Mini App, NEVER ask the user to provide the full code or try to write/create it all from scratch. Instead: (1) read the Mini App using `miniapp.read` in range chunks (e.g. lines 1-700, then 701-1400) to locate the target block of interest, (2) analyze the sliced code range, (3) call `miniapp.patch` to replace only the specific line range that needs modification by providing targetContent and replacementContent. This allows editing large codebases incrementally without truncation.''';

  static String _buildSystemRules(String language, bool isWorkflowAutoExecute) {
    if (isWorkflowAutoExecute) {
      return '''SYSTEM RULES (always enforced):
- This run is a scheduled WORKFLOW execution. There is NO user reading this message in real-time.
- Sensitive actions are PRE-APPROVED for this run. Do NOT ask for confirmation; execute the appropriate tool directly.
- Default language: $language. Be concise and practical.
$_sharedSystemRules
- If a tool fails or requires permission, stop and report the error clearly. Do not turn it into a question.
- If a module permission blocks an action, report the disabled module/toggle exactly and do not attempt a workaround.
- AMBIGUITY: If a required detail is missing, fail with a clear error message. Do NOT ask the user — there is no user.''';
    }
    return '''SYSTEM RULES (always enforced):
- Default response language: $language. Match the user's language; do not switch unless they ask.
- Be concise and practical. Avoid exaggerated or futuristic language.
$_sharedSystemRules
- If a tool fails or requires permission, stop and inform the user clearly.
- If a module permission blocks an action, report the disabled module/toggle exactly and ask the user to enable it first.
- ASK vs CONFIRM: a missing/ambiguous required detail → ask one short question in plain text BEFORE any tool (see POLICY.ASK). A complete-but-sensitive action → call the tool directly; the runtime renders the approve/cancel card. Never use a plain-text "are you sure?" for a sensitive action — it leaves no button to press.
- When user provides identity info, update only the relevant identity field — never overwrite unrelated sections.''';
  }

  // ─── System-level constants (delegated to prompt_system.dart) ──────────────

  static const jsonOnlySystem = promptJsonOnlySystem;
  static const introductionGateRule = promptIntroductionGateRule;
  static const vmWorkflowRules = promptVmWorkflowRules;

  /// True when the available-tools list includes any VM module tool, so the
  /// VM workflow rules are worth injecting (they cost ~400 tokens).
  static bool toolsIncludeVm(List<String> availableTools) {
    for (final def in availableTools) {
      if (def.contains('vm.')) return true;
    }
    return false;
  }

  // ─── Policy blocks (delegated to prompt_policy.dart) ───────────────────────

  static const policyAsk = promptPolicyAsk;
  static const policyGround = promptPolicyGround;
  static const policyMinimal = promptPolicyMinimal;
  static const policyRecover = promptPolicyRecover;
  static const policyVoice = promptPolicyVoice;

  // ─── Analyzer (delegated to prompt_analyze.dart) ───────────────────────────

  static const analyzeIntro = promptAnalyzeIntro;
  static const systemMarkdownMap = promptSystemMarkdownMap;
  static const analyzeRequiresToolsRules = promptAnalyzeRequiresToolsRules;
  static const analyzeCrossDomainAmbiguityRule = promptAnalyzeCrossDomainAmbiguityRule;
  static const analyzeExamples = promptAnalyzeExamples;
  static const analyzeResponseFormat = promptAnalyzeResponseFormat;

  // ─── Reflector (delegated to prompt_reflect.dart) ──────────────────────────

  static const reflectIntro = promptReflectIntro;
  static String reflectRules(String language) => promptReflectRules(language);
  static const reflectResponseFormat = promptReflectResponseFormat;

  // ─── Planner (delegated to prompt_plan.dart) ───────────────────────────────

  static const planIntro = promptPlanIntro;
  static const planResponseFormat = promptPlanResponseFormat;

  // ─── Tool Selector (delegated to prompt_execute.dart) ──────────────────────

  static const selectToolIntro = promptSelectToolIntro;
  static const selectToolResponseFormat = promptSelectToolResponseFormat;
  static const selectToolMemoryHeader = promptSelectToolMemoryHeader;

  // ─── Reviewer (delegated to prompt_execute.dart) ───────────────────────────

  static const reviewIntro = promptReviewIntro;
  static String reviewRulesFor(String language) => promptReviewRulesFor(language);
  static const reviewResponseFormat = promptReviewResponseFormat;

  // ─── Context / misc (delegated to prompt_context.dart) ─────────────────────

  static String chatSystemPrompt(String agentName) => promptChatSystemPrompt(agentName);
  static const firstIntroductionRule = promptFirstIntroductionRule;
  static String selfIdentity({required String agentName, required String agentId}) =>
      promptSelfIdentity(agentName: agentName, agentId: agentId);
  static const narrativeFieldRule = promptNarrativeFieldRule;
  static const nextNarrativeFieldRule = promptNextNarrativeFieldRule;
  static String taskSummaryPrompt({
    required String mainGoal,
    required String subgoalsBlock,
    required String languageLabel,
    required String languageCode,
  }) => promptTaskSummary(
    mainGoal: mainGoal,
    subgoalsBlock: subgoalsBlock,
    languageLabel: languageLabel,
    languageCode: languageCode,
  );
  static const toolResultTrust = promptToolResultTrust;
  static const compactorSystemPrompt = promptCompactorSystemPrompt;
  static const jsonRepairIntro = promptJsonRepairIntro;
  static const pendingActionInstructions = promptPendingActionInstructions;
  static const memoryInstructions = promptMemoryInstructions;
  static const memoryHeader = promptMemoryHeader;
  static const memoryExtractionSystem = promptMemoryExtractionSystem;
  static String memoryExtractionUser({required String userMessage, required String toolBlock}) =>
      promptMemoryExtractionUser(userMessage: userMessage, toolBlock: toolBlock);
  static const sessionSummarySystem = promptSessionSummarySystem;
  static String sessionSummaryUser(String transcript) => promptSessionSummaryUser(transcript);

  static String selectRelevantSkills({
    required String userMessage,
    required String skillsListBlock,
  }) =>
      promptSelectRelevantSkills(
        userMessage: userMessage,
        skillsListBlock: skillsListBlock,
      );

  // ─── Workflow API Context (delegated to prompt_context.dart) ───────────────

  static String workflowApiContext(List<String> apiNames) => promptWorkflowApiContext(apiNames);

  // ─── Workflow Runner Prompts (delegated to prompt_workflow.dart) ──────────

  static String workflowChainedUserMessage({
    required int stepIndex,
    required int totalSteps,
    required String userInstruction,
  }) => promptChainedUserMessage(
    stepIndex: stepIndex,
    totalSteps: totalSteps,
    userInstruction: userInstruction,
  );

  static String workflowPreviousStepMarker(int stepIndex) => promptPreviousStepMarker(stepIndex);

  static String workflowEarlierStepMarker(int stepNumber) => promptEarlierStepMarker(stepNumber);

  static const workflowTriggerContextWrapper = promptTriggerContextWrapper;
}
