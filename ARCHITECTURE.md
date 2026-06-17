# ARCHITECTURE_2.md — Meow Agent Runtime, LLM & Agent Architecture

> The technical map of how Meow Agent thinks and acts: the agentic runtime,
> the LLM client, the tool/permission system, and the data layer — with flow
> charts grounded in the current source.
>
> Companion: **[AGENTS_2.md](./AGENTS_2.md)** (dev rules), **[DESIGN_2.md](./DESIGN_2.md)** (UI).
> Status: runtime-v4 (SQLite-backed, prefix-gated permissions, cancellable LLM calls).

---

## 1. Stack Overview

```
┌──────────────────────────────────────────────────────────────┐
│                       Flutter UI Layer                         │
│        Chat · Agents · Providers · Modules · Settings          │
├──────────────────────────────────────────────────────────────┤
│                     Riverpod State Layer                       │
│        Providers · StateNotifiers · StreamProviders            │
├──────────────────────────────────────────────────────────────┤
│                    Agentic Runtime Engine                      │
│   Analyze → Reflect → Plan → Execute Loop → Verbalize          │
├──────────────────────────────────────────────────────────────┤
│                  Tool Router + Module Plugins                  │
│        16 self-registering ModulePlugins · 2-layer gate        │
├──────────────────────────────────────────────────────────────┤
│                       Data Layer (SQLite)                      │
│   meow_core.db (single source) + flutter_secure_storage keys   │
└──────────────────────────────────────────────────────────────┘
```

Android-native AI companion built with Flutter. Multi-agent runtime that
automates device actions, manages notes/calendar/files, and drives other apps
via Accessibility Services. All paths below are relative to `lib/`.

---

## 2. The Runtime Loop

`AgentRuntimeEngine.run()` (`services/agent_runtime/runtime_engine.dart:341`)
orchestrates every turn. **L** = LLM call, **D** = deterministic.

```
                          User Message
                               │
                               ▼
        ┌──────────────────────────────────────────────┐
        │ 0. Reset cancel flag + register CancelToken (D)│
        │ 1. Idle-session summarize (L, best-effort)     │
        │ 2. Language bootstrap — Unicode script (D)     │
        │ 3. Ledger resume + pending-action check (D)    │
        │ 4. Vision / attachment context (D)             │
        │ 5. Tool preselect — ToolCatalog.select (D)     │
        └───────────────────────┬────────────────────────┘
                                │
                                ▼
                  ┌─────────────────────────┐
                  │ 6. ANALYZE (L)          │  intent, requires_tools,
                  │    Planner.analyze()    │  tool_groups, missing_info,
                  └────────────┬────────────┘  subgoal_seeds, language, risk
                               │
                  7. refine language (D) · 8. re-narrow tools (D)
                               │
                  ┌────────────┴────────────┐
                  │ 9. missing info?        │──yes──▶ ASK user (D, early return)
                  └────────────┬────────────┘
                               │ no
              ┌────────────────┴────────────────┐
              │ requires_tools?                  │
              └──────┬───────────────────┬───────┘
                  no │                   │ yes
                     ▼                   ▼
          ┌──────────────────┐   ┌──────────────────────────┐
          │ 11. DIRECT (L)   │   │ 10. REFLECT (L, skippable)│ strategy, goal tree,
          │  conversational  │   │     Reflector.reflect()   │ targets, impacts
          └──────────────────┘   └────────────┬─────────────┘
                                               │
                                  ┌────────────┴────────────┐
                                  │ 12. PLAN (L, skippable)  │ goal tree + subgoals
                                  │     Planner.plan()       │ (synthesized if skip)
                                  └────────────┬─────────────┘
                                               │
                                  ┌────────────┴────────────┐
                                  │ 13. build GoalTree (D)   │
                                  └────────────┬─────────────┘
                                               │
                                  ┌────────────┴─────────────────┐
                                  │ 14. EXECUTE LOOP             │
                                  │     ExecuteLoopRunner.run()  │
                                  └────────────┬─────────────────┘
                                               │
                                  15. memory extraction (L, best-effort)
                                               │
                                               ▼
                                  Final Response (via ToolVerbalizer)
```

### 2.1 Skip conditions (cost control — "efficient ≠ stingy")

| Phase | Skipped when |
|-------|--------------|
| **Reflect** (`canSkipReflect`, `runtime_engine.dart:855`) | `requires_tools` AND not workflow-auto AND tool selection confidence ≥0.75 AND exactly 1 tool group AND no missing_info AND not bulk AND not destructive AND snapshot not relevant |
| **Plan** (`canSkipPlanner`, `:1016`) | not pending AND not workflow-auto AND high-confidence AND 1 group AND no missing_info AND no multi-target → synthesizes a 1-step plan locally |
| **Fast-path** (`:1025`) | `canSkipPlanner && canSkipReflect` → loop hard-capped at 2 iters, falls back to normal mode on exhaustion |
| **Review** (in loop, `execute_loop_runner.dart:992`) | `result.success && isLastPlannedStep && wouldCompleteTree` → verbalize directly, no review LLM call |

---

## 3. The Execute Loop

`ExecuteLoopRunner.run()` (`execute_loop_runner.dart:29`) — the step machine.
Adaptive iteration budget: `maxSteps` (5) scaling with subgoal count, capped at
`maxSteps*3`; fast-path capped at 2.

```
  ┌─▶ per iteration ────────────────────────────────────────────┐
  │  cancel check (cooperative) ─── cancelled ──▶ bail, hide UI  │
  │       │                                                       │
  │       ▼                                                       │
  │  SELECT next tool                                             │
  │   ├─ fast-path: chatWithTools (native function calling)       │
  │   └─ fallback:  selectTool JSON  (LlmJsonCaller)              │
  │       │                                                       │
  │       ▼                                                       │
  │  guards: off-path soft-guard · stuck detector (semantic) ·    │
  │          premature-done guard · duplicate-delivery guard      │
  │       │                                                       │
  │       ▼                                                       │
  │  PERMISSION gate (ToolRouter) ─── denied ──▶ localized denial │
  │       │                                                       │
  │       ▼                                                       │
  │  CONFIRMATION gate ─── requiresConfirmation ──▶ park + card   │
  │       │                                                       │
  │       ▼                                                       │
  │  EXECUTE (plugin.dispatch)                                    │
  │       │                                                       │
  │       ▼                                                       │
  │  VERIFY (PostExecuteValidator, on success) ─ unverified ─▶ recover
  │       │                                                       │
  │       ▼                                                       │
  │  REVIEW (LLM) — or short-circuit verbalize if terminal        │
  │       │                                                       │
  │       ▼                                                       │
  │  GoalTree update → done? ── no ──┘   yes ──▶ verbalize final  │
  └──────────────────────────────────────────────────────────────┘
```

---

## 4. Components

| Component | File | Responsibility |
|-----------|------|----------------|
| `AgentRuntimeEngine` | `runtime_engine.dart:341` | Orchestrates the full turn |
| `Planner` | `planner.dart:12` | LLM analyze + plan (JSON via `LlmJsonCaller`) |
| `Reflector` | `reflector.dart:207` | LLM deep-think: strategy, goal tree, targets, impacts; degrades to directExecute on failure |
| `Executor` | `executor.dart:13` | LLM tool selection (`selectTool`, `selectToolViaFunctionCalling`) + result `review` |
| `ExecuteLoopRunner` | `execute_loop_runner.dart:29` | The step loop: select→guards→gate→execute→verify→review; recovery |
| `ToolRouter` | `tool_router.dart:25` | Validate, enforce confirm/permission gates, dispatch to plugin |
| `ToolCatalog` | `tool_catalog.dart:24` | Deterministic tool shortlisting from analyzer `tool_groups` |
| `GoalTree` | `goal_tree.dart:113` | Subgoal tree: `nextActionable`, `isComplete`, status updates |
| `TaskScopeManager` | `task_scope_manager.dart:17` | Ledger lifecycle, cancellation flags + tokens, park-for-input |
| `ConfirmationManager` | `confirmation_manager.dart:35` | Pending-action state, confirmation decisions, ledger restore |
| `RecoveryCoordinator` | `recovery_coordinator.dart:82` | Bounded retry/replan vs give-up (max 2); tracks prior attempts |
| `PostExecuteValidator` | `post_execute_validator.dart:95` | Anti-hallucination probe after success |
| `RuntimeMemory` | `runtime_memory.dart:12` | Per-agent tool-result scratchpad (max 8, 30-min prompt window) |
| `TargetResolver` | `target_resolution.dart:39` | Resolve reflection targets vs live snapshot |
| `EcosystemSnapshotBuilder` | `ecosystem_snapshot.dart:163` | Live snapshot: agents/workflows/providers/modules |
| `ContextBuilder` / `WorkspaceContextBuilder` | `context_builder.dart` / `workspace_context_builder.dart` | Build LLM context from SQLite |
| `ToolVerbalizer` | `tool_verbalizer.dart:20` | LLM user-facing copy in detected language; per-turn cache |
| `LanguageDetector` | `language_detector.dart:57` | Unicode-script detection; Latin→fallback (no LLM) |
| `LlmJsonCaller` | `llm_json_caller.dart:12` | Shared JSON LLM call with one repair retry |
| `ContextCompactor` | `context_compactor.dart:7` | Token estimate + LLM summarize at 80% of max context |

---

## 5. LLM Client

`services/llm/openai_compatible_client.dart` — a single OpenAI-compatible HTTP
client (other providers work via an OpenAI-compatible base URL).

### 5.1 Methods

| Method | Purpose |
|--------|---------|
| `chat()` (`:155`) | Standard completion; supports inline `imageDataUrls` (multipart on last user msg); normalizes XML tool-calls → JSON |
| `chatWithTools()` (`:247`) | Native function calling; sends `tools` + `tool_choice`; returns `null` → caller falls back to JSON selector |
| `chatWithImage()` (`:336`) | Single vision turn (text + image_url) |
| `testConnection()` / `testVisionSupport()` | Setup-screen credential/vision probes |

### 5.2 Timeouts & cancellation

- **Timeouts** (`_defaultDio`, `:58`): connect 30s, receive 120s, send 30s. A
  stalled provider can no longer hang a turn forever.
- **Cancellation**: every method takes a `CancelToken?` threaded to Dio. `run()`
  registers a per-turn token with `TaskScopeManager` (`runtime_engine.dart:348`);
  `TaskScopeManager.cancel()` aborts the in-flight HTTP call immediately. A
  user-cancel surfaces as `DioException` where `CancelToken.isCancel(e)` is true
  → mapped to a silent empty failure (`runtime_engine.dart:1262`), so no
  duplicate error bubble (the chat manager already posted the cancel message).

### 5.3 Error mapping

`llm_error_mapper.dart` `friendlyMessage()` maps exceptions to localized copy,
prefixed with the `[[PROVIDER_ERROR]]` sentinel:

| Exception | Message key |
|-----------|-------------|
| timeout | `runtime_provider_timeout` |
| connection/socket | `runtime_provider_network_error` |
| 401 | `runtime_provider_auth_failed` · 403 forbidden · 404 model_not_found · 400 bad_request |
| 429 | `runtime_provider_rate_limited` |
| ≥500 | `runtime_provider_server_error` |
| other | `runtime_provider_unknown_error` |

The sentinel lets the runtime strip stale error turns from future LLM context
(`runtime_engine.dart:490`, `execute_loop_runner.dart:110`) so the model never
parrots "I can't connect" on later turns.

### 5.4 Provider config & API keys

`run()` builds `LlmProviderConfig` from `ProviderConfig` (`:355`): `baseUrl`,
`apiKey`, `model`, `supportsFunctionCalling`. The raw key is **never** in
SQLite — it lives in `flutter_secure_storage` under `meow.provider_key.<id>`
(`SecureStorageService`). The `providers.api_key_ref` column holds only the
reference. Both the UI path (`provider_repository.dart:24`) and the agent tool
path (`provider_domain_module.dart`) use the same scheme, so a tool-created
provider resolves correctly and securely.

---

## 6. Tool System

### 6.1 Self-registering ModulePlugin

```dart
abstract class ModulePlugin {
  String get moduleId;
  String get catalogGroup;
  List<ToolDefinition> get toolDefinitions;
  List<String> get capabilityHints;       // English-only shortlist hints
  Future<ToolExecutionResult> dispatch(ToolCallRequest req, ModuleToolContext ctx);
}
```

Adding a tool/module = ONE file + one line in `runtime_module_plugins.dart`.
**No central dispatch switch, registry map, or catalog map to hand-edit** — the
`ModuleRegistry` derives all three. There are **16 plugins**
(`runtime_module_plugins.dart:20`): AppAgent, Device, Notification, Notes, Files,
Calendar, Workflow, AgentDomain, ProviderDomain, System, SqliteQuery, Chat,
Attachment, Web, Vm, Communication.

`ModuleToolContext` (`module_plugin.dart:22`) is built fresh per dispatch from
live router fields, carrying repos, `secureStorage`, attachments, and the agent
id/name so identity stays current across turns.

### 6.2 ToolDefinition (key fields, `runtime_models.dart:199`)

`name`, `description`, `risk`, `requiresConfirmation`, `inputSchema`,
`operation`, `targetEntity`, `selectorArgs`, `policies`, `postconditions`,
`isRetrieval`, `hiddenFromModel`, `verificationProbe`.

`risk` and `requiresConfirmation` are **authoritative from the registry, never
from the LLM** (`tool_router.dart:99`, `executor.dart:131`).

| Risk | Behavior |
|------|----------|
| `safe` | read-only → auto-execute |
| `sensitive-lite` | low-risk side effect (toggle, pin, append) → auto-execute |
| `sensitive` | side effect (write, open, create) → confirmation card |
| `dangerous` | destructive/irreversible → confirmation + extra warning |

### 6.3 Dispatch flow

```
LLM selects tool → ToolRouter.execute()
   ├─ validate (registered?)                    ── no ──▶ error
   ├─ permission gate (ToolPermissionPolicy)     ── deny ─▶ localized denial
   ├─ confirmation gate (requiresConfirmation)   ── yes ──▶ REQUIRES_CONFIRMATION (park)
   └─ _dispatch → registry.pluginFor(name).dispatch(req, ctx)
                                                          └─▶ ToolExecutionResult
```

`forceExecute()` (post-approval) skips the confirmation gate **but still checks
permission**.

### 6.4 Two-layer permission gate

A tool with **no** matching requirement **fails OPEN** (allowed). The gate is
opt-in coverage, backed by a coverage test.

**Layer 1 — exact map** (`tool_permission_requirements.dart:12`):
`toolPermissionRequirements[toolName]` →
`{moduleId, settingKey, settingLabel, actionLabel, androidPermission?}`.

**Layer 2 — prefix rule** (`toolPermissionPrefixRequirements`, `:545`):
`'app_agent.'` → the single `super_power` / `app_agentic` toggle gates the
entire `app_agent.*` family. One toggle ON = allow every on-screen action; new
`app_agent.*` tools are covered automatically and can never silently fail open.

**Resolution** (`tool_permission_policy.dart:_requirementFor`): exact lookup
first, then prefix scan. `check()` verifies in order:

```
module installed? ─no─▶ moduleMissing
       │ yes
module enabled?   ─no─▶ moduleDisabled
       │ yes
setting toggle on? ─no─▶ settingDisabled
       │ yes
android perm granted? ─no─▶ androidPermissionDenied
       │ yes
     ALLOW
```

Denied → `ToolExecutionResult` with `errorCode: 'module_permission_denied'`.

**Coverage guard**: `test/tool_permission_coverage_test.dart` asserts every
registered tool is gated (exact or prefix) OR in a documented
`intentionallyUngated` allowlist, plus no orphan gates and no dead prefix rules.
This closes the fail-open class for good.

---

## 7. Data Layer

### 7.1 `meow_core.db` (SQLite — single source of truth)

`core/storage/meow_database.dart`. No `meow.json`, no file-based identity/memory.

| Table | Purpose | Repository |
|-------|---------|-----------|
| `app_settings` | key/value (language, active agent, theme) | `AppSettingsRepository` |
| `providers` | LLM endpoints; `api_key_ref` = opaque token, not raw key | `ProviderEntryRepository` |
| `agents` | agent rows (provider FK, model, max_context, auto_compact) | `AgentRepository` |
| `agent_soul` | structured identity (replaces SOUL.md) | `AgentSoulRepository` |
| `agent_memory` | append-only facts (fact/preference/bookmark/session) | `AgentMemoryRepository` |
| `agent_events` | activity/heartbeat stream | `AgentEventRepository` |
| `modules` | installed plugins, enable/config | `ModuleEntryRepository` |
| `agent_module_permissions` | per-agent module overrides | `ModuleEntryRepository` |
| `chat_messages` | chat history per agent | `ChatHistoryService` |
| `task_ledger` | active/completed task tracking | `TaskLedgerDatabase` |

### 7.2 Secrets

API keys live in `flutter_secure_storage` via `SecureStorageService`
(`secure_storage_service.dart`), keyed `meow.provider_key.<id>`. The raw key is
never written to SQLite (the column holds only the reference).

### 7.3 Workspace folder (user files only)

```
/Documents/MeowAgent/Agents/{AgentName}/
└── user-uploaded files, PDFs, exports   (NO SOUL.md / MEMORY.md / etc.)
```

The agent reads/writes here via `files.*` tools only when the user asks. No
runtime-critical data lives here; identity/memory are in SQLite.

---

## 8. State Management (Riverpod)

| Provider | Type | Purpose |
|----------|------|---------|
| `agentListProvider` | StateNotifierProvider | Agent list from SQLite |
| `providerListProvider` | StateNotifierProvider<AsyncValue> | Provider configs |
| `agentSoulProvider` | StreamProvider.family | Reactive soul per agent |
| `agentMemoryStreamProvider` | StreamProvider.family | Reactive memory per agent |
| `chatMessagesProvider` | NotifierProvider.family | Chat messages per agent |
| `agentRuntimeEngineProvider` | Provider | Singleton runtime engine |
| `meowDatabaseProvider` | Provider | Singleton DB |
| `secureStorageProvider` | Provider | Secure key store |

**Init sequence** (`main.dart`): pre-warm SQLite → `ProviderScope` →
`AgentListNotifier.ready` ensures agents are loaded before any UI reads them.
Race guards: DB pre-warm in `main()`, `AgentListNotifier.ready`,
`providerListProvider.notifier.load()` before resolution in the chat manager.

---

## 9. Anti-Hallucination & Resilience

| Guard | Location | What it does |
|-------|----------|--------------|
| `verificationProbe` | `runtime_models.dart:278` | Per-tool probe: `tool_result_data` / `snapshot_contains` / `snapshot_absent` / `none` |
| `PostExecuteValidator` | `post_execute_validator.dart:95` | On success, re-reads state and confirms the mutation landed; `unverified` → recovery |
| `CompletionVerifier` | `completion_verifier.dart:57` | Gates `status=done`; blocks → parks + asks user |
| `StuckDetector` | `goal_tree.dart:227` | Same (tool+target) ×3 (semantic key) → one re-plan, then recovery, then abort |
| `RecoveryCoordinator` | `recovery_coordinator.dart:82` | Max 2 attempts; repeating-failure short-circuit; feeds `prior_attempts` to reflector |
| Premature-done guard | `execute_loop_runner.dart:279` | `status=done` while tree incomplete → inject error note; ≥2 abort, ≥3 synthesize |
| Narrative dedup | `execute_loop_runner.dart:1547` | Suppress repeated POV-AI sentences (window 4) — kills "thinking" loops |
| Cancellation | `runtime_engine.dart:348`, loop `:132` | Per-iter cooperative check + in-flight HTTP abort |
| Provider-error sentinel | `llm_error_mapper.dart:18` | Strips stale "I can't connect" from future context |
| Off-path soft guard | `execute_loop_runner.dart:500` | Rejects canonical-path violations once (action_map) |
| Duplicate-delivery guard | `execute_loop_runner.dart:771` | Suppresses repeat `chat.send` / `notification.create_local` |
| Empty-result guard | `execute_loop_runner.dart:1094` | A zero-match retrieval IS the answer → force done, no re-search |

---

## 10. Prompt Architecture

`prompt_constants.dart` is the central accessor (`PromptConstants`), delegating
to per-phase files. `promptVersion` is logged with every LLM decision.

| File | Phase |
|------|-------|
| `prompt_system.dart` | System rules, introduction gate |
| `prompt_analyze.dart` | Analyzer (requires_tools, tool_groups, selectors) |
| `prompt_reflect.dart` | Reflector (strategy, goal tree, targets) |
| `prompt_plan.dart` | Planner (goal-tree building) |
| `prompt_execute.dart` | Tool selector + reviewer |
| `prompt_context.dart` | Chat, compactor, repair, pending, memory, narrative-field rule |
| `prompt_policy.dart` | Reusable policy blocks (Ask/Ground/Minimal/Recover/Voice) |
| `prompt_workflow.dart` | Workflow auto-execute prompts |
| `prompt_templates.dart` | Assembles final prompts |

**English-only by design.** All scaffolding/examples are English; the user's
language is injected separately via `systemRules(language)` + `DetectedLanguage`
and rendered by `ToolVerbalizer` / `NarrativeNarrator`. System rules are cached
by `language|isWorkflowAutoExecute` — workflow runs get a distinct ruleset
("no user reading this", sensitive pre-approved, fail-don't-ask) vs interactive
(ask-vs-confirm policy). See AGENTS_2.md §2 for the authoring rules.

### 10.1 Two language layers (never crossed)

```
UI copy            →  AppStrings (id/en)            →  widgets
agent spoken lang  →  DetectedLanguage + Verbalizer →  chat
prompt scaffolding →  prompt_* (English only)       →  LLM
```

---

## 11. Confirmation vs Clarification

Two distinct paths the agent must not conflate:

- **Missing detail** (ambiguous time, vague title, unclear target) → ASK a plain
  clarifying question; park `PendingClarification`, persist ledger, resume on
  answer.
- **Sensitive action** (detail complete, side effects) → CALL the tool; the
  runtime renders a confirmation card. Do NOT ask "are you sure?" in text.

Confirmation flow: `requiresConfirmation` → store `PendingAction` → UI card →
Confirm (`executeConfirmed` → `forceExecute`) / Reject (`clearPendingAction`) /
typed reply (`ConfirmationChecker.check`).

---

## 12. Key Decisions

1. **No file-based identity/memory** — all in SQLite; workspace folder is user
   files only.
2. **`meow.json` retired** — all config in `meow_core.db`; legacy prefs migrated
   once via `LegacyMigration.runOnce`.
3. **Self-registering modules** — one file per tool/module.
4. **Prompts English-only** — language handled by the LLM via detected language.
5. **Permissions opt-in & gated** — fail-open is prevented by the coverage test;
   `app_agent.*` governed by one prefix-rule toggle.
6. **API keys in secure storage** — never plaintext in SQLite, same scheme for UI
   and agent tool paths.
7. **LLM calls are bounded & cancellable** — explicit Dio timeouts + per-turn
   `CancelToken`.
8. **Not Play-Store-bound** — Accessibility automation allowed; user controls
   every permission.

---

## 13. Testing

| Suite | File | Gate |
|-------|------|------|
| Golden end-to-end | `test/runtime_golden_test.dart` | phase sequence, tool sequence, no-hallucination |
| Module drift | `test/module_plugin_test.dart` | registry/catalog in sync |
| Permission coverage | `test/tool_permission_coverage_test.dart` | no fail-open, no orphan/dead gates |
| Real-LLM flow | `test/runtime_real_llm_test.dart` | live `.env` provider (no-op without creds) |

Test support: `ScriptedToolRouter` (canned results), `EnvLoader` (.env creds),
`sqflite_common_ffi` (in-memory SQLite). Credentials live in gitignored `.env` —
never hardcode or commit.
