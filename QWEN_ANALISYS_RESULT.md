# QWEN Analysis Result — Meow Agent Codebase

**Date:** 2026-05-31
**Scope:** Full codebase analysis (142 Dart source files, 24 test files)
**Method:** Architecture review, pattern analysis, potential bug hunting

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

### 2. Duplicate `ModuleRegistry` Instances

Two separate `ModuleRegistry` instances are created at startup from the same plugin list:

```dart
// tool_router.dart — instance #1
final ModuleRegistry _moduleRegistry = buildRuntimeModuleRegistry();

// tool_catalog.dart — instance #2
static final Map<String, Set<String>> groups = buildRuntimeModuleRegistry()
    .buildCatalogGroups();
```

**Impact:** Wasted memory, potential drift between the two registries if they're ever constructed differently. Currently functionally identical, but a future refactor could desynchronize them without any compile-time error.

**Fix:** Inject the same registry instance into both consumers, or make `buildRuntimeModuleRegistry()` return a cached singleton.

### 3. Force-Unwrap Crash Risk in `tool_catalog.dart`

```dart
// tool_catalog.dart ~line 44-45
if (pendingAction != null) {
  return ToolCatalogSelection(
    toolNames: {
      pendingAction.toolName,
      ...groups['files']!,   // 💥 crashes if 'files' group missing from catalog
      ...groups['system']!,  // 💥 crashes if 'system' group missing
    },
    ...
  );
}
```

**Impact:** `Null check operator used on a null value` at runtime if any plugin rename/removal affects the `files` or `system` catalog groups. Currently safe because both plugins always exist in `runtimeModulePlugins`, but fragile against future refactors.

**Fix:** Use null-safe fallback — `groups['files'] ?? const {}` and `groups['system'] ?? const {}`.

### 4. Hardcoded Indonesian Strings — Conflicts with "Language-Generic" Principle

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

### 5. Duplicate `_callLlm` Logic in Planner & Executor

Both `Planner` and `Executor` have identical `_callLlm` methods (JSON parse → repair prompt retry → null on double failure):

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

### 6. `Planner.plan()` Method — Potentially Unused

`Planner` exposes a `plan()` method that builds a separate planning prompt. In `runtime_engine.dart`, the engine flows directly from `analyze` → `reflect` → `execute loop` without calling `planner.plan()`. The planning logic appears to have been absorbed into the reflector + executor phases.

**Recommendation:** Verify whether this is dead code. If unused, remove to reduce maintenance surface.

### 7. Non-Unique Event IDs in `RuntimeLogger`

```dart
// runtime_logger.dart
class RuntimeEvent {
  RuntimeEvent({required this.type, required this.message, this.data})
    : id = DateTime.now().microsecondsSinceEpoch.toString(),
      createdAt = DateTime.now();
```

Two events created in the same microsecond will have identical IDs. The `uuid` package is already in `pubspec.yaml` dependencies.

**Fix:** Use `const Uuid().v4()` for event IDs.

### 8. `enableAgentRuntimeV1` — Unused Feature Flag

```dart
// runtime_models.dart
const bool enableAgentRuntimeV1 = true;
```

This constant is defined but not referenced as a guard anywhere visible in the codebase. It appears to be vestigial.

**Recommendation:** Remove if unused, or implement the feature flag if it's meant to gate v1 vs v2 runtime paths.

### 9. `ModuleRegistry` Constructor with Non-Trivial Side Effects

```dart
// module_registry.dart
class ModuleRegistry {
  ModuleRegistry(this.plugins) {
    for (final plugin in plugins) {
      for (final def in plugin.toolDefinitions) {
        final existing = _pluginByTool[def.name];
        if (existing != null) {
          throw StateError('Duplicate tool "${def.name}" ...');
        }
        _pluginByTool[def.name] = plugin;
        _definitions[def.name] = def;
      }
    }
  }
```

Dart convention favors simple constructors. Heavy initialization with validation in the constructor body is uncommon.

**Fix:** Use a factory constructor — `factory ModuleRegistry.fromPlugins(List<ModulePlugin> plugins) => ...` — or a `static ModuleRegistry build(List<ModulePlugin> plugins)` method.

### 10. `context_compactor.dart` — Unclear Integration

The `ContextCompactor` class exists with token estimation and compaction logic, but its usage in the main `runtime_engine.dart` loop is not visible. Compaction may be handled at the UI/chat layer instead. Needs verification.

---

## 🔵 Minor / Style Issues

- **`prompt_constants.dart` (535 lines)** — could be split by phase (`analyze_constants.dart`, `reflect_constants.dart`, etc.) now that it exceeds 500 lines.
- **`system_tools.dart` (1,266 lines)** — handles too many concerns: workspace markdown parsing, profile field mapping, agent CRUD, provider lookup, module listing, and tool listing. Could be split per domain.
- **Magic strings** for catalog group names (`'system'`, `'files'`) appear hardcoded in `tool_catalog.dart`. Consider making them constants on the respective `ModulePlugin` classes.
- **`tool_permission_policy.dart`** — the `_requirements` static map has ~300 lines of entry definitions. Could be generated from module plugin metadata or moved to a separate data file.

---

## 📊 Summary Table

| # | Severity | Issue | Suggested Action |
|---|---|---|---|
| 1 | 🔴 Critical | `runtime_engine.dart` 3,735 lines — massive SRP violation | Decompose into 3-4 focused classes |
| 2 | 🔴 Critical | Duplicate `ModuleRegistry` instances at startup | Inject shared singleton registry |
| 3 | 🔴 Critical | Force-unwrap `!` on `groups['files']` and `groups['system']` | Use `?? const {}` null-safe fallback |
| 4 | 🔴 Critical | Hardcoded Indonesian strings contradict language-generic philosophy | Architectural decision: migrate to LLM-driven or i18n pack |
| 5 | 🟡 Medium | Duplicate `_callLlm` logic in Planner & Executor | Extract shared `LlmJsonCaller` mixin/class |
| 6 | 🟡 Medium | `Planner.plan()` potentially unused dead code | Verify and remove if confirmed dead |
| 7 | 🟡 Medium | Non-unique event IDs from `microsecondsSinceEpoch` | Use `uuid` package (already a dependency) |
| 8 | 🟡 Medium | `enableAgentRuntimeV1` unused feature flag | Remove or implement |
| 9 | 🟡 Medium | `ModuleRegistry` constructor with heavy side effects | Convert to factory constructor |
| 10 | 🟡 Medium | `context_compactor.dart` integration unclear | Verify and document usage path |
| 11 | 🔵 Minor | `prompt_constants.dart` 535 lines | Split by phase |
| 12 | 🔵 Minor | `system_tools.dart` 1,266 lines | Split by domain |
| 13 | 🔵 Minor | Magic strings for catalog group names | Extract as named constants |
| 14 | 🔵 Minor | `_requirements` map in `tool_permission_policy.dart` | Move to separate data file or generate from plugin metadata |