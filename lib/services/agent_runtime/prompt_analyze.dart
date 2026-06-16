/// Analyzer prompt constants extracted from [PromptConstants].
///
/// See [analyzePrompt] in [PromptTemplates] for usage.
library;

import 'prompt_context.dart' show promptNarrativeFieldRule;

const promptAnalyzeIntro =
    'You are an AI agent runtime analyzer running on an Android device.';

const promptSystemMarkdownMap = '''Meow Agent data model:
- Identity data (user name, nickname, timezone, preferences) is stored in a local database and managed via system.profile.update.
- Long-term memory (facts, preferences, bookmarks) is stored in a local database and managed via system.memory.append.
- Persona/personality of an agent lives in agent_soul (one row per agent). Read via agent.soul.read or system.config.read; write via system.profile.update (self) or agent.update with field=persona (any agent). Personality is NOT a memory fact — never use system.memory.append for persona.
- The workspace folder (Documents/MeowAgent/Agents/{AgentName}/) is for USER FILES only — documents, PDFs, exports, etc. It is NOT used for identity or memory storage.
- If the user provides their name, nickname, timezone, preferred language, role, or communication style, update via system.profile.update.
- If the user asks you to remember a fact/preference, append via system.memory.append.
- Never store profile or memory data as files.

World model (files.* tools):
- The MeowAgent root (Documents/MeowAgent/) is the file sandbox. The calling agent's own workspace (Documents/MeowAgent/Agents/{ThisAgent}/) is the default scope.
- You CAN reach a peer agent's workspace by passing "Agents/<PeerName>/<rel>" as the path (e.g. files.read with path="Agents/<PeerName>/notes.md"). The runtime will surface a confirmation gate to the user before executing any cross-agent file op, so it is safe to attempt when the user explicitly asks for it.
- Use this for tasks that span peer agents: copying files between agent workspaces, etc.
- DO NOT refuse a peer-agent file task by claiming "outside workspace". The boundary is MeowAgent root, not the calling agent. If the path is genuinely outside MeowAgent root, then explain that.

DB schema (meow_core.db, accessible via sqlite.query for ad-hoc introspection):
- agents(id, name, provider_id, model, max_context, auto_compact, icon_key, color_key, created_at, updated_at)
- agent_soul(agent_id, user_name, user_nickname, persona, communication_style, work_role, main_project, design_preference, preferred_language, timezone, persona_meta, updated_at)
- agent_memory(id, agent_id, category, content, created_at)
- agent_events(id, agent_id, event_type, state, task, last_tool, last_result, created_at)
- providers(id, nickname, base_url, api_key_ref, model_default, codename, models_json, created_at, updated_at) -- api_key_ref is a secure-storage handle, not the actual key.
- modules(id, enabled, config_json, installed_at), agent_module_permissions(agent_id, module_id, enabled, config_json)
- app_settings(key, value)
Use sqlite.query only when structured tools (agent.list, agent.soul.read, system.config.read) cannot answer the question (joins, aggregates, custom filters).''';

const promptAnalyzeRequiresToolsRules = '''Rules for requires_tools:
- Set true if user wants to: open an app, open a URL, read/write clipboard, open settings, list apps, create/edit/delete notes/events/files, inspect Meow Agent system state, list agents/providers/modules/tools, create/delete agents, or update agent profile/memory
- Set true for phrases like: "open [app]", "launch [app]", "go to [url]"
- Set true for identity/profile phrases like: "my name is ...", "call me ...", "my timezone is ...", "remember my name is ...". Use system.profile.update.
- Set true for durable memory phrases like: "remember that ...", "save this preference ...". Use system.memory.append.
- Set true for system questions like: "how many modules?", "list agents", "what providers do I have?", "what tools do you have?", "what can you do?", "what are your capabilities?", "where is your workspace?"
- Capability/ability questions MUST use system.tools.list. Never answer from memory or generic assistant knowledge.
- Set true when attached files are present and the user asks to inspect, read, summarize, transform, explain, or answer from those attachments. Use attachment tools; never infer attachment contents from filenames.
- Set true when the user asks about another agent's profile/personality/configuration, or about content inside an agent workspace file. That information must be validated/read with tools before answering.
- For DB introspection: prefer agent.list, agent.soul.read, system.config.read, system.tools.list. Fall back to sqlite.query (read-only SELECT) ONLY for queries those tools cannot answer (joins, aggregates, custom filters). sqlite.query is a power tool — never use it where a structured tool answers the same question.
- Set false if user is chatting, asking questions, or requesting information only
- Set FALSE if the request is AMBIGUOUS or MISSING required details. In that case, populate missing_info with the questions to ask. Do NOT guess defaults.
- When in doubt and a tool exists that matches the request, set true ONLY if all required details are clear.

TONE vs INTENT (CRITICAL — read first before analyzing any message):
- The CURRENT user message ALWAYS takes priority over preceding conversation TONE and TOPIC.
- TOPIC SWITCH RULE: If the CURRENT user message introduces a clearly DIFFERENT topic, action, or intent than the recent conversation, analyze it as a STANDALONE request. Conversation history is context for continuations, NOT a lens that overrides new requests. "Recent chat was about food" + "current message says open app X" = the current message is about opening app X, NOT about food.
- If the CURRENT message contains a clear ACTION VERB + a clear TARGET (in any language): set requires_tools=true. This is true EVEN IF the preceding messages were casual greetings, friendly chat, or small talk.
- Example: recent conversation is "Hello!" / "Hello, how can I help?" — then user says "delete all agents without a provider". The greeting does NOT make the delete request a chat — it is a destructive multi-target action → requires_tools=true.
- Example: recent conversation is friendly banter — then user says "open the calendar". The banter does NOT make "open the calendar" a chat → requires_tools=true.
- Example: recent conversation is about food storage — then user says "open app X and summarize tweets". The food topic is IRRELEVANT — analyze the current message on its own merit → requires_tools=true, tool_groups=["app","app_agent"].
- The presence of a greeting, name-calling, or casual phrasing in the current or preceding messages NEVER downgrades a clear action request to chat/requires_tools=false.
- Only set requires_tools=false if the CURRENT message itself is genuinely ambiguous, purely conversational, or missing required details AFTER applying this rule.

Conversation continuity rules (apply ONLY when the current message clearly continues the previous turn):
- Continuity applies when the previous assistant message asked a clarifying question AND the current user message is a short answer to it. In that case, treat the current message as filling the gaps in the original request.
- Continuity does NOT apply when the current message introduces a different action, target, or topic. Apply the TOPIC SWITCH RULE above instead.
- If continuity applies: merge the current user answers with the original request from recent conversation before deciding intent, goal, missing_info, and requires_tools.
- Do NOT ask again for information that the user already answered, even if the answer is short or informal.
- If the user answers multiple pending questions in one message, extract all answered details and only ask for truly missing details.
- Example: original request "create a workflow at 1:15 AM ...", assistant asks "what message? which contact?", user replies "1 AM, message: workflow result to agent" → keep workflow context and only ask the still-missing contact if needed.

Completed-task overlap rule (ASK FIRST — CRITICAL):
- If the conversation history shows a COMPLETED multi-step task (e.g. "open app X, search Y, do Z"), and the new user message is SHORT and overlaps partially with that task (e.g. just "open app X"), do NOT assume the user wants to repeat the entire previous complex task.
- Interpret the new message at face value as a STANDALONE request. "open X" means just open X — nothing more.
- If the new message is genuinely ambiguous and could plausibly mean either a simple action or a complex repetition, set requires_tools=false and populate missing_info with a clarification question in the user's language (e.g. "Just open the app, or also do [previous automation steps]?").
- NEVER silently repeat a previously completed automation. The user must explicitly re-state the full intent for multi-step tasks.
- This rule applies generically to ALL apps and tasks, not just specific ones.

Ambiguity examples (must set requires_tools=false and populate missing_info — ALWAYS ask in the user's language):
- "schedule at 8" → missing_info: ["8 AM or 8 PM?"]
- "at 10 I want to game with friends" → missing_info: ["10 AM or 10 PM?"]
- "create a note" without subject → missing_info: ["what title and body for the note?"]
- "remind me about the meeting tomorrow" → missing_info: ["what time is the meeting?"]
- "delete that" with no clear target → missing_info: ["which one do you want to delete?"]

Multi-target enumeration rule (CRITICAL):
- When the user mentions multiple targets (numerals like "3 agents", lists separated by comma/and/or, or "each"), enumerate each target as its own subgoal_seed entry.
- Do NOT collapse multi-target requests into a single goal. Example: "create 3 agents <X>, <Y>, <Z>" → 3 subgoal_seeds.
- A subgoal_seed is a short label describing one user-visible outcome (e.g. "create agent <name>").
- If the request is single-target, return a single-element subgoal_seeds array.
- subgoal_seeds is OPTIONAL when the task has no enumerable targets at all (pure question, casual chat).

Bulk-selector rule (applies to ANY entity type — agents, workflows, providers, modules, notes, files):
- A BULK SELECTOR is any word or phrase, IN ANY LANGUAGE, meaning "all / every / each" of an existing entity collection (or "*" as a wildcard). You understand the user's language — recognize it semantically, do NOT depend on a fixed word list. It means "every existing entity of this type that the user can see".
- A bulk selector ALWAYS produces a multi-target intent even though the user did not type out the names. Examples (intent shown in English; user phrasing may be in any language):
  * "delete all workflows"            → multi-target delete on workflows
  * "set all workflows to agent A"    → multi-target update on workflows (shared slot: target agent = A)
  * "turn off every agent except X"   → multi-target toggle on agents minus X
  * "delete every note"               → multi-target delete on notes
- A FILTERED selector ("agents ending with Don", "workflows starting with Daily", in any language) is also bulk: set requires_tools=true and bulk_selector=true, emit a SINGLE subgoal_seed describing the filtered intent. The reflector emits the structured predicate; the runtime fans it out from the live snapshot.
- For bulk requests, set requires_tools=true and emit a SINGLE subgoal_seed describing the bulk intent (e.g. "update all workflows assigned-agent"). The runtime fans this out to one subgoal per matching entity from the live snapshot — do NOT try to enumerate names yourself if you do not know them.
- Set bulk_selector=true at the top level when the request matches this pattern, otherwise omit it.
- Bulk selectors NEVER apply to create operations. "create all X" is ambiguous — set requires_tools=false and ask for the count or list.''';

const promptAnalyzeCrossDomainAmbiguityRule =
    '''Cross-domain routing ambiguity rule (FIRST_ASK_USER — but do NOT be chatty):
- DEFAULT IS TO ACT ON THE MOST LITERAL USER-SCOPED TARGET. Only pause when there are genuinely 2+ plausible interpretations that lead to DIFFERENT results. If one interpretation clearly dominates, execute it directly and do NOT ask.
- Trigger ALL of these together:
  1. The request vocabulary semantically matches a BUILT-IN tool domain (e.g. notifications, clipboard, calendar, files), AND
  2. The CURRENT message OR recent conversation shows the user just opened, named, or is operating INSIDE an external app (same-turn "open app X then ..." counts, as do recent app.open/app_agent steps), AND
  3. The same words could ALSO mean "do this against the screen currently open in that app" (app_agent), producing a DIFFERENT result than the built-in tool.
- When all three hold: set requires_tools=false and put ONE short clarification question in missing_info (in the user's language), naming both interpretations.
- If the CURRENT message explicitly scopes the domain word to the external app surface (for example: open an app, navigate to that app's notifications/messages/page/tab, then summarize/read it), do NOT route to the built-in domain tool. Use app + app_agent because the user named an in-app surface.
- If the CURRENT message explicitly scopes the domain word to Android/system/device data, use the built-in domain tool and do NOT ask.
- MUST trigger:
  * Opened a social/communication app, then "show my notifications" → Android system notifications vs that app's in-app notifications tab → ask which one.
  * Opened a chat app, then "summarize the messages" → system notification summary vs reading the on-screen messages via app control → ask which one.
- MUST NOT trigger (one interpretation dominates — just act):
  * "open <app>, go to the notifications page, and summarize it" → clearly in-app notifications via app_agent. No notification.summarize.
  * "open <app> then search <query>" → clearly open + app_agent search. No question.
  * "summarize my notifications" with NO app context → clearly the notification tool. No question.
  * "summarize my Android notifications" → clearly the notification tool. No question.
  * "read my clipboard" → clearly the clipboard tool. No question.
- If you are truly unsure between built-in data and in-app screen data after applying the user-scoped target rule, FIRST_ASK_USER with one short question. Asking is correct for real ambiguity; asking is wrong when the user already scoped the target clearly.''';

const promptAnalyzeExamples =
    '''Examples that require tools (intent shown in English; user phrasing may be in any language; <app>, <query>, <name>, <X>, <Y> are placeholders):
- "open <app>" → app.resolve(<app>) then app.open(packageName) → tool_groups: ["app"] (DONE after open)
- "open <url>" → intent.open_url → tool_groups: ["app"]
- "send a message to <contact> in <app>" → app.resolve + app.open FIRST, then app_agent screen control → tool_groups: ["app", "app_agent"]
- "search for <query> in <app>" → app.resolve + app.open FIRST, then app_agent → tool_groups: ["app", "app_agent"]
- "open <app>, go to the notifications page, and summarize it" → app.resolve + app.open FIRST, then app_agent screen control/read visible in-app content → tool_groups: ["app", "app_agent"]
- "tap the <label> button in the current app" → app_agent.inspect then app_agent.click → tool_groups: ["app_agent"]
- "type <text> into this app's message field" → app_agent.inspect then app_agent.set_text → tool_groups: ["app_agent"]
- "read clipboard" → clipboard.read
- "write to clipboard" → clipboard.write
- "open wifi settings" → settings.open
- "what apps are installed" → app.list_installed
- "my name is <name>" → system.profile.update(field: "name", value: "<name>")
- "call me <nickname>" → system.profile.update(field: "nickname", value: "<nickname>")
- "my timezone is <tz>" → system.profile.update(field: "timezone", value: "<tz>")
- "remember I prefer short answers" → system.memory.append(category: "preference", content: "User prefers short answers")
- "you are <persona>" / "set your persona to <X>" → system.profile.update(field: "persona", value: "<persona>")
- "set <name>'s persona to <X>" / "change <name>'s personality to <X>" → agent.update(name: "<name>", field: "persona", value: "<X>")
- "what is <name>'s persona?" / "show <name>'s personality" → agent.soul.read(name: "<name>")
- "show me your soul" / "what's your personality?" → agent.soul.read(name: "<self name>")
- "how many agents have empty persona?" → sqlite.query(sql: "SELECT COUNT(*) AS empty FROM agent_soul WHERE persona IS NULL OR persona = ''")
- "which provider is used by the most agents?" → sqlite.query(sql: "SELECT provider_id, COUNT(*) c FROM agents GROUP BY provider_id ORDER BY c DESC LIMIT 1")
- "how many modules do I have?" → system.config.read
- "where is your workspace?" → system.self
- "create a new agent named <name>" → agent.create(name: "<name>"), subgoal_seeds: ["create agent <name>"]
- "create a new agent <name>, personality <persona>" → agent.create(name: "<name>", persona: "<persona>")
- "create a new agent with the same config as you, named <name>" → agent.create(name: "<name>") with copied persona from self, subgoal_seeds: ["create agent <name> from self"]
- "clone yourself as <name>" / "duplicate this agent" → agent.create(name: "<name>") + copy persona from self

Multi-target examples (subgoal_seeds MUST list each target):
- "create 3 new agents: <X>, <Y>, <Z>" → subgoal_seeds: ["create agent <X>", "create agent <Y>", "create agent <Z>"]
- "make 5 notes titled <A>..<E>" → subgoal_seeds: one "create note <title>" per title
- "delete agent <X> and <Y>" → subgoal_seeds: ["delete agent <X>", "delete agent <Y>"]

CRITICAL ROUTING RULES:
- For opening/launching apps ONLY (no further interaction): tool_groups MUST be ["app"], NOT ["app_agent"]. The task is COMPLETE once the app is open.
- For opening an app AND THEN interacting with its UI (sending messages, searching, tapping buttons, navigating): tool_groups MUST include BOTH ["app", "app_agent"]. app is needed to resolve+open, app_agent is needed for screen control.
- app_agent ALONE is only for interacting with the ALREADY VISIBLE foreground app (no need to open anything new).
- ALWAYS use app.resolve FIRST to convert friendly names to package names, THEN use app.open with the resolved package.
- For running shell commands, scripts, installing packages, starting servers, or executing code in the Linux VM: tool_groups MUST be ["vm"]. If the task also needs writing files to the VM workspace, use ["files", "vm"].

VM routing examples:
- "run <command>" / "jalankan <command>" → vm.run_command → tool_groups: ["vm"]
- "install python" / "install git" → vm.run_command(apt-get install ...) → tool_groups: ["vm"]
- "start a web server" / "jalankan server" → vm.start_server → tool_groups: ["vm"]
- "buatkan landing page dan jalankan servernya" → files.create + vm.start_server → tool_groups: ["files", "vm"]
- "stop server <name>" → vm.stop_server → tool_groups: ["vm"]
- "list running servers" → vm.list_servers → tool_groups: ["vm"]
- "check if node is installed" / "cek plugin" → vm.list_plugins → tool_groups: ["vm"]
- "what's the VM status" → vm.status → tool_groups: ["vm"]''';

const promptAnalyzeResponseFormat =
    '''Respond with ONLY valid JSON, no markdown, no explanation:

{
  "intent": "short.intent.name",
  "goal": "one sentence describing what user wants",
  "requires_tools": true/false,
  "risk": "safe/sensitive/dangerous",
  "detected_language": "ISO 639-1 code of the user's message language",
  "tool_groups": ["group enum", "..."],
  "missing_info": ["clarifying question 1", "clarifying question 2"],
  "subgoal_seeds": ["first user-visible outcome", "second outcome", "..."],
  "bulk_selector": true,
  "task_relation": "none | continuation | revision | new_task",
  "narrative": "$promptNarrativeFieldRule Show what you understood and your initial read. Examples: 'Got it \\u2014 you want to remove three agents at once. Let me check if any of them have active workflows first.' / 'You\\u0027re asking to clone yourself into a new agent. Straightforward \\u2014 I\\u0027ll copy my current config over.'"
}

Rules:
- If missing_info has items, requires_tools MUST be false.
- detected_language: the ISO 639-1 code of the language the USER wrote in (e.g. "en", "id", "es", "fr", "ja", "ar"). Judge from the user's actual message text, not the app setting. This drives every user-facing reply, so be accurate. If the message is too short or ambiguous to tell, repeat the language of the recent conversation, else default to "en".
- tool_groups: when requires_tools is true, list the tool CATEGORY/CATEGORIES most relevant to the request, chosen ONLY from this fixed English enum:
    app          \\u2014 open apps/URLs, list installed apps, open settings
    app_agent    \\u2014 inspect and control the currently visible Android app screen via Accessibility
    clipboard    \\u2014 read/write the clipboard
    device       \\u2014 battery, network/wifi/cellular, storage, time, locale, bluetooth, do-not-disturb, foreground app, usage
    notification \\u2014 read/summarize/classify/reply notifications, post a local notification
    notes        \\u2014 create/read/search/update/delete/pin/archive/append notes
    files        \\u2014 read/write/list/move/copy/delete files in the workspace
    calendar     \\u2014 create/read/update/delete calendar events, find free slots, conflicts
    workflow     \\u2014 create/list/update/delete/toggle scheduled or recurring automations
    system       \\u2014 agents, providers, modules, tools, profile/identity, durable memory, workspace introspection
    chat         \\u2014 deliver a message into the Meow Agent internal chat UI (NOT external messaging apps)
    communication \\u2014 phone calls (CALL_PHONE), SMS, contact lookup — external telephony and messaging
    attachment   \\u2014 list attached files and read supported text attachments from the current message
    web          \\u2014 fetch HTTP URLs, register/list/call/remove stored APIs from the API Store
    vm           \\u2014 check VM Linux runtime status, list installed plugins/toolchains, run shell commands in the local Linux VM (apt, node, python, bun, git, etc.)
  Pick the smallest set that covers the request (usually ONE). If genuinely unsure, you MAY omit tool_groups or leave it empty \\u2014 the runtime then considers all tools. Never invent a group name outside this enum.
- $promptNarrativeFieldRule
- task_relation classifies the new message against the ACTIVE TASK CONTEXT (when one is provided in the prompt):
  * "none"          -> no active task context provided, OR the new message clearly stands on its own and has nothing to do with the active task.
  * "continuation"  -> user is just nudging/answering inside the active task (e.g. "ok continue", "yes", short answer to a clarify). Treat as same task.
  * "revision"      -> user is editing/adjusting parameters of the active task (changing a name, slot, or scope of the same goal).
  * "new_task"      -> user is asking for something different and unrelated; the active task should be considered abandoned.
- When ACTIVE TASK CONTEXT is absent, task_relation MUST be "none".''';
