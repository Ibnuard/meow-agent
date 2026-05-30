# QWEN Analysis Result — Meow Agent Codebase

**Date:** 2026-05-31
**Scope:** Full codebase analysis (142 Dart source files, 24 test files)
**Method:** Architecture review, pattern analysis, potential bug hunting
**Status:** All 14 findings resolved — #1 remains as architectural note (deferred), #2–#14 fully addressed (see ✓ below)

---

## ✅ What's Already Good

- **Self-registering plugin architecture** — clean and mature. Module→plugin consistency is excellent after the Stage 3 migration.
- **PostExecuteValidator** + `verificationProbe` — solid anti-hallucination design. Every mutating tool can declare a post-execute verification spec.
- **RecoveryCoordinator** — bounded retry with escalating strategy (`retrySameStep` → `rethinkAndReplan` → `giveUp`). Prevents infinite loops.
- **Snapshot-based target resolution** — generic predicate selectors that don't depend on per-language keyword matching.
- **JsonUtils local recovery** — avoids extra paid LLM calls for malformed JSON by stripping markdown fences and extracting balanced `{...}` blocks locally.
- **ToolRouter security** — risk level always comes from the registry definition, never from LLM output.
- **StuckDetector** — catches same (tool + args) executed 3× in a row and triggers re-planning.
- **Language detection architecture** — two-tier (script bootstrap + LLM refinement), correctly handles non-Latin scripts with high confidence and Latin scripts with LLM refinement.

---

## 🔴 Critical Issues

### 1. `runtime_engine.dart` — 3,735 Lines (Severe SRP Violation)

`AgentRuntimeEngine.run()` handles **everything at once**: language detection, workspace loading, tool catalog selection, pending clarification merge, active task context resolution, relation gate, confirmation classifier, reflection, execute loop, stuck detection, recovery, response building, and task scope management — all in one extremely long method.

**Impact:** Very hard to test individual flows, debug, or extend. A change in confirmation flow risks breaking task scoping.

**Suggested decomposition:**

| Responsibility | Suggested New Class |
|---|---|
| Confirmation + pending action flow | `ConfirmationManager` |
| Task scope / ledger lifecycle | `TaskScopeManager` |
| Tool surface narrowing pipeline | `ToolSurfacePipeline` |
| Execute loop orchestration | `ExecuteLoopRunner` |

### 2. ~~Duplicate `ModuleRegistry` Instances~~ ✅ FIXED

> **Fix:** `buildRuntimeModuleRegistry()` now caches and returns a singleton via `_cachedRegistry ??=`. All callers (ToolRouter, ToolCatalog) share one instance.

**Original issue:** Two separate `ModuleRegistry` instances were created at startup from the same plugin list (`tool_router.dart` and `tool_catalog.dart` each called `buildRuntimeModuleRegistry()` independently), wasting memory and creating drift risk.

### 3. ~~Force-Unwrap Crash Risk in `tool_catalog.dart`~~ ✅ FIXED

> **Fix:** Changed `...groups['files']!` → `...?groups['files']` (null-aware spread). Same for `system`. Null groups now silently contribute nothing instead of crashing.

**Original issue:** Force-unwrap `!` on `groups['files']` and `groups['system']` would throw if either catalog group key was ever missing from the registry. Fragile against future plugin refactors.

### 4. ~~Hardcoded Indonesian Strings — Conflicts with "Language-Generic" Principle~~ ✅ FIXED

> **Fix:** Removed `actionLabelId`/`settingLabelId` from `ToolPermissionRequirement` (single canonical English label now, UI localizes via `LanguageRegistry`). Removed `labelId` from `ResultAction` (single `label` field). `ConfirmationChecker` kept as-is (documented pragmatic exception).

SKILLS.md states: *"Language-generic, always. NO per-language word lists, NO Indonesian-specific examples in routing/classification code."* However, the following files hardcode Indonesian strings:

| File | Violation | Count |
|---|---|---|
| `tool_permission_policy.dart` | `actionLabelId`, `settingLabelId` fields with Indonesian translations hardcoded per tool requirement | ~40 pairs |
| `runtime_models.dart` (`ResultAction`) | `labelId` field carrying Indonesian label for every result action | 1 field, N instances |
| `pending_action.dart` (`ConfirmationChecker`) | ~40 Indonesian keywords and phrases for confirmation detection | ~40 strings |

SKILLS.md itself documents the `ConfirmationChecker` as "Tier-1 deterministic ID/EN keyword check" — so there's an explicit architectural acknowledgment that the confirmation path needs fast, deterministic keyword matching for ID and EN. This is a pragmatic compromise, but the other two files (`ToolPermissionRequirement`, `ResultAction`) have no such justification.

**Impact:** Every new module/tool requires manual ID translation in `tool_permission_policy.dart`. Adding a new language to confirmation checking requires editing hardcoded maps. This contradicts the stated design philosophy.

**Recommendation:** Architectural decision needed:
- For `ToolPermissionRequirement`: generate user-facing messages via `ToolVerbalizer` (LLM-driven) instead of hardcoding bilingual strings.
- For `ResultAction`: remove `labelId` and use `LanguageRegistry` or LLM-verbalized labels.
- For `ConfirmationChecker`: keep as-is (documented pragmatic exception) but consider expanding to a JSON-based language pack if more languages are needed.

---

## 🟡 Medium Impact

### 5. ~~Duplicate `_callLlm` Logic in Planner & Executor~~ ✅ FIXED

> **Fix:** Extracted to shared `LlmJsonCaller` class (`lib/services/agent_runtime/llm_json_caller.dart`). Both `Planner` and `Executor` now use `LlmJsonCaller(client: client, config: config).call(prompt, phase, logger)`.

**Original issue:** Both `Planner` and `Executor` had identical `_callLlm` methods (JSON parse → repair prompt retry → null on double failure):

```dart
// Identical in both planner.dart and executor.dart
Future<Map<String, dynamic>?> _callLlm(
  String prompt, String phase, RuntimeLogger logger,
) async {
  final response = await client.chat(...);
  var parsed = JsonUtils.tryParseObject(response);
  if (parsed != null) { logger.logLlmDecision(phase, parsed); return parsed; }
  logger.logError('JSON parse failed in $phase, attempting repair');
  final repairPrompt = PromptTemplates.jsonRepairPrompt(response);
  final repaired = await client.chat(...);
  parsed = JsonUtils.tryParseObject(repaired);
  if (parsed != null) { logger.logLlmDecision(phase, parsed); return parsed; }
  logger.logError('JSON repair also failed in $phase');
  return null;
}
```

**Fix:** Extract to a shared mixin or standalone `LlmJsonCaller` class.

### 6. ~~`Planner.plan()` Method — Potentially Unused~~ ✅ FALSE POSITIVE

> **Verification:** `planner.plan()` is actively called at 3 locations in `runtime_engine.dart` (lines 845, 861, 952). It is live, not dead code. No action needed.

**Original concern:** `Planner` exposes a `plan()` method that builds a separate planning prompt. In `runtime_engine.dart`, the engine flows directly from `analyze` → `reflect` → `execute loop` without calling `planner.plan()`. The planning logic appears to have been absorbed into the reflector + executor phases.

**Recommendation:** Verify whether this is dead code. If unused, remove to reduce maintenance surface.

### 7. ~~Non-Unique Event IDs in `RuntimeLogger`~~ ✅ FIXED

> **Fix:** Changed `DateTime.now().microsecondsSinceEpoch.toString()` → `const Uuid().v4()` in `RuntimeEvent` constructor. Added `import 'package:uuid/uuid.dart';` to `runtime_models.dart`.

**Original issue:** Two events created in the same microsecond would have identical IDs.

### 8. ~~`enableAgentRuntimeV1` — Unused Feature Flag~~ ✅ FIXED

> **Fix:** Removed the vestigial constant from the codebase entirely.

**Original issue:** This constant was defined but not referenced anywhere.

### 9. ~~`ModuleRegistry` Constructor with Non-Trivial Side Effects~~ ✅ FIXED

> **Fix:** Converted to `factory ModuleRegistry.fromPlugins(List<ModulePlugin> plugins)` delegating to private `ModuleRegistry._(this.plugins)`. Updated callers in `runtime_module_plugins.dart` and `test/module_plugin_test.dart`.

**Original issue:** Heavy initialization with validation in the constructor body is uncommon in Dart.

### 10. ~~`context_compactor.dart` — Unclear Integration~~ ✅ VERIFIED

> **Verification:** `ContextCompactor` is integrated at the **UI/chat layer**, not in `runtime_engine.dart`. This is the correct architectural placement — compaction is a UI concern triggered by user commands or auto-detection before sending.
>
> **Integration points:**
> - `chat_screen.dart:750` — `/status` command: `getUsageInfo()` for context usage report
> - `chat_screen.dart:849–903` — `/compact` command: `estimateChatTokens()` + `compact()` for manual compaction
> - `chat_screen.dart:931–962` — `needsCompaction()` + `compact()` for auto-compact before sending
> - `context_report.dart:75` — `/context` command: `peakRecentInputTokens()` for measured usage

**Original concern:** The `ContextCompactor` class exists with token estimation and compaction logic, but its usage in the main `runtime_engine.dart` loop is not visible.

---

## 🔵 Minor / Style Issues

### 11. ~~`prompt_constants.dart` (535 lines)~~ ✅ FIXED

> **Fix:** Split into 6 per-phase files: `prompt_system.dart`, `prompt_analyze.dart`, `prompt_reflect.dart`, `prompt_plan.dart`, `prompt_execute.dart`, `prompt_context.dart`. `PromptConstants` class now delegates to the split constants via thin accessors for backward compatibility.

**Original:** ~~`prompt_constants.dart` (535 lines) — could be split by phase (`analyze_constants.dart`, `reflect_constants.dart`, etc.) now that it exceeds 500 lines.~~

### 12. ~~`system_tools.dart` (1,266 lines)~~ ✅ FIXED

> **Fix:** Split into 4 part files via Dart `part` directives: `system_tools_agent.dart` (agent CRUD), `system_tools_workspace.dart` (self, workspace, profile, memory), `system_tools_introspection.dart` (provider, module, tool listing & toggle), `system_tools_export.dart` (export/import). Each part file uses an extension on `SystemTools` so `system_module.dart` dispatches identically.

**Original:** ~~`system_tools.dart` (1,266 lines) — handles too many concerns: workspace markdown parsing, profile field mapping, agent CRUD, provider lookup, module listing, and tool listing. Could be split per domain.~~

### 13. ~~Magic strings for catalog group names~~ ✅ FIXED

> **Fix:** Added `static const groupFiles = 'files'` and `static const groupSystem = 'system'` on `ToolCatalog`. All references now use the named constants.

**Original:** ~~Magic strings for catalog group names (`'system'`, `'files'`) appear hardcoded in `tool_catalog.dart`. Consider making them constants on the respective `ModulePlugin` classes.~~

### 14. ~~`_requirements` map in `tool_permission_policy.dart`~~ ✅ FIXED

> **Fix:** Extracted to `tool_permission_requirements.dart` as a top-level `const toolPermissionRequirements` map. `ToolPermissionPolicy._requirements` now returns it via a getter. All `actionLabelId`/`settingLabelId` fields removed (English-only canonical labels).

---

## 📊 Summary Table

| # | Severity | Issue | Suggested Action |
|---|---|---|---|
| 1 | 🔴 Critical | `runtime_engine.dart` 3,735 lines — massive SRP violation | Decompose into 3-4 focused classes |
| 2 | ~~🔴 Critical~~ ✅ | ~~Duplicate `ModuleRegistry` instances~~ | Fixed: cached singleton |
| 3 | ~~🔴 Critical~~ ✅ | ~~Force-unwrap on `groups['files']` and `groups['system']`~~ | Fixed: null-aware spread |
| 4 | ~~🔴 Critical~~ ✅ | ~~Hardcoded Indonesian strings~~ | Fixed: removed `labelId`/`actionLabelId`, single canonical English |
| 5 | ~~🟡 Medium~~ ✅ | ~~Duplicate `_callLlm` in Planner & Executor~~ | Fixed: extracted `LlmJsonCaller` class |
| 6 | ~~🟡 Medium~~ ✅ | ~~`Planner.plan()` potentially unused~~ | False positive: called at 3 locations in runtime_engine.dart |
| 7 | ~~🟡 Medium~~ ✅ | ~~Non-unique event IDs~~ | Fixed: `const Uuid().v4()` |
| 8 | ~~🟡 Medium~~ ✅ | ~~`enableAgentRuntimeV1` unused flag~~ | Fixed: removed entirely |
| 9 | ~~🟡 Medium~~ ✅ | ~~`ModuleRegistry` constructor side effects~~ | Fixed: factory `fromPlugins` + private `_()` |
| 10 | ~~🟡 Medium~~ ✅ | ~~`context_compactor.dart` integration unclear~~ | Verified: integrated at UI/chat layer, not runtime engine |
| 11 | ~~🔵 Minor~~ ✅ | ~~`prompt_constants.dart` 535 lines~~ | Fixed: split into 6 per-phase files |
| 12 | ~~🔵 Minor~~ ✅ | ~~`system_tools.dart` 1,266 lines~~ | Fixed: split into 4 domain part files |
| 13 | ~~🔵 Minor~~ ✅ | ~~Magic strings for catalog group names~~ | Fixed: `groupFiles`/`groupSystem` constants |
| 14 | ~~🔵 Minor~~ ✅ | ~~`_requirements` map in `tool_permission_policy.dart`~~ | Fixed: extracted to `tool_permission_requirements.dart` |