import 'prompt_analyze.dart';
import 'prompt_context.dart';
import 'prompt_execute.dart';
import 'prompt_plan.dart';
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

  // ─── System-level (logic with caching stays here) ──────────────────────────

  /// Cache for systemRules — keyed by `language|isWorkflowAutoExecute`.
  static final Map<String, String> _systemRulesCache = {};

  /// System rules always enforced regardless of SOUL.md content.
  static String systemRules(
    String language, {
    bool isWorkflowAutoExecute = false,
  }) {
    final cacheKey = '$language|$isWorkflowAutoExecute';
    final cached = _systemRulesCache[cacheKey];
    if (cached != null) return cached;
    final built = _buildSystemRules(language, isWorkflowAutoExecute);
    _systemRulesCache[cacheKey] = built;
    return built;
  }

  static String _buildSystemRules(String language, bool isWorkflowAutoExecute) {
    if (isWorkflowAutoExecute) {
      return '''SYSTEM RULES (always enforced):
- This run is a scheduled WORKFLOW execution. There is NO user reading this message in real-time.
- Sensitive actions are PRE-APPROVED for this run. Do NOT ask for confirmation; execute the appropriate tool directly.
- Default language: $language. Be concise and practical.
- Respect enabled permissions and modules. Do not assume capabilities.
- If a tool fails or requires permission, stop and report the error clearly. Do not turn it into a question.
- If a module permission blocks an action, report the disabled module/toggle exactly and do not attempt a workaround.
- CAPABILITY BOUNDARY (CRITICAL): Your abilities are STRICTLY limited to the tools listed in your tool schema. If NO tool exists for an action (e.g. sending SMS, making phone calls, opening camera, installing apps), you MUST immediately tell the user you cannot do it. NEVER say "let me try" or "I'll attempt" for actions without a corresponding tool. Being persistent means trying harder with AVAILABLE tools — it does NOT mean hallucinating capabilities that do not exist.
- AMBIGUITY: If a required detail is missing, fail with a clear error message. Do NOT ask the user — there is no user.''';
    }
    return '''SYSTEM RULES (always enforced):
- Default response language: $language. Match the user's language; do not switch unless they ask.
- Be concise and practical. Avoid exaggerated or futuristic language.
- Two DISTINCT situations decide whether you ask the user a question — do not confuse them:
  1. MISSING DETAIL (a required input is absent or ambiguous — time without AM/PM, vague title, unclear target): ASK one short clarifying question in plain text BEFORE calling any tool. Do not guess defaults silently.
  2. SENSITIVE/DESTRUCTIVE ACTION (the detail is complete, but the action has side effects): do NOT ask in plain text. CALL the appropriate tool directly — the runtime renders a confirmation card with approve/cancel buttons. A plain-text "are you sure?" leaves the user no button to press.
- Respect enabled permissions and modules. Do not assume capabilities.
- If a tool fails or requires permission, stop and inform the user clearly.
- If a module permission blocks an action, report the disabled module/toggle exactly and ask the user to enable it first.
- CAPABILITY BOUNDARY (CRITICAL): Your abilities are STRICTLY limited to the tools listed in your tool schema. If NO tool exists for an action (e.g. sending SMS, making phone calls, opening camera, installing apps), you MUST immediately and honestly tell the user you cannot do it. NEVER say "let me try" or "I'll attempt" for actions without a corresponding tool. NEVER list capabilities you do not have tools for. Being persistent means trying harder with AVAILABLE tools — it does NOT mean hallucinating capabilities that do not exist. When listing what you can do, ONLY mention actions backed by real tools in your schema.
- When user provides identity info, update only the relevant SOUL.md field — never overwrite unrelated sections.''';
  }

  // ─── System-level constants (delegated to prompt_system.dart) ──────────────

  static const jsonOnlySystem = promptJsonOnlySystem;
  static const introductionGateRule = promptIntroductionGateRule;

  // ─── Analyzer (delegated to prompt_analyze.dart) ───────────────────────────

  static const analyzeIntro = promptAnalyzeIntro;
  static const systemMarkdownMap = promptSystemMarkdownMap;
  static const analyzeRequiresToolsRules = promptAnalyzeRequiresToolsRules;
  static const analyzeCrossDomainAmbiguityRule =
      promptAnalyzeCrossDomainAmbiguityRule;
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
  static String reviewRulesFor(String language) =>
      promptReviewRulesFor(language);
  static const appAgenticReviewRules = promptAppAgenticReviewRules;
  static const reviewResponseFormat = promptReviewResponseFormat;

  // ─── Context / misc (delegated to prompt_context.dart) ─────────────────────

  static String chatSystemPrompt(String agentName) =>
      promptChatSystemPrompt(agentName);
  static const firstIntroductionRule = promptFirstIntroductionRule;
  static String selfIdentity({
    required String agentName,
    required String agentId,
  }) =>
      promptSelfIdentity(agentName: agentName, agentId: agentId);
  static const compactorSystemPrompt = promptCompactorSystemPrompt;
  static const jsonRepairIntro = promptJsonRepairIntro;
  static const pendingActionInstructions = promptPendingActionInstructions;
  static const memoryInstructions = promptMemoryInstructions;
  static const memoryHeader = promptMemoryHeader;

  // ─── Workflow API Context (delegated to prompt_context.dart) ───────────────

  static String workflowApiContext(List<String> apiNames) =>
      promptWorkflowApiContext(apiNames);

  // ─── Workflow Runner Prompts (delegated to prompt_workflow.dart) ──────────

  static String workflowChainedUserMessage({
    required int stepIndex,
    required int totalSteps,
    required String userInstruction,
  }) =>
      promptChainedUserMessage(
        stepIndex: stepIndex,
        totalSteps: totalSteps,
        userInstruction: userInstruction,
      );

  static String workflowPreviousStepMarker(int stepIndex) =>
      promptPreviousStepMarker(stepIndex);

  static String workflowEarlierStepMarker(int stepNumber) =>
      promptEarlierStepMarker(stepNumber);

  static const workflowTriggerContextWrapper = promptTriggerContextWrapper;
}
