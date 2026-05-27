/// Centralized prompt constants for the Meow Agent runtime.
///
/// All LLM prompt strings live here for easy discovery and editing.
/// Avoid hardcoding prompt text in service/UI files — reference this class instead.
class PromptConstants {
  PromptConstants._();

  // ─── System-level ──────────────────────────────────────────────────────────

  /// JSON-only system message used by planner and executor.
  static const jsonOnlySystem =
      'You are a JSON-only responder. Never use markdown.';

  /// Cache for systemRules — keyed by `language|isWorkflowAutoExecute`.
  /// The string content is identical across turns for the same key, so
  /// rebuilding it repeatedly is wasted work.
  static final Map<String, String> _systemRulesCache = {};

  /// System rules always enforced regardless of SOUL.md content.
  /// Use [language] placeholder for the resolved language label.
  /// When [isWorkflowAutoExecute] is true, the run is a background scheduled
  /// workflow with no user reading the message and pre-approved sensitive
  /// actions — the rules are reworded to make the LLM execute directly.

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
- AMBIGUITY: If a required detail is missing, fail with a clear error message. Do NOT ask the user — there is no user.''';
    }
    return '''SYSTEM RULES (always enforced):
- Default response language: $language. Match the user's language; do not switch unless they ask.
- Be concise and practical. Avoid exaggerated or futuristic language.
- For sensitive or destructive actions, CALL the appropriate tool directly. The runtime will automatically render a confirmation card with approve/cancel buttons. NEVER reply with a confirmation question as plain text — the user has no button to press.
- Respect enabled permissions and modules. Do not assume capabilities.
- If a tool fails or requires permission, stop and inform the user clearly.
- If a module permission blocks an action, report the disabled module/toggle exactly and ask the user to enable it first.
- When user provides identity info, update only the relevant SOUL.md field — never overwrite unrelated sections.
- AMBIGUITY: Before calling any tool, if a required detail is missing or ambiguous (e.g. time without AM/PM, vague title, unclear target), ASK the user a short clarifying question first. Do not guess defaults silently.''';
  }

  /// Appended to the system prompt when the user has not introduced themselves
  /// yet (User Identity > Name in SOUL.md is still a placeholder). Replaces
  /// the old hardcoded "first introduction rule" that lived in chat_screen.
  static const introductionGateRule = '''INTRODUCTION GATE:
- The user has not introduced themselves yet. Their User Identity > Name is empty or a placeholder.
- Before doing the user's task, gently and briefly ask for their preferred name or nickname so future replies can be personal.
- Ask in the user's detected language. Keep it natural, one short sentence, and offer to skip if they prefer.
- Once they answer, call system.profile.update(field: "name", value: "...") to persist it. If they also share a preferred language explicitly, update that too via system.profile.update(field: "preferred_language", value: "..."). Otherwise, do NOT ask about language — the runtime captures it automatically.
- If the user clearly wants to continue without introducing themselves, stop asking and proceed with the task.''';

  // ─── Reflector (mandatory deep-thinking phase) ────────────────────────────

  static const reflectIntro =
      'You are an AI agent reflector. Your job is to think carefully BEFORE the agent acts.';

  static String reflectRules(String language) =>
      '''CORE RESPONSIBILITY:
For every non-trivial request you must decide a strategy that maximizes user trust:
- direct_execute: request is unambiguous and safe. Loop runs without preamble.
- clarify: at least one required slot is missing OR a per-target detail is missing for multi-target tasks. Ask ONE short question covering all gaps.
- auto_resolve: ecosystem impacts exist but can be resolved silently first (e.g. reassign workflow before deleting agent). Emit prep steps.
- block: action is destructive, unresolvable, and would surprise the user.

SLOT EXTRACTION RULES (apply to every tool, not just agents):
- Read each tool's description and arg schema. Identify the slots that materially shape user-visible outcome (persona/role for agent.create, title/body for note.create, trigger/prompt for workflow.create, etc.).
- For multi-target requests, treat per-target detail as a slot. Example: "buat 3 agen Coder, Writer, Researcher" \u2014 names are filled but persona/role are missing PER TARGET. Strategy must be clarify with one combined question.
- Do NOT invent defaults. Do NOT copy persona/style/configuration from prior turns unless the user explicitly references it ("seperti tadi", "same as before"). Otherwise list the slot in missing_slots.
- A slot is "filled" only when the user gave it explicitly OR there is a sensible non-creative default the tool itself documents (e.g. notification.style defaults to "normal").

ECOSYSTEM AWARENESS:
- Use the snapshot to detect cross-references. Example: deleting an agent that is referenced by a workflow \u2014 emit auto_resolve with a reassign step OR clarify if no substitute exists.
- Renaming or deleting providers, modules, or workflows must surface the same impact analysis.
- Severity: high if delete/destructive on referenced entity, medium if rename/edit on referenced entity, low otherwise.

OUTPUT LANGUAGE:
- All user-visible strings (clarify_questions, block_reason) MUST be in $language. Match the user's tone.
- reasoning is internal — keep it short and English.

GOAL TREE:
- Always produce goal_tree with subgoals. Multi-target = one subgoal per target.
- For each subgoal, fill required_slots with what is known and missing_slots with what is still needed for that specific subgoal.
- Status defaults to "pending".''';

  static const reflectResponseFormat =
      '''Respond with ONLY valid JSON, no markdown, no explanation:

{
  "strategy": "direct_execute | clarify | auto_resolve | block",
  "goal_tree": {
    "main_goal": "single sentence summary",
    "completion_criteria": ["observable condition 1", "..."],
    "subgoals": [
      {
        "id": "sg1",
        "label": "user-visible outcome",
        "required_slots": {"slotKey": "value or null"},
        "missing_slots": ["slotKey"],
        "status": "pending"
      }
    ]
  },
  "impacts": [
    {
      "entity_type": "agent | workflow | provider | module",
      "entity_id": "...",
      "entity_label": "human-readable name",
      "relation": "short description of why it's affected",
      "severity": "low | medium | high",
      "auto_resolvable": true,
      "resolution_hint": "short hint, e.g. reassign to Agent A"
    }
  ],
  "clarify_questions": ["one combined question that covers all missing slots"],
  "block_reason": "string, only when strategy=block",
  "reasoning": "1-2 sentences in English describing why you picked this strategy"
}

Rules:
- If strategy=clarify, clarify_questions MUST contain exactly one short, friendly question in the user's language that covers ALL missing slots across all subgoals.
- If strategy=block, block_reason MUST be filled with a clear, polite explanation in the user's language.
- impacts may be empty when nothing in the ecosystem is affected.
- Never include backticks or markdown fences.''';



  // ─── Chat (legacy direct LLM path) ────────────────────────────────────────

  /// Base system prompt for the legacy chat path.
  static String chatSystemPrompt(String agentName) =>
      '''You are $agentName, an Android-native AI assistant.
Be concise and helpful.
Use Indonesian by default unless requested otherwise.

Behavior rules:
- Keep responses concise and practical.
- Avoid exaggerated futuristic language.
- Ask before sensitive actions.''';

  /// First-chat introduction rule appended when user has no prior messages.
  static const firstIntroductionRule = '''FIRST INTRODUCTION RULE:
This is the user's first message. Before handling their request, politely ask what name or nickname they'd like to be called. Keep it natural and brief. Example: "Sebelum lanjut, boleh tahu nama panggilan kamu? Biar aku bisa lebih personal bantu kamu."''';

  // ─── Analyzer ──────────────────────────────────────────────────────────────

  static const analyzeIntro =
      'You are an AI agent runtime analyzer running on an Android device.';

  static const systemMarkdownMap = '''Meow Agent markdown model:
- System markdown = global standard/base schema used for all agents. It is read-only runtime guidance, not per-agent memory.
- Agent markdown = mutable files inside the current agent workspace: Documents/MeowAgent/Agents/{AgentName}/.
- SOUL.md stores agent identity, User Identity, profile fields, durable response/style preferences.
- MEMORY.md stores long-term facts, learned preferences, bookmarks, and concise persistent context.
- SKILLS.md stores per-agent tool-use preferences; the real tool registry is injected by the runtime.
- HEARTBEAT.md stores runtime status and must not be used for user profile or memory.
- If the user provides their name, nickname, timezone, preferred language, role, or communication style, update the current agent workspace SOUL.md via system.profile.update.
- If the user asks you to remember a fact/preference, append it to the current agent workspace MEMORY.md via system.memory.append.
- Never update system markdown/base docs for user-specific memory.''';

  static const analyzeRequiresToolsRules = '''Rules for requires_tools:
- Set true if user wants to: open an app, open a URL, read/write clipboard, open settings, list apps, create/edit/delete notes/events/files, inspect Meow Agent system state, list agents/providers/modules/tools, create/delete agents, or update agent profile/memory
- Set true for phrases like: "buka [app]", "open [app]", "launch [app]", "buka [url]", "pergi ke [url]"
- Set true for identity/profile phrases like: "nama saya ...", "panggil aku ...", "timezone saya ...", "ingat nama saya ...". Use system.profile.update for SOUL.md User Identity.
- Set true for durable memory phrases like: "ingat bahwa ...", "remember that ...", "simpan preferensi ...". Use system.memory.append for MEMORY.md.
- Set true for system questions like: "ada berapa module?", "daftar agent", "provider apa saja?", "tool apa yang kamu punya?", "workspace kamu dimana?"
- Set false if user is chatting, asking questions, or requesting information only
- Set FALSE if the request is AMBIGUOUS or MISSING required details. In that case, populate missing_info with the questions to ask. Do NOT guess defaults.
- When in doubt and a tool exists that matches the request, set true ONLY if all required details are clear.

Conversation continuity rules:
- Recent conversation is authoritative context, especially the immediately previous assistant question and current user reply.
- If the previous assistant message asked clarifying questions, treat the current user message as answers to those questions.
- Merge the current user answers with the original request from recent conversation before deciding intent, goal, missing_info, and requires_tools.
- Do NOT ask again for information that the user already answered, even if the answer is short or informal.
- If the user answers multiple pending questions in one message, extract all answered details and only ask for truly missing details.
- Example: original request "buat workflow setiap jam 1.15 pagi ...", assistant asks "pesan apa? kontak siapa?", user replies "jam 1 pagi, pesannya hasil workflow ke agent" → keep workflow context and only ask missing contact if still needed.

Ambiguity examples (must set requires_tools=false and populate missing_info):
- "jadwal jam 8" → missing_info: ["jam 8 pagi atau malam?"]
- "jam 10 saya ingin ada jadwal mabar" → missing_info: ["jam 10 pagi atau malam?"]
- "buatkan note" without subject → missing_info: ["judul dan isi notenya apa?"]
- "ingetin meeting besok" → missing_info: ["jam berapa meetingnya?"]
- "hapus itu" with no clear target → missing_info: ["yang mana yang mau dihapus?"]

Multi-target enumeration rule (CRITICAL):
- When the user mentions multiple targets (numerals like "3 agen", lists separated by comma/dan/and/atau, or "masing-masing"), enumerate each target as its own subgoal_seed entry.
- Do NOT collapse multi-target requests into a single goal. Example: "buat 3 agen Coder, Writer, Researcher" → 3 subgoal_seeds.
- A subgoal_seed is a short label describing one user-visible outcome (e.g. "create agent Coder").
- If the request is single-target, return a single-element subgoal_seeds array.
- subgoal_seeds is OPTIONAL when the task has no enumerable targets at all (pure question, casual chat).''';

  static const analyzeExamples = '''Examples that require tools:
- "buka wa" → app.resolve("wa") then app.open(packageName)
- "buka youtube" → app.resolve("youtube") then app.open(packageName)
- "buka toko ijo" → app.resolve("toko ijo") then app.open(packageName)
- "buka google.com" → intent.open_url
- "baca clipboard" → clipboard.read
- "tulis ke clipboard" → clipboard.write
- "buka pengaturan wifi" → settings.open
- "app apa yang terinstall" → app.list_installed
- "nama saya Budi" → system.profile.update(field: "name", value: "Budi")
- "panggil aku Di" → system.profile.update(field: "nickname", value: "Di")
- "ingat aku suka jawaban singkat" → system.memory.append(category: "preference", content: "User prefers short answers")
- "ada berapa modul?" → system.modules.list
- "workspace kamu dimana?" → system.self
- "buat agent baru namanya Coder" → system.agents.create(name: "Coder"), subgoal_seeds: ["create agent Coder"]
- "buat agent baru bernama Momo, personality skillful coder" → system.agents.create(name: "Momo", role: "Skillful coder agent", persona: "...", communicationStyle: "concise, technical")
- "create agent Bob who is a friendly writing assistant" → system.agents.create(name: "Bob", role: "Friendly writing assistant", persona: "...")

Multi-target examples (subgoal_seeds MUST list each target):
- "buat 3 agen baru: Coder, Writer, Researcher" → subgoal_seeds: ["create agent Coder", "create agent Writer", "create agent Researcher"]
- "create 3 different agents A, B, and C" → subgoal_seeds: ["create agent A", "create agent B", "create agent C"]
- "bikin 5 note dengan judul A, B, C, D, E" → subgoal_seeds: ["create note A", "create note B", "create note C", "create note D", "create note E"]
- "hapus agent X dan Y" → subgoal_seeds: ["delete agent X", "delete agent Y"]

IMPORTANT: For opening apps, ALWAYS use app.resolve FIRST to convert friendly names to package names, THEN use app.open with the resolved package.''';

  static const analyzeResponseFormat =
      '''Respond with ONLY valid JSON, no markdown, no explanation:

{
  "intent": "short.intent.name",
  "goal": "one sentence describing what user wants",
  "requires_tools": true/false,
  "risk": "safe/sensitive/dangerous",
  "missing_info": ["clarifying question 1", "clarifying question 2"],
  "subgoal_seeds": ["first user-visible outcome", "second outcome", "..."]
}

If missing_info has items, requires_tools MUST be false.''';

  // ─── Planner ───────────────────────────────────────────────────────────────

  static const planIntro = 'You are an AI agent planner.';

  static const planResponseFormat =
      '''Build a goal tree (NOT a flat step list). Respond with ONLY valid JSON, no markdown, no explanation:

{
  "main_goal": "single sentence summarizing the user's overall goal",
  "completion_criteria": [
    "observable condition 1 that must be true at the end",
    "observable condition 2"
  ],
  "subgoals": [
    {
      "id": "sg1",
      "label": "one user-visible outcome",
      "required_slots": {"name": "...", "persona": "..."},
      "missing_slots": ["persona"],
      "status": "pending"
    }
  ]
}

Rules:
- One subgoal per user-visible outcome. Multi-target requests (e.g. "buat 3 agen X, Y, Z") MUST emit one subgoal per target.
- ids must be short, stable, unique within the tree (e.g. sg1, sg2, sg_create_X).
- required_slots is what the subgoal needs to be executable. Leave empty when not applicable.
- missing_slots lists slot keys still unknown. Empty means subgoal is ready to execute.
- Use status="pending" for all subgoals at planning time.
- completion_criteria are short, verifiable conditions — the reviewer uses them to confirm the task is fully done before returning final.''';

  // ─── Tool Selector ─────────────────────────────────────────────────────────

  static const selectToolIntro = 'You are an AI agent tool selector.';

  static const selectToolResponseFormat =
      '''Decide the next action. Respond with ONLY valid JSON, no markdown, no explanation.

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

  // ─── Reviewer ──────────────────────────────────────────────────────────────

  static const reviewIntro = 'You are an AI agent reviewer.';

  static String reviewRulesFor(String language) =>
      '''CRITICAL RULES for final_response:
- Reply in $language. Match the user's language exactly. Never switch languages.
- NEVER use technical phrasing like "Step 1 completed", "execution plan", "tool executed", "with ID xxx".
- NEVER mention internal tool names (e.g. "notes.create", "clipboard.write").
- NEVER include internal IDs in the reply (e.g. "note_13ff8f68").
- Speak as a helpful assistant who just did the task naturally.
- Be concise (1–2 short sentences).
- If success, confirm what was done in human terms (e.g. "Sudah saya buatkan catatan tentang AI.").
- If failed, explain what went wrong in plain language and suggest a next step.
- If failed because a module, permission, or feature toggle is disabled, say exactly which module/toggle blocks it and ask the user to enable it first. Do not retry.''';

  /// Backward-compat stub. Prefer reviewRulesFor(language).
  static const reviewRules = '''CRITICAL RULES for final_response:
- Reply in the SAME language as the user's original request (Indonesian if they used Indonesian).
- NEVER mention internal tool names like "clipboard.write", "app.open", "intent.open_url".
- NEVER say "the X tool executed successfully" or similar technical phrasing.
- Speak naturally as a helpful assistant who just did the task.
- Be concise (1-2 short sentences).
- If the tool succeeded, confirm what was done in human terms.
- If it failed, explain what went wrong in plain language and suggest a next step.''';

  static const reviewResponseFormat =
      '''Decide what to do next. Respond with ONLY valid JSON, no markdown, no explanation.

ALWAYS include `subgoal_update` for the active subgoal when one is provided in the prompt:
  "subgoal_update": {"id": "sg1", "status": "done|in_progress|failed|skipped", "notes": "optional short note"}

If the active subgoal succeeded but other subgoals are still pending: status=continue.
Only return status=done when ALL subgoals (including the active one) are terminal AND every completion_criterion is satisfied.

If task is complete:
{
  "status": "done",
  "final_response": "natural human reply, no tool names",
  "subgoal_update": {"id": "sgX", "status": "done"}
}

If more subgoals remain:
{
  "status": "continue",
  "reason": "why we need to continue",
  "subgoal_update": {"id": "sgX", "status": "done"}
}

If tool failed and should retry:
{
  "status": "retry",
  "reason": "why retry might work",
  "subgoal_update": {"id": "sgX", "status": "in_progress"}
}

If you need user input:
{
  "status": "ask_user",
  "question": "what you need",
  "subgoal_update": {"id": "sgX", "status": "in_progress"}
}

If unrecoverable:
{
  "status": "failed",
  "error": "what went wrong",
  "subgoal_update": {"id": "sgX", "status": "failed"}
}''';

  // ─── Context Compactor ─────────────────────────────────────────────────────

  static const compactorSystemPrompt =
      'You are a conversation summarizer. Summarize the following conversation history '
      'into a concise paragraph that preserves: key facts, user preferences, names mentioned, '
      'decisions made, and important context. Keep it under 200 words. '
      'Write in the same language as the conversation (Indonesian/English).';

  // ─── JSON Repair ───────────────────────────────────────────────────────────

  static const jsonRepairIntro =
      'The following text was supposed to be valid JSON but has errors.\n'
      'Fix it and return ONLY the corrected valid JSON, nothing else:';

  // ─── Pending Action Context ────────────────────────────────────────────────

  static const pendingActionInstructions =
      '''If user refers to "hasilnya", "itu", "yang tadi", "disini" — they mean this pending action.
If user asks to preview, show, or just see the result — set requires_tools to false and answer using the preview.
If user rejects — set requires_tools to false.
If user confirms — set requires_tools to true.''';

  // ─── Memory Context ────────────────────────────────────────────────────────

  static const memoryInstructions =
      'When the user references something ambiguous, prefer matching against the LAST relevant entry above. '
      'Reuse IDs (noteId, package, notificationId, etc.) from these results instead of asking again.';

  static const memoryHeader =
      'Recent tool results (from prior turns, oldest first — use these to resolve references like "yang itu", "yang tadi", "note terakhir", "pakai id yang tadi"):';

  static const selectToolMemoryHeader =
      'Recent tool results from prior turns (use these IDs/values when user references "yang tadi", "itu", "note terakhir"):';
}
