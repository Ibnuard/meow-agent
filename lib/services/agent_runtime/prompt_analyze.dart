/// Analyzer prompt constants extracted from [PromptConstants].
///
/// See [analyzePrompt] in [PromptTemplates] for usage.
library;

const promptAnalyzeIntro =
    'You are an AI agent runtime analyzer running on an Android device.';

const promptSystemMarkdownMap = '''Meow Agent markdown model:
- System markdown = global standard/base schema used for all agents. It is read-only runtime guidance, not per-agent memory.
- Agent markdown = mutable files inside the current agent workspace: Documents/MeowAgent/Agents/{AgentName}/.
- SOUL.md stores agent identity, User Identity, profile fields, durable response/style preferences.
- MEMORY.md stores long-term facts, learned preferences, bookmarks, and concise persistent context.
- SKILLS.md stores per-agent tool-use preferences; the real tool registry is injected by the runtime.
- HEARTBEAT.md stores runtime status and must not be used for user profile or memory.
- If the user provides their name, nickname, timezone, preferred language, role, or communication style, update the current agent workspace SOUL.md via system.profile.update.
- If the user asks you to remember a fact/preference, append it to the current agent workspace MEMORY.md via system.memory.append.
- Never update system markdown/base docs for user-specific memory.

World model (files.* tools):
- The MeowAgent root (Documents/MeowAgent/) is the file sandbox. The calling agent's own workspace (Documents/MeowAgent/Agents/{ThisAgent}/) is the default scope.
- You CAN reach a peer agent's workspace by passing "Agents/<PeerName>/<rel>" as the path (e.g. files.read with path="Agents/Penulis/SOUL.md"). The runtime will surface a confirmation gate to the user before executing any cross-agent file op, so it is safe to attempt when the user explicitly asks for it.
- Use this for tasks that span peer agents: swapping personalities, syncing memory snippets, copying files between agent workspaces, etc.
- DO NOT refuse a peer-agent file task by claiming "outside workspace". The boundary is MeowAgent root, not the calling agent. If the path is genuinely outside MeowAgent root, then explain that.''';

const promptAnalyzeRequiresToolsRules = '''Rules for requires_tools:
- Set true if user wants to: open an app, open a URL, read/write clipboard, open settings, list apps, create/edit/delete notes/events/files, inspect Meow Agent system state, list agents/providers/modules/tools, create/delete agents, or update agent profile/memory
- Set true for phrases like: "open [app]", "launch [app]", "go to [url]"
- Set true for identity/profile phrases like: "my name is ...", "call me ...", "my timezone is ...", "remember my name is ...". Use system.profile.update for SOUL.md User Identity.
- Set true for durable memory phrases like: "remember that ...", "save this preference ...". Use system.memory.append for MEMORY.md.
- Set true for system questions like: "how many modules?", "list agents", "what providers do I have?", "what tools do you have?", "what can you do?", "what are your capabilities?", "where is your workspace?"
- Capability/ability questions MUST use system.tools.list. Never answer from memory or generic assistant knowledge.
- Set true when attached files are present and the user asks to inspect, read, summarize, transform, explain, or answer from those attachments. Use attachment tools; never infer attachment contents from filenames.
- Set true when the user asks about another agent's profile/personality/configuration, or about content inside an agent workspace file. That information must be validated/read with tools before answering.
- Set false if user is chatting, asking questions, or requesting information only
- Set FALSE if the request is AMBIGUOUS or MISSING required details. In that case, populate missing_info with the questions to ask. Do NOT guess defaults.
- When in doubt and a tool exists that matches the request, set true ONLY if all required details are clear.

TONE vs INTENT (CRITICAL — read first before analyzing any message):
- The CURRENT user message ALWAYS takes priority over preceding conversation TONE.
- If the CURRENT message contains a clear ACTION VERB + a clear TARGET (in any language): set requires_tools=true. This is true EVEN IF the preceding messages were casual greetings, friendly chat, or small talk.
- Example: recent conversation is "Hello!" / "Hello, how can I help?" — then user says "delete all agents without a provider". The greeting does NOT make the delete request a chat — it is a destructive multi-target action → requires_tools=true.
- Example: recent conversation is friendly banter — then user says "open the calendar". The banter does NOT make "open the calendar" a chat → requires_tools=true.
- The presence of a greeting, name-calling, or casual phrasing in the current or preceding messages NEVER downgrades a clear action request to chat/requires_tools=false.
- Only set requires_tools=false if the CURRENT message itself is genuinely ambiguous, purely conversational, or missing required details AFTER applying this rule.

Conversation continuity rules:
- Recent conversation is authoritative context, especially the immediately previous assistant question and current user reply.
- If the previous assistant message asked clarifying questions, treat the current user message as answers to those questions.
- Merge the current user answers with the original request from recent conversation before deciding intent, goal, missing_info, and requires_tools.
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
- Do NOT collapse multi-target requests into a single goal. Example: "create 3 agents Coder, Writer, Researcher" → 3 subgoal_seeds.
- A subgoal_seed is a short label describing one user-visible outcome (e.g. "create agent Coder").
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
  * Opened LinkedIn, then "show my notifications" → Android system notifications vs LinkedIn's in-app notifications tab → ask which one.
  * Opened a chat app, then "summarize the messages" → system notification summary vs reading the on-screen messages via app control → ask which one.
- MUST NOT trigger (one interpretation dominates — just act):
  * "open LinkedIn, go to the notifications page, and summarize it" → clearly in-app LinkedIn notifications via app_agent. No notification.summarize.
  * "open youtube then search cooking videos" → clearly open + app_agent search. No question.
  * "summarize my notifications" with NO app context → clearly the notification tool. No question.
  * "summarize my Android notifications" → clearly the notification tool. No question.
  * "read my clipboard" → clearly the clipboard tool. No question.
- If you are truly unsure between built-in data and in-app screen data after applying the user-scoped target rule, FIRST_ASK_USER with one short question. Asking is correct for real ambiguity; asking is wrong when the user already scoped the target clearly.''';

const promptAnalyzeExamples =
    '''Examples that require tools (intent shown in English; user phrasing may be in any language):
- "open whatsapp" → app.resolve("whatsapp") then app.open(packageName) → tool_groups: ["app"] (DONE after open)
- "open youtube" → app.resolve("youtube") then app.open(packageName) → tool_groups: ["app"] (DONE after open)
- "open google.com" → intent.open_url → tool_groups: ["app"]
- "send a message to Bob in WhatsApp" → app.resolve + app.open FIRST, then app_agent screen control → tool_groups: ["app", "app_agent"]
- "search for X in YouTube" → app.resolve + app.open FIRST, then app_agent → tool_groups: ["app", "app_agent"]
- "open LinkedIn, go to the notifications page, and summarize it" → app.resolve + app.open FIRST, then app_agent screen control/read visible in-app content → tool_groups: ["app", "app_agent"]
- "tap the Send button in the current app" → app_agent.inspect then app_agent.click → tool_groups: ["app_agent"]
- "type hello into this app's message field" → app_agent.inspect then app_agent.set_text → tool_groups: ["app_agent"]
- "read clipboard" → clipboard.read
- "write to clipboard" → clipboard.write
- "open wifi settings" → settings.open
- "what apps are installed" → app.list_installed
- "my name is Budi" → system.profile.update(field: "name", value: "Budi")
- "call me Di" → system.profile.update(field: "nickname", value: "Di")
- "my timezone is WIB" → system.profile.update(field: "timezone", value: "Asia/Jakarta")
- "remember I prefer short answers" → system.memory.append(category: "preference", content: "User prefers short answers")
- "how many modules do I have?" → system.modules.list
- "where is your workspace?" → system.self
- "create a new agent named Coder" → system.agents.create(name: "Coder"), subgoal_seeds: ["create agent Coder"]
- "create a new agent Momo, personality skillful coder" → system.agents.create(name: "Momo", role: "Skillful coder agent", persona: "...", communicationStyle: "concise, technical")
- "create agent Bob who is a friendly writing assistant" → system.agents.create(name: "Bob", role: "Friendly writing assistant", persona: "...")

Multi-target examples (subgoal_seeds MUST list each target):
- "create 3 new agents: Coder, Writer, Researcher" → subgoal_seeds: ["create agent Coder", "create agent Writer", "create agent Researcher"]
- "create 3 different agents A, B, and C" → subgoal_seeds: ["create agent A", "create agent B", "create agent C"]
- "make 5 notes titled A, B, C, D, E" → subgoal_seeds: ["create note A", "create note B", "create note C", "create note D", "create note E"]
- "delete agent X and Y" → subgoal_seeds: ["delete agent X", "delete agent Y"]

CRITICAL ROUTING RULES:
- For opening/launching apps ONLY (no further interaction): tool_groups MUST be ["app"], NOT ["app_agent"]. The task is COMPLETE once the app is open.
- For opening an app AND THEN interacting with its UI (sending messages, searching, tapping buttons, navigating): tool_groups MUST include BOTH ["app", "app_agent"]. app is needed to resolve+open, app_agent is needed for screen control.
- app_agent ALONE is only for interacting with the ALREADY VISIBLE foreground app (no need to open anything new).
- ALWAYS use app.resolve FIRST to convert friendly names to package names, THEN use app.open with the resolved package.''';

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
  "narrative": "ONE short, casual, POV-AI sentence in the user's language saying what you understood from their request (e.g. 'Got it \\u2014 you want to remove three agents at once.' / 'Got it \\u2014 you want to open WhatsApp.')"
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
    communication \\u2014 WhatsApp messages/calls, phone calls (CALL_PHONE), SMS, contact lookup — any external messaging or telephony
    attachment   \\u2014 list attached files and read supported text attachments from the current message
    web          \\u2014 fetch HTTP URLs, register/list/call/remove stored APIs from the API Store
  Pick the smallest set that covers the request (usually ONE). If genuinely unsure, you MAY omit tool_groups or leave it empty \\u2014 the runtime then considers all tools. Never invent a group name outside this enum.
- narrative MUST be in the user's language, first-person, 1 short sentence, NO tool names, NO IDs. Speak as if you're recapping what you understood.
- task_relation classifies the new message against the ACTIVE TASK CONTEXT (when one is provided in the prompt):
  * "none"          -> no active task context provided, OR the new message clearly stands on its own and has nothing to do with the active task.
  * "continuation"  -> user is just nudging/answering inside the active task (e.g. "ok continue", "yes", short answer to a clarify). Treat as same task.
  * "revision"      -> user is editing/adjusting parameters of the active task (changing a name, slot, or scope of the same goal).
  * "new_task"      -> user is asking for something different and unrelated; the active task should be considered abandoned.
- When ACTIVE TASK CONTEXT is absent, task_relation MUST be "none".''';
