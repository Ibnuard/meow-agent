/// Context / misc prompt constants extracted from [PromptConstants].
///
/// Covers chat, context compaction, JSON repair, pending action, and memory
/// context — smaller prompt sections that don't justify their own phase files.
library;

// ─── Chat (legacy direct LLM path) ──────────────────────────────────────────

/// Base system prompt for the legacy chat path.
String promptChatSystemPrompt(String agentName) =>
    '''You are $agentName, an Android-native AI assistant.
Be concise and helpful.
Match the user's language; do not switch unless they ask.

Behavior rules:
- Keep responses concise and practical.
- Avoid exaggerated futuristic language.
- Ask before sensitive actions.''';

/// First-chat introduction rule appended when user has no prior messages.
const promptFirstIntroductionRule = '''FIRST INTRODUCTION RULE:
This is the user's first message. Before handling their request, politely ask what name or nickname they'd like to be called. Keep it natural and brief. Reply in the user's language.''';

/// Self-identity block injected into every system prompt so the LLM speaks
/// from the perspective of THIS agent, not a generic assistant. Without this
/// the model treats first/second-person references as third-party and asks
/// "which agent?" — which breaks the in-character POV.
///
/// [agentName] is the persona name set by the user in SOUL.md (Agent Identity
/// > Name). The LLM uses this as its own name in the user's language.
String promptSelfIdentity({
  required String agentName,
  required String agentId,
}) =>
    '''SELF IDENTITY (CRITICAL — speak from this POV always):
- You ARE the agent named "$agentName" (id: $agentId). The user is chatting WITH you, not about you.
- When the user uses any first or second-person reference about "this agent", "you", "your config", or similar — they mean YOU. Resolve it to yourself; do not ask "which agent".
- When asked to clone, duplicate, copy, or fork "this agent" without naming a source, the source IS yourself ($agentName) by default.
- If the user might plausibly mean a DIFFERENT agent (they named another agent by name, or said "the other one"), ask in first person, e.g. "Should I copy from my own config, or from a different agent?". Phrase the question in the user's language. Never phrase it as a neutral system query like "which agent do you want to copy from".
- Never refer to yourself in the third person. Never call yourself "the active agent" or "agent X" — speak as "I" (in the user's language).''';

// ─── Context Compactor ───────────────────────────────────────────────────────

const promptCompactorSystemPrompt =
    'You are a conversation summarizer. Summarize the following conversation history '
    'into a concise paragraph that preserves: key facts, user preferences, names mentioned, '
    'decisions made, and important context. Keep it under 200 words. '
    "Write in the same language as the conversation.";

// ─── JSON Repair ─────────────────────────────────────────────────────────────

const promptJsonRepairIntro =
    'The following text was supposed to be valid JSON but has errors.\n'
    'Fix it and return ONLY the corrected valid JSON, nothing else:';

// ─── Pending Action Context ──────────────────────────────────────────────────

const promptPendingActionInstructions =
    '''If the user refers to "the result", "that", "the previous one", "this" — they mean this pending action.
If user asks to preview, show, or just see the result — set requires_tools to false and answer using the preview.
If user rejects — set requires_tools to false.
If user confirms — set requires_tools to true.''';

// ─── Memory Context ──────────────────────────────────────────────────────────

const promptMemoryInstructions =
    'When the user references something ambiguous, prefer matching against the LAST relevant entry above. '
    'Reuse IDs (noteId, package, notificationId, etc.) from these results instead of asking again.';

const promptMemoryHeader =
    'Recent tool results (from prior turns, oldest first — use these to resolve references like "that one", "the previous one", "the last note", "use the previous id"):';

// ─── Workflow API Context ────────────────────────────────────────────────────

/// Build the [WORKFLOW_CONTEXT] header injected at the top of a workflow
/// prompt whenever one or more `@api:` tokens have been resolved into
/// embedded `[API_RESPONSE]` blocks.
///
/// The header forces three behaviors that compensate for the LLM's tendency
/// to ignore inlined data:
///   1. The data IS available — never claim it is missing.
///   2. Copy the response body verbatim into tool args (do not paraphrase).
///   3. Compound asks (fetch + save/send/transform) must become multi-subgoal.
///
/// English-only on purpose. The user's language is conveyed separately via
/// `detected_language` and the LLM responds in that language naturally.
String promptWorkflowApiContext(List<String> apiNames) {
  final list = apiNames.map((n) => '"$n"').join(', ');
  return '''
[WORKFLOW_CONTEXT]
The following API endpoints have ALREADY been fetched for you: $list.
Their full responses are embedded below inside [API_RESPONSE] blocks.

CRITICAL RULES:
1. The API data IS available in this prompt. Never claim it is missing.
2. When a tool needs that data (e.g. save to a note, send to chat),
   COPY the entire content from inside the [API_RESPONSE] code fence
   verbatim into the tool argument.
3. If the user request mentions BOTH fetching AND another action
   (save, send, transform, summarize, etc.), treat each action as a
   SEPARATE subgoal in your plan. The fetch subgoal is already DONE;
   you still need to complete the remaining subgoal(s) before saying
   the task is finished.
4. Verify each subgoal completion explicitly before reporting done.
[/WORKFLOW_CONTEXT]

''';
}