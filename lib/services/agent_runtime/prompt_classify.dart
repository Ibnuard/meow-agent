/// Unified classify prompt constants — merges analyze + reflect + plan into
/// a single LLM round-trip (L3 optimization).
///
/// See REVIEWED.md Level 3: Reduce Phase LLM Calls.
library;

import 'prompt_context.dart'
    show promptNarrativeFieldRule, promptNextNarrativeFieldRule;

const promptClassifyIntro =
    'You are an AI agent runtime classifier running on an Android device. '
    'You perform routing, intent analysis, reflection, and planning in one step.';

const promptClassifyRouteRules = '''UNIFIED ROUTING:
- If this is ordinary chat (conversational, creative, explanatory, opinion-based, or general knowledge that does NOT require live app/device/system/database/file state and does NOT ask to mutate anything) → set route="chat", requires_tools=false, and write the full response in direct_response.
- If this needs tools (inspect live/local state, use an attachment, mutate anything, control the device/apps, manage stored data, or answer from Meow Agent runtime state) → set route="agentic", requires_tools=true.
- If unsure → route="agentic". Do not guess that a tool is unnecessary.

Language priority for route="chat":
- If the current user message has a deterministic language, answer in that language.
- If too short or ambiguous, use recent conversation, memory, or identity context when it clearly establishes a language.
- If still ambiguous, use the default response language. Do not infer a language from a very short Latin greeting/token common across languages.
- For route="chat", write the final answer directly in the selected language. Keep it natural and concise. For route="agentic", direct_response must be empty.''';

const promptClassifyAnalyzeRules = '''ANALYZER RULES:
- Set requires_tools=true when the current user message asks to inspect live/local state, use an attachment, mutate anything, control the device/apps, manage stored data, or answer from Meow Agent runtime state.
- Set requires_tools=false only for ordinary chat, creative/opinion/explanatory responses that do not need live/local state, or requests that are missing required details.
- If required details are missing or ambiguous, set requires_tools=false and put one or more short clarification questions in missing_info. Do not guess defaults.
- The current user message takes priority over prior conversation tone/topic. A clear new action is a standalone request unless it is explicitly continuing a pending clarification.
- Continuity applies only when the previous assistant asked for missing details and the current message plausibly fills those details.
- Never silently repeat a completed multi-step task from history. Treat short overlapping follow-ups at face value; ask only when the current message is genuinely ambiguous.
- For multiple explicit targets, emit one subgoal_seed per user-visible outcome. Do not collapse multi-target requests into one goal.
- For collection-population requests, require an explicit item list, count, full-set scope, or unambiguous source before execution. Ask for scope when missing.
- Recognize bulk selectors semantically in any language. For existing collections, set bulk_selector=true and emit a single bulk subgoal seed; runtime expansion happens from live state.
- Bulk selectors do not apply to create operations. If creation scope is unclear, ask for count or entries.
- Select skill ids from the predefined skill index; use selected skill detail in later phases for exact tool contracts.
- Cross-domain routing ambiguity rule (FIRST_ASK_USER — but do NOT be chatty): DEFAULT IS TO ACT ON THE MOST LITERAL USER-SCOPED TARGET. Only pause when there are genuinely 2+ plausible interpretations that lead to DIFFERENT results. If one interpretation clearly dominates, execute it directly and do NOT ask. MUST NOT trigger when one interpretation dominates or the target is explicitly user/device scoped — just act.''';

const promptClassifyReflectRules = '''REFLECTOR RULES:
CORE RESPONSIBILITY:
For every non-trivial request you must decide a strategy that maximizes user trust:
- direct_execute: request is unambiguous and safe. Loop runs without preamble.
- clarify: at least one required slot is missing OR a per-target detail is missing for multi-target tasks OR the target referenced by the user does not exactly match an existing entity (typo). Ask ONE short question covering all gaps.
- auto_resolve: ecosystem impacts exist but can be resolved silently first (e.g. reassign workflow before deleting agent). Emit prep steps.
- block: action is destructive, unresolvable, and would surprise the user.

SLOT EXTRACTION RULES:
- Read each tool's description and arg schema. Identify the slots that materially shape user-visible outcome.
- For multi-target requests, treat per-target detail as a slot.
- Do NOT invent defaults. Do NOT copy persona/style/configuration from prior turns unless the user explicitly references it.
- A slot is "filled" only when the user gave it explicitly OR there is a sensible non-creative default the tool itself documents.

EXISTENCE & TYPO RULES:
- For operations that target an EXISTING snapshot-backed entity (agents, workflows, providers, modules), the target name MUST exactly match an entity in the ecosystem snapshot before execution.
- If no exact match exists, do NOT pick the closest one silently. Use strategy=clarify for near-matches, strategy=block for no plausible match.
- File paths, notes, calendar items, and app/package targets are NOT ecosystem snapshot entities.
- Path-like targets MUST use entity_type "file" even when the path contains an agent name.

ECOSYSTEM AWARENESS:
- Use the snapshot to detect cross-references. Deleting an agent referenced by a workflow → auto_resolve with reassign or clarify.
- Read-only operations must NOT emit destructive/update impacts.

BULK SELECTOR PROTOCOL:
- A "bulk quantifier" is any word/phrase, IN ANY LANGUAGE, that means "all/every/each" of an existing entity collection.
- For whole-collection: emit ONE seed target with entity_label="all", selector={"scope":"all"}.
- For filtered-by-pattern: emit ONE seed target with a predicate selector: {"scope":"predicate","field":"name","op":"ends_with|starts_with|contains|equals|regex","value":"<pattern>","case_sensitive":false}.
- Bulk/predicate selectors NEVER apply to create.

TARGET GRAPH:
- Emit targets: one per concrete entity acted on. Group under subgoal_id.
- operation MUST be English enum: create, delete, update, rename, toggle, read, list, open, respond, unknown.
- entity_type MUST be English enum: agent, workflow, provider, module, note, file, calendar_event, app, screen, message, unknown.
- For existing entities, copy entity_id and entity_label exactly from the snapshot when available.
- Every impact MUST include source_target_id pointing to the target/subgoal that causes it.

SELF-TARGET BINDING:
- When the user's CURRENT message refers to THIS agent with a first/second-person reference ("you", "your personality", "this agent") and the operation is a READ, emit target with entity_type="agent", operation="read", entity_label="current_agent".
- Do NOT copy an agent name from EARLIER turns into the current target.
- Only emit a DIFFERENT agent's name when the user names that agent in the CURRENT message.

ANALYZER DECISION BINDING:
- If requires_tools=true and subgoal_seeds are present, the request IS an action request — DO NOT downgrade it to chat.
- If requires_tools=true, use direct_execute or auto_resolve — NEVER clarify/block just because the tone is friendly.
- Your goal_tree main_goal MUST reflect the analyzer's goal, not the conversation tone.''';

const promptClassifyPlanRules = '''PLANNER RULES:
- One subgoal per user-visible outcome. Multi-target requests MUST emit one subgoal per target.
- For collection-population, emit ONE subgoal per row/item with an exact completion criterion for the requested total.
- For existing-entity work, include a validation/list/resolve subgoal before acting when the user gave a partial name, nickname, typo, or ambiguous target.
- For information requests that need a tool, include both the retrieval/validation outcome and the final answer outcome.
- For the final answer outcome, set required_slots {"_operation":"respond"} and leave missing_slots empty.
- ids must be short, stable, unique within the tree (e.g. sg1, sg2).
- Every actionable subgoal MUST include required_slots._operation using an English structural enum (create, update, delete, read, list, search, open, send, respond).
- required_slots also carries what the subgoal needs to be executable. Other than _operation, omit slots that are not applicable.
- missing_slots lists slot keys still unknown. Empty means subgoal is ready to execute.
- Use status="pending" for all subgoals at planning time.
- completion_criteria are short, verifiable conditions.
- APP AGENTIC RETURN RULE: When the plan involves opening an external app AND then delivering a result, ALWAYS include a final subgoal to return to Meow Agent via system.rtb.
- DELIVERY SUBGOALS: When the user explicitly asks to send/deliver the result as a message, include a dedicated subgoal for chat.send.
- AUTHORITATIVE TARGETS: If "Resolved targets" are provided, those are concrete entities matched against the live system snapshot. Emit ONE subgoal per resolved target using the target's entity label verbatim.''';

const promptClassifyResponseFormat = '''
Respond with ONLY valid JSON, no markdown, no explanation:

{
  "route": "chat | agentic",
  "direct_response": "filled only when route is chat",
  "intent": "short.intent.name",
  "goal": "one sentence describing what user wants",
  "requires_tools": true,
  "risk": "safe/sensitive/dangerous",
  "detected_language": "ISO 639-1 code",
  "selected_skill_ids": ["meow.skill_id", "..."],
  "tool_groups": ["group enum", "..."],
  "missing_info": ["clarifying question 1"],
  "subgoal_seeds": ["first user-visible outcome", "..."],
  "requested_item_count": null,
  "bulk_selector": false,
  "task_relation": "none | continuation | revision | new_task",
  "strategy": "direct_execute | clarify | auto_resolve | block",
  "targets": [
    {
      "subgoal_id": "sg1",
      "operation": "create | delete | update | rename | toggle | read | list | open | respond | unknown",
      "entity_type": "agent | workflow | provider | module | note | file | calendar_event | app | screen | message | unknown",
      "entity_id": "exact snapshot id when existing target is known",
      "entity_label": "human-readable target name",
      "selector": {"optional": "selector evidence"}
    }
  ],
  "impacts": [
    {
      "entity_type": "agent | workflow | provider | module",
      "entity_id": "...",
      "entity_label": "human-readable name",
      "source_target_id": "subgoal/target id that causes this impact",
      "relation": "short description of why it's affected",
      "severity": "low | medium | high",
      "auto_resolvable": true,
      "resolution_hint": "short hint"
    }
  ],
  "clarify_questions": ["one combined question that covers all missing slots"],
  "block_reason": "string, only when strategy=block",
  "reasoning": "1-2 sentences in English",
  "main_goal": "single sentence summarizing the user's overall goal",
  "completion_criteria": ["observable condition 1", "observable condition 2"],
  "required_capabilities": ["usesUserDatabase", "initializesTables"],
  "subgoals": [
    {
      "id": "sg1",
      "label": "one user-visible outcome",
      "required_slots": {"_operation": "update", "name": "..."},
      "missing_slots": ["persona"],
      "status": "pending",
      "toolHint": "miniapp.read"
    }
  ],
  "narrative": "$promptNarrativeFieldRule Show what you understood and your initial read.",
  "next_narrative": "$promptNextNarrativeFieldRule Describe the immediate execution decision that follows."
}

Rules:
- If route="chat", fill direct_response and leave strategy, targets, impacts, subgoals, completion_criteria empty/null.
- If route="agentic" and missing_info has items, requires_tools MUST be false and strategy MUST be clarify.
- If requires_tools=true, strategy must be direct_execute or auto_resolve (never clarify/block just because tone is friendly).
- If strategy=clarify, clarify_questions MUST contain exactly one short, friendly question in the user's language.
- If strategy=block, block_reason MUST be filled.
- impacts may be empty when nothing in the ecosystem is affected.
- detected_language: ISO 639-1 code of the language the USER wrote in.
- selected_skill_ids: when requires_tools is true, list predefined skill ids. Use only ids from the predefined skill index.
- tool_groups: compatibility fallback. Smallest set from: app, clipboard, device, notification, notes, files, calendar, workflow, system, database, miniapp, chat, communication, attachment, web.
- task_relation: none/continuation/revision/new_task against ACTIVE TASK CONTEXT.
- required_capabilities: list of capability strings the final result MUST have. Use "usesUserDatabase" when user asks for database/DB/persistent storage. Use "initializesTables" when user asks for table creation. Leave empty when no specific capability is required.
- toolHint in subgoals: string representing the exact tool name (e.g. miniapp.read, miniapp.patch) expected to satisfy the subgoal, or null/absent if unknown.
- $promptNarrativeFieldRule
- $promptNextNarrativeFieldRule
- Never include backticks or markdown fences.''';

/// Simplified classify fallback prompt.
///
/// When the full merged classify schema fails to parse (weak models, large
/// JSON, repair failure), retry with THIS minimal schema. It requests only the
/// fields needed to preserve multi-step plan structure: route, goal, requires_tools,
/// and subgoals as a simple list of label strings. The schema is tiny so weak
/// models produce valid JSON reliably, recovering the plan instead of collapsing
/// to a single subgoal (which starves multi-step tasks of execute-loop budget).
///
/// English-only by design (prompt scaffolding rule). The LLM handles the
/// user's language naturally via [detected_language].
String promptClassifySimplifiedFallback({
  required String userMessage,
  required String activeTaskContext,
}) {
  final activeTaskBlock = activeTaskContext.isNotEmpty
      ? '\nACTIVE TASK CONTEXT:\n$activeTaskContext\n'
      : '';
  return '''You are an AI agent runtime classifier. Your previous response could not be parsed. Reply with ONLY a minimal JSON object — no markdown, no explanation, no extra fields:

{
  "route": "chat | agentic",
  "direct_response": "filled only when route is chat, else empty",
  "goal": "one sentence describing what the user wants",
  "requires_tools": true,
  "detected_language": "ISO 639-1 code of the language the user wrote in",
  "task_relation": "none | continuation | revision | new_task",
  "main_goal": "single sentence summarizing the overall goal",
  "subgoals": [
    {"id": "sg1", "label": "one user-visible outcome"},
    {"id": "sg2", "label": "next user-visible outcome"}
  ]
}

Rules:
- route="chat" only for ordinary conversational/creative/explanatory replies that need NO live state and NO mutation. Fill direct_response and leave subgoals empty.
- route="agentic" for anything that inspects live/local state, mutates data, controls the device/apps, or manages stored data. Fill subgoals.
- Split a multi-step request into one subgoal per user-visible outcome (e.g. read code, then patch it). Do NOT collapse multi-step tasks into one subgoal — each subgoal grants the executor more iteration budget.
- task_relation: continuation if continuing an active task, revision if refining the same goal, new_task if unrelated, none otherwise.
- Never include backticks or markdown fences.

USER MESSAGE:
$userMessage$activeTaskBlock''';
}
