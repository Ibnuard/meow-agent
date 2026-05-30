# SKILLS.md — Meow Agent Codebase Guide

> The canonical codebase guide for Meow Agent. All coding agents MUST read and follow this document.

---

## Core Principles (READ FIRST)

1. **Accuracy is #1.** The agent must never hallucinate a capability it doesn't have or claim success it can't verify. When data is missing or a capability doesn't exist, tell the user honestly and quickly — do not retry/guess/fabricate.
2. **Language-generic, always.** NO per-language word lists, NO per-case patches ("kalau user bilang X, lakukan Y"), NO Indonesian-specific examples in routing/classification code. The engine works across ALL languages equally. Examples in prompts use English only; the LLM handles the user's language naturally.
3. **LLM-driven classification, not keyword-matching.** Tool selection is driven by the analyzer LLM's `tool_groups` enum, not by hardcoded keyword sets. The analyzer sees every tool and decides which group(s) cover the request — language-agnostic and semantic.
4. **More LLM calls are OK if they improve accuracy — but zero wasted calls.** The engine skips provably redundant phases (reflect for trivial safe reads, review for terminal retrievals) while keeping deep-thinking for destructive/multi-entity/cross-reference turns. Efficient ≠ stingy.
5. **Validation before declaration.** A task is only "done" after state re-check (snapshot probe, registry re-read, tool result data keys) confirms it. Never trust the LLM's self-report alone.
6. **Self-registering modules.** Adding a tool or module = creating ONE file (a `ModulePlugin`). There is no central registry map, dispatch switch, or catalog group map to hand-edit.

---

## Architecture Overview

```
lib/
├── main.dart
├── app/                                    # UI: theme, router, widgets
├── core/storage/                           # Local storage
├── features/
│   ├── chat/                               # Chat UI + runtime manager
│   ├── agents/                             # Agent management UI
│   ├── providers/                          # LLM provider config UI
│   ├── settings/                           # App settings
│   └── modules/
│       ├── data/                           # ModuleModel, ModuleRepository
│       ├── <module_name>/                  # One folder per module
│       │   ├── <module>_module.dart        # ModulePlugin (self-registering)
│       │   ├── <module>_tools.dart         # Handler implementations
│       │   ├── <module>_models.dart        # Data classes
│       │   └── <module>_repository.dart    # Business logic + settings gate
│       └── presentation/                   # UI screens
├── services/
│   ├── llm/
│   │   └── openai_compatible_client.dart
│   └── agent_runtime/
│       ├── runtime_engine.dart             # Main agentic loop (3586→stable)
│       ├── runtime_models.dart             # ToolDefinition, ToolCallRequest, etc.
│       ├── runtime_module_plugins.dart     # ALL module plugins in one list
│       ├── module_plugin.dart              # ModulePlugin abstract class
│       ├── module_registry.dart            # Collects plugins → registry + catalog
│       ├── tool_router.dart                # Validation + dispatch (232 lines)
│       ├── tool_catalog.dart               # Shortlisting from analyzer tool_groups
│       ├── planner.dart                    # Analyzer (intent + tool_groups)
│       ├── executor.dart                   # Tool selector + reviewer
│       ├── reflector.dart                  # Deep-thinking impact/slot analysis
│       ├── target_resolution.dart          # Target resolution + bulk/predicate expansion
│       ├── ecosystem_snapshot.dart         # World model (agents/workflows/providers/modules)
│       ├── context_builder.dart            # Builds prompt context
│       ├── prompt_templates.dart           # Prompt assembly
│       ├── prompt_constants.dart           # All LLM prompt strings
│       ├── tool_verbalizer.dart            # LLM-driven user-facing messages
│       ├── language_detector.dart          # Script-based bootstrap + analyzer refinement
│       ├── language_registry.dart          # i18n for short deterministic phrases
│       ├── post_execute_validator.dart     # Anti-hallucination verification gate
│       ├── recovery_coordinator.dart       # Bounded retry + re-plan logic
│       ├── pending_action.dart             # Confirmation gate
│       └── workspace_loader.dart           # SOUL/MEMORY/SKILL/HEARTBEAT
```

---

## Agentic Runtime Loop

Flow per user turn (simplified — see `runtime_engine.dart` for exact conditions):

```
User Message
    │
    ▼
┌──────────────────────────┐
│ RuntimeEngine.run()       │
│  1. Bootstrap language    │  ← Script detection (non-Latin) or app fallback (Latin)
│  2. Load workspace        │
│  3. ToolCatalog.select()  │  ← Full catalog pre-analyze (no keyword matching)
└──────────┬───────────────┘
           │
           ▼
┌──────────────────────────┐
│ Planner.analyze()         │  ← LLM: intent, goal, risk, tool_groups, detected_language,
│   → Refine language       │     missing_info, subgoal_seeds, task_relation, bulk_selector
│   → Narrow tools from     │
│     tool_groups hint      │
└──────────┬───────────────┘
           │
    ┌──────┴──────┐
    │             │
    ▼             ▼
 No Tools     Tools Required
    │             │
    ▼             ├─ Reflect? (skipped for trivial safe single-tool reads)
 Direct         │     │
 Response       │     ▼
                │  ┌──────────────────┐
                │  │ Execute Loop      │  (adaptive budget: 5–15 iters)
                │  │  ├─ selectTool()  │  ← LLM picks next tool/marks done
                │  │  ├─ validate()    │  ← ToolRouter checks registry
                │  │  ├─ execute()     │  ← ToolRouter dispatches to plugin
                │  │  └─ review()      │  ← LLM reviews result (skipped for terminal retrievals)
                │  └──────────────────┘
                │         │
                ▼         ▼
         Final Response to User (via ToolVerbalizer)
```

---

## How to Add a New Tool (Post-Stage-3 Architecture)

### ONE file to create: a `ModulePlugin`

1. Create `lib/features/modules/<your_module>/<your_module>_module.dart`.
2. Extend `ModulePlugin`. Implement `moduleId`, `catalogGroup`, `toolDefinitions`, and `dispatch`.
3. Add the plugin instance to the list in `lib/services/agent_runtime/runtime_module_plugins.dart`.

That's it. The `ModuleRegistry` derives the tool registry, the catalog group map, and the dispatch index automatically. The `ToolRouter` dispatches to your plugin at runtime.

### Example: a minimal module

```dart
// lib/features/modules/hello/hello_module.dart
import '../../../services/agent_runtime/module_plugin.dart';
import '../../../services/agent_runtime/runtime_models.dart';

class HelloModulePlugin extends ModulePlugin {
  const HelloModulePlugin();

  @override String get moduleId => 'hello';
  @override String get catalogGroup => 'hello';

  @override
  List<String> get capabilityHints => const ['greet', 'hello'];

  @override
  List<ToolDefinition> get toolDefinitions => const [
    ToolDefinition(
      name: 'hello.greet',
      description: 'Greet the user by name.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'name': 'string (optional)'},
    ),
  ];

  @override
  Future<ToolExecutionResult> dispatch(ToolCallRequest req, ModuleToolContext ctx) {
    final name = (req.args['name'] as String?) ?? 'world';
    return Future.value(ToolExecutionResult(
      success: true,
      toolName: 'hello.greet',
      data: {'greeting': 'Hello, $name!'},
    ));
  }
}
```

Then in `runtime_module_plugins.dart`, add `HelloModulePlugin()` to the list.

### Risk Levels & ToolDefinition Metadata

- `safe` — read-only, no side effects → auto-execute
- `sensitive` — has side effects (write, open app, create) → confirmation card
- `dangerous` — destructive/irreversible → confirmation + extra warning
- `sensitive-lite` — side effects but low risk (toggle, pin, append) → auto-execute

Key ToolDefinition fields beyond the basics:
- `isRetrieval: true` — marks a read/list/search tool; retrieval results are the answer, triggers the grounded `answerFromToolResult` path, and exempts from mutation verification.
- `verificationProbe` — post-execute anti-hallucination gate. For `tool_result_data`, asserts expected keys exist in the response. For `snapshot_contains`/`snapshot_absent`, re-reads the ecosystem to confirm the mutation landed.
- `operation` / `targetEntity` / `selectorArgs` — drive target resolution, impact analysis, and bulk expansion.

Every mutating tool MUST have a `verificationProbe`. A tool reporting `success: true` without one is a gap.

---

## Tool Naming Convention

`namespace.action` (lowercase, dot-separated). Examples: `device.battery`, `notes.create`, `system.agents.list`.

---

## How to Add a New Module (Store-level)

A Module is a user-installable feature with settings toggles in the Module Store.

1. Define in `ModuleModel` (in `module_model.dart`): id, name, description, icon, default settings.
2. Create folder `lib/features/modules/<module_id>/` with:
   - `<module>_module.dart` — ModulePlugin (self-registering tool surface)
   - `<module>_models.dart` — data classes with `fromMap()` and `toJson()`
   - `<module>_service.dart` — MethodChannel wrapper (if native)
   - `<module>_repository.dart` — business logic + per-setting toggle check
3. Register the plugin in `runtime_module_plugins.dart`.
4. (If native) Kotlin plugin + `MainActivity.kt` registration.
5. (If native) permissions in `AndroidManifest.xml`.

---

## Language Detection Architecture

Two-tier, no per-language word lists:

1. **Bootstrap (LanguageDetector)**: Unicode script detection for non-Latin scripts → high-confidence instant mapping. For Latin script, returns the app setting as a provisional low-confidence fallback — no guessing between Latin languages.
2. **Refinement (analyzer LLM)**: The analyzer emits `detected_language` after reading the user's actual message. The engine overwrites the bootstrap with this authoritative value. All languages are detected equally — there is no special-casing for Indonesian, English, or any other language.

The `LanguageRegistry` is a separate i18n layer for short deterministic runtime phrases (16 languages, English fallback). It is NOT used for routing or classification.

---

## Prompt Rules

All prompt strings live in `prompt_constants.dart`. Assembly in `prompt_templates.dart`.

### Language-generic requirements
- Examples in prompts MUST be in English only.
- NEVER enumerate language-specific words ("semua/setiap/seluruh" or "all/every/each") as a fixed list. Describe the concept semantically ("any word meaning all/every/each in any language").
- The `tool_groups` enum the analyzer emits is an English-only closed set. The `capabilityHints` on ModulePlugins are English-only.
- BULK SELECTOR PROTOCOL and PREDICATE SELECTOR are fully structural (the runtime matches against live snapshot state), never language-dependent.

### Confirmation vs Clarification (two distinct paths)
- **Missing detail** (ambiguous time, vague title, unclear target) → ASK a clarifying question in plain text.
- **Sensitive action** (detail is complete, but the action has side effects) → CALL the tool. The runtime renders a confirmation card. Do NOT ask "are you sure?" in plain text.

### Redundancy rules
- The narrative spec (ONE short POV-AI sentence, no tool names, no IDs) is documented once and referenced; it is NOT copy-pasted across phases.
- Dead prompt constants must be removed when a phase is refactored.

---

## Verification & Anti-Hallucination

1. **PostExecuteValidator**: Runs after every tool that declares a `verificationProbe`. Re-checks actual state (snapshot or result data) before declaring success.
2. **Empty-result loop guard**: A tool returning zero matches IS the answer. The engine forces `done` rather than letting the LLM re-search with different keywords.
3. **Capability boundary**: The `systemRules` prompt explicitly states the agent's abilities are strictly limited to registered tools. The selector returns `null` for unavailable capabilities, and the engine surfaces the `capabilityNotFound` message.
4. **Stuck detector**: Same tool+args × 3 iterations → one re-plan, then recovery, then abort with a human-readable message. No infinite loops.
5. **Recovery coordinator**: Bounded retries (max 2). Exhausted → honest give-up message with what was attempted.

---

## Bulk & Predicate Selectors

Fully language-agnostic and structural. The runtime evaluates against live snapshot state — the LLM never enumerates entity names.

- **scope: "all"** — fan out to every entity in the collection from the snapshot.
- **scope: "predicate"** — filter by a structured op against a field:
  ```json
  {"scope":"predicate","field":"agent","op":"equals","value":"Mina Chan","case_sensitive":false}
  ```
  Supported ops: `ends_with`, `starts_with`, `contains`, `equals`, `regex`.
  The field resolves against `_EntityMatch.metadata` first (per-entity-type extended fields like `workflow.agent_name`, `module.enabled`), then against `id`, then against `label`.

No keyword matching, no natural-language parsing — the LLM supplies the structured predicate, the runtime matches.

---

## Multi-Step Workflow Impact Detection

The `EcosystemSnapshotBuilder` scans both the primary workflow agent AND the `agentId` references inside chained `WorkflowStep`s. All referenced agents appear in the `usedByWorkflows` reverse index, so deleting an agent that appears *only* inside a workflow step still triggers impact analysis and clarification. No per-workflow hardcoding — the builder iterates `steps` generically.

---

## Handling Native Code (Kotlin ↔ Flutter)

### MethodChannel Pattern

| Channel | Function |
|---------|----------|
| `com.meowagent/device_context` | Battery, network, storage, time, locale, foreground app, usage stats |
| `com.meowagent/app_control` | Open app, list apps, open settings, open URL |
| `com.meowagent/services` | Start/stop foreground services, permissions |
| `com.meowagent/share` | Share intent handling |

### Rules
1. ALWAYS return `Map<String, Any?>` from native.
2. ALWAYS wrap in try-catch — never crash the app.
3. Permission check in native — return safe fallback, not a crash.
4. Log errors: `Log.e(TAG, "message", exception)`.
5. Do NOT block the main thread — heavy work must be async.

---

## Confirmation Flow

Tools with `requiresConfirmation: true`:

```
LLM picks tool → ToolRouter detects confirmation needed
    │
    ▼
Store as PendingAction → Return waitingConfirmation state
    │
    ▼
UI shows confirmation card (Confirm / Reject buttons)
    │
    ├─ User clicks Confirm → executeConfirmed() → forceExecute()
    ├─ User clicks Reject → clearPendingAction()
    └─ User types text → ConfirmationChecker.check() (keyword matching)
         ├─ "ya/oke/lanjut" → execute
         ├─ "tidak/batal/cancel" → reject
         ├─ "lihat dulu/preview" → show preview
         └─ unclear → let LLM decide with pending context
```

---

## Testing (REQUIRED)

### Golden Suite (`test/runtime_golden_test.dart`)

End-to-end regression gate. Scripts every LLM phase + tool result, runs the real engine, and asserts:
- final `state` and `success`
- exact LLM phase sequence (orchestration cost signal)
- tool dispatch sequence
- no-hallucination (final message grounded in canned data, not invented)

Run after every refactor: `flutter test test/runtime_golden_test.dart`

### Drift Guard (`test/module_plugin_test.dart`)

Asserts the router registry and catalog groups are in perfect sync. Run after every module addition/migration: `flutter test test/module_plugin_test.dart`

### Unit Tests (per-tool/per-module)

Minimum per new tool:
1. Success path — fromMap/toJson correct
2. Empty/null input — no crash, sensible defaults
3. Permission missing — safe fallback, no throw
4. Tool registered — risk & confirmation metadata correct
5. For mutation tools: verificationProbe set

Run: `flutter test`

---

## Convention Quick Reference

1. **Tool naming:** `namespace.action` (lowercase, dot-separated)
2. **Error handling:** Always return `ToolExecutionResult` — never throw
3. **Module gating:** Check `module.enabled` AND `module.settings[key]` before execution
4. **Native returns:** Always `Map<String, Any?>`, handle null/error gracefully
5. **LLM prompts:** Always request JSON-only response; handle parse failure with repair retry
6. **Language:** ALL user-facing strings are i18n-driven (`LanguageRegistry`) or LLM-generated (`ToolVerbalizer` in detected language). NO hardcoded natural-language routing or classification.
7. **Risk comes from registry, NOT from LLM output** — security enforcement
8. **No tool names exposed to user** — verbalizer translates to natural language
9. **Every mutating tool MUST have a verificationProbe**
10. **Module install defaults:** `module.enabled` = ON. ALL `module.settings[*]` = OFF until user opts in manually.
11. **Module translations:** New modules must provide translations for every user-facing string in the UI (description, labels, dialogs, snackbars, empty/error states).
12. **English-only examples in prompts.** The LLM handles language naturally — no per-language word lists.
