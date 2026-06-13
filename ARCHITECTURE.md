# Meow Agent — Architecture Overview

> Last updated: 2026-06-14
> Status: Post Phase 7 migration (SQLite-backed runtime)

---

## 1. High-Level Overview

Meow Agent is an Android-native AI companion operating system built with Flutter. It provides a multi-agent runtime that can automate device actions, manage notes/calendar/files, and interact with external apps via Accessibility Services.

```
┌─────────────────────────────────────────────────────────────┐
│                      Flutter UI Layer                         │
│  (Chat Screen, Agent List, Provider Settings, Modules)       │
├─────────────────────────────────────────────────────────────┤
│                   Riverpod State Layer                        │
│  (Providers, Notifiers, StreamProviders)                     │
├─────────────────────────────────────────────────────────────┤
│                  Agentic Runtime Engine                       │
│  (Planner → Reflector → Executor → ToolVerbalizer)          │
├─────────────────────────────────────────────────────────────┤
│               Tool Router + Module Plugins                    │
│  (Self-registering ModulePlugin pattern)                     │
├─────────────────────────────────────────────────────────────┤
│                   Data Layer (SQLite)                         │
│  meow_core.db — single source of truth                       │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. Data Architecture (Phase 7 — Current)

### 2.1 Storage: `meow_core.db` (SQLite)

All persistent state lives in a single SQLite database. **No more `meow.json`** for configuration, **no more workspace markdown files** for identity/memory.

| Table | Purpose | Repository |
|-------|---------|-----------|
| `agents` | Agent registry (id, name, providerId, model, persona) | `AgentRepository` |
| `providers` | LLM provider configs (baseUrl, apiKey, models) | `ProviderEntryRepository` |
| `agent_soul` | Per-agent identity/profile fields | `AgentSoulRepository` |
| `agent_memory` | Per-agent long-term memory entries | `AgentMemoryRepository` |
| `agent_events` | Runtime events / heartbeat data | `AgentEventRepository` |
| `modules` | Installed module registry | `ModuleEntryRepository` |
| `app_settings` | App-wide preferences (theme, language) | `AppSettingsRepository` |
| `chat_messages` | Chat history per agent | `ChatHistoryService` |
| `task_ledger` | Active/completed task tracking | `TaskLedgerDatabase` |

### 2.2 Workspace Folder (User Files Only)

```
/Documents/MeowAgent/Agents/{AgentName}/
├── (user-uploaded files, PDFs, exports)
└── (NO SOUL.md, NO MEMORY.md, NO SKILLS.md, NO HEARTBEAT.md)
```

The workspace folder is **strictly for user files**. The agent can read/write here via `files.*` tools when the user explicitly asks (e.g., "read the PDF in your workspace"). No runtime-critical data lives here.

### 2.3 Legacy → Current Migration Map

| Before (legacy) | After (Phase 7) |
|-----------------|------------------|
| `meow.json` agents array | `agents` table |
| `meow.json` providers array | `providers` table |
| `SOUL.md` in workspace | `agent_soul` table |
| `MEMORY.md` in workspace | `agent_memory` table |
| `HEARTBEAT.md` in workspace | `agent_events` table |
| `SharedPreferences` for settings | `app_settings` table |
| File-based chat history | `chat_messages` table |

---

## 3. Runtime Engine Architecture

### 3.1 Runtime Loop

```
User Message
    │
    ▼
┌─────────────┐     ┌──────────────┐     ┌───────────────┐
│  Analyzer   │────▶│  Reflector   │────▶│    Planner    │
│ (intent +   │     │ (impact +    │     │ (goal tree +  │
│  language)  │     │  slots)      │     │  subgoals)    │
└─────────────┘     └──────────────┘     └───────────────┘
                                                │
                                                ▼
                                    ┌───────────────────┐
                                    │   Execute Loop    │
                                    │ (select → exec →  │
                                    │  review → repeat) │
                                    └───────────────────┘
                                                │
                                                ▼
                                         Final Response
```

### 3.2 Key Engine Components

| Component | File | Responsibility |
|-----------|------|----------------|
| `AgentRuntimeEngine` | `runtime_engine.dart` | Orchestrates the full loop |
| `Planner` | `planner.dart` | LLM call: analyze intent |
| `Reflector` | `reflector.dart` | LLM call: impact analysis |
| `Executor` | `executor.dart` | Dispatches tool calls |
| `ToolVerbalizer` | `tool_verbalizer.dart` | LLM call: review results |
| `ExecuteLoopRunner` | `execute_loop_runner.dart` | Iterates select→exec→review |
| `GoalTree` | `goal_tree.dart` | Tracks multi-subgoal completion |
| `RuntimeMemory` | `runtime_memory.dart` | In-session tool result cache |
| `TaskScopeManager` | `task_scope_manager.dart` | Task lifecycle + ledger |
| `ConfirmationManager` | `confirmation_manager.dart` | Sensitive tool gates |

### 3.3 Context Builder (Phase 5b)

The runtime engine builds LLM context from SQLite, not from files:

```dart
Future<AgentWorkspace> _buildWorkspace(String agentName, String agentId) async {
  // Reads from AgentSoulRepository → formats as markdown-like string
  // Reads from AgentMemoryRepository → formats grouped entries
  // Returns AgentWorkspace { soul, memory, skills, heartbeat }
}
```

The prompt templates receive the same `AgentWorkspace` shape — they don't know the data came from SQLite vs files.

---

## 4. Tool System

### 4.1 Self-Registering Module Plugins

Each feature module = one Dart file implementing `ModulePlugin`:

```dart
abstract class ModulePlugin {
  String get moduleId;
  String get catalogGroup;
  List<ToolDefinition> get toolDefinitions;
  Future<ToolExecutionResult> dispatch(ToolCallRequest request, ModuleToolContext ctx);
}
```

All plugins are listed in `runtime_module_plugins.dart`. **No central registry map, no dispatch switch to edit.**

### 4.2 Tool Dispatch Flow

```
LLM selects tool → ToolRouter.dispatch()
    │
    ├─ Looks up plugin by tool name prefix
    ├─ Builds ModuleToolContext (repos, agentId, etc.)
    └─ Calls plugin.dispatch(request, ctx)
         │
         └─ Plugin executes → returns ToolExecutionResult
```

### 4.3 Key System Tools (Phase 7)

| Tool | Data Source | Notes |
|------|-------------|-------|
| `system.profile.update` | `agent_soul` table | Updates identity fields (name, timezone, etc.) |
| `system.memory.append` | `agent_memory` table | Appends fact/preference/bookmark entries |
| `system.config.read` | `meow_core.db` various tables | Reads ecosystem snapshot |
| `system.config.patch` | `meow_core.db` | Creates/deletes agents, providers |
| `system.workspace.read` | Filesystem (user files) | Reads user-uploaded files in workspace |
| `system.self` | Combined DB + filesystem | Returns current agent info |

---

## 5. Prompt Architecture

### 5.1 Prompt Files

| File | Phase |
|------|-------|
| `prompt_system.dart` | System-level rules |
| `prompt_analyze.dart` | Analyzer phase (world model, routing rules) |
| `prompt_reflect.dart` | Reflector phase (impact, slots) |
| `prompt_plan.dart` | Planner phase |
| `prompt_execute.dart` | Tool selector & reviewer |
| `prompt_context.dart` | Chat, compactor, repair, memory, workflow API |
| `prompt_constants.dart` | Central accessor class |

### 5.2 World Model (LLM-Facing)

The LLM is told:
- Identity data → stored in local database → managed via `system.profile.update`
- Memory data → stored in local database → managed via `system.memory.append`
- Workspace folder → user files only (documents, PDFs, exports)
- **No references to SOUL.md, MEMORY.md, SKILLS.md, or HEARTBEAT.md**

### 5.3 Action Map

`action_map.dart` defines canonical intent→tool routing:
- `edit persona` → `system.profile.update` (NOT `files.write`)
- `remember fact` → `system.memory.append` (NOT `files.write`)
- `create agent` → `system.config.patch`

---

## 6. State Management (Riverpod)

### 6.1 Key Providers

| Provider | Type | Purpose |
|----------|------|---------|
| `agentListProvider` | `StateNotifierProvider` | Agent list from SQLite |
| `providerListProvider` | `StateNotifierProvider<AsyncValue>` | Provider configs |
| `agentSoulProvider` | `StreamProvider.family` | Reactive soul per agent |
| `agentMemoryStreamProvider` | `StreamProvider.family` | Reactive memory per agent |
| `chatMessagesProvider` | `NotifierProvider.family` | Chat messages per agent |
| `agentRuntimeEngineProvider` | `Provider` | Singleton runtime engine |
| `meowDatabaseProvider` | `Provider` | Singleton DB instance |

### 6.2 Initialization Sequence

```dart
void main() async {
  // 1. Pre-warm SQLite database
  await MeowDatabase.instance.database;
  
  // 2. Initialize Riverpod container
  runApp(ProviderScope(child: MeowApp()));
  
  // 3. AgentListNotifier.ready future ensures data is loaded
  //    before any UI reads agents
}
```

### 6.3 Race Condition Guards

| Guard | Location | Purpose |
|-------|----------|---------|
| DB pre-warm in `main()` | `main.dart` | DB ready before first frame |
| `AgentListNotifier.ready` | `agent_repository.dart` | Consumers await agent list |
| `providerListProvider.notifier.load()` | `chat_runtime_manager.dart` | Provider list populated before resolution |

---

## 7. Error Handling

### 7.1 LLM Error Mapper

`LlmErrorMapper` converts all provider/network exceptions into user-friendly localized messages:

| Exception Type | User Message Key |
|---------------|------------------|
| 401 Unauthorized | `runtime_provider_auth_failed` |
| 429 Rate Limited | `runtime_provider_rate_limited` |
| 5xx Server Error | `runtime_provider_server_error` |
| Timeout | `runtime_provider_timeout` |
| Network / Socket | `runtime_provider_network_error` |
| All other | `runtime_provider_unknown_error` |

Error messages are prefixed with `[[PROVIDER_ERROR]]` sentinel so the runtime can strip them from future LLM context (prevents the model from parroting "I can't connect" on subsequent turns).

### 7.2 Non-Fatal Filesystem Operations

All workspace file I/O is wrapped in try/catch and returns gracefully on failure:
- `WorkspaceLoader.load()` → returns empty workspace
- `updateHeartbeat()` → silent fail
- `ensureWorkspace()` → silent fail
- `maybeFillPreferredLanguage()` → silent fail

This ensures the runtime never surfaces "Permission denied" errors to users when the workspace folder isn't accessible.

---

## 8. File Structure (Key Paths)

```
lib/
├── core/storage/
│   ├── meow_database.dart          # SQLite schema + migrations
│   ├── meow_database_provider.dart # Riverpod DB provider
│   ├── core_storage_providers.dart # Barrel file for all repos
│   ├── agent_repository.dart       # Agent CRUD (core DB)
│   ├── agent_soul_repository.dart  # Identity fields
│   ├── agent_memory_repository.dart # Long-term memory
│   ├── provider_repository.dart    # LLM provider entries
│   ├── agent_event_repository.dart # Events/heartbeat
│   ├── app_settings_repository.dart # Global settings
│   └── module_entry_repository.dart # Module registry
├── services/
│   ├── agent_runtime/
│   │   ├── runtime_engine.dart     # Main engine
│   │   ├── workspace_loader.dart   # Returns empty (Phase 7)
│   │   ├── system_tools.dart       # Core tool class + parts
│   │   ├── system_tools_workspace.dart # profile.update, memory.append
│   │   ├── prompt_analyze.dart     # World model for LLM
│   │   ├── action_map.dart         # Intent→tool canonical map
│   │   ├── module_plugin.dart      # Plugin interface + context
│   │   └── tool_router.dart        # Dispatch hub
│   ├── llm/
│   │   ├── openai_compatible_client.dart
│   │   └── llm_error_mapper.dart
│   └── workspace/
│       ├── workspace_file_service.dart # File I/O (user files only)
│       └── workspace_paths.dart        # Path resolution
├── features/
│   ├── agents/data/
│   │   ├── agent_repository.dart   # AgentListNotifier (legacy bridge)
│   │   └── agent_model.dart
│   ├── providers/data/
│   │   ├── provider_repository.dart # ProviderListNotifier
│   │   └── provider_config.dart
│   ├── chat/
│   │   ├── data/chat_runtime_manager.dart # Orchestrates send flow
│   │   └── presentation/chat_screen.dart
│   └── modules/
│       ├── system/system_module.dart # System tools plugin
│       └── ...other modules
└── main.dart                        # App entry, DB pre-warm
```

---

## 9. Known Constraints & Decisions

1. **No file-based identity/memory** — All identity (soul) and memory data lives in SQLite. The workspace folder is for user files only.

2. **`meow.json` is fully retired** — All configuration (prefs, active selection, modules, agents, providers) lives in `meow_core.db`. Legacy SharedPreferences keys are migrated once on first boot via `LegacyMigration.runOnce` (gated by `migration.legacy_v1_completed` in `app_settings`).

3. **`WorkspaceFolderService` only ensures the user-files folder exists** — Identity/memory live in SQLite. The folder is created lazily on first `files.*` tool use.

4. **`system.workspace.read` reads user files from the workspace folder** — Not for identity/memory.

5. **Module plugins are self-registering** — Adding a tool = one file. No central dispatch switch.

6. **Prompts are English-only** — The LLM responds in the user's detected language naturally. No per-language prompt variants.

7. **`AgentSoulRepository.updateField()` requires an existing row** — The `agents` table INSERT trigger creates a default `agent_soul` row. If a soul row is missing (edge case), the runtime renders a placeholder scaffold and triggers the introduction gate.

8. **`system.config.read`/`patch` are SQLite-backed** — The LLM-facing tools synthesize a `meow.json`-shaped snapshot from `app_settings` + `agents` + `providers` + `modules` tables. `system.config.patch` accepts only `/prefs/*`, `/activeAgentId`, `/activeProviderId`, and `/modules/<id>/{enabled,settings}` paths. Agents and providers must use their dedicated domain tools (`agent.create`, `provider.create`, etc.).

---

## 10. Testing

### Real LLM Tests

Located at `test/runtime_real_llm_test.dart`. Uses live provider from `.env`:

```
MEOW_TEST_BASE_URL=https://...
MEOW_TEST_API_KEY=sk-...
MEOW_TEST_MODEL=deepseek-v4-flash
```

Tests R1–R20 cover: simple reads, writes, multi-target, language detection, sensitive tool gating, failed tool honesty, bulk predicates, conversational responses, and more.

### Test Support

- `ScriptedToolRouter` — canned tool results, no real device calls
- `FakeWorkspaceLoader` — returns configurable workspace
- `EnvLoader` — reads `.env` for credentials
- `sqflite_common_ffi` — in-memory SQLite for tests
