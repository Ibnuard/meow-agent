# Runtime Engine Decomposition Plan

**Source:** `lib/services/agent_runtime/runtime_engine.dart` (3,558 lines, 1 class: `AgentRuntimeEngine`)
**Goal:** Decompose into 6 focused classes across 6 phases, each producing a green build.
**Source Ref:** QWEN_ANALISYS_RESULT.md Issue #1

---

## Current State

The `AgentRuntimeEngine` class owns **everything**:

| Responsibility | Approx Lines | Where |
|---|---|---|
| `run()` main entry point | 1,068 | L167–L1235 |
| `_executeLoop()` (the main loop) | 1,150 | L1460–L2570 |
| Confirmation/pending action flow | 480 | `_handlePendingDecision`, `_executePendingTool`, `executeConfirmed` |
| Task scope / ledger lifecycle | 350 | `_finishTaskScope*`, `_archiveLedger*`, `_persistLedgerAtGate`, `_parkTaskForUserInput` |
| Preflight target validation | 200 | ✅ Extracted → `preflight_checker.dart` |
| Completion verification | 150 | `_blockIfCompletionUnverified`, `_verifyAgentRegistryCompletion` |
| Recovery | 80 | `_maybeRecover`, `_summarizeArgs` |
| Goal tree / snapshot / tool defs | 160 | `_buildGoalTree`, `_buildSnapshot`, `_toolDefinitionsFor` |
| Response building | 120 | `_finalForCompletedTree`, `_fallbackQuestionForToolFailure` |
| Utility helpers (static/instance) | 200 | `_isDestructiveIntent`, `_isRetrievalTool`, `_isEffectivelyEmpty`, etc. |
| Field/state declarations + accessors | 50 | `_pendingActions`, `_cancelledAgents`, `_pendingClarifications`, `_memory` |
| Constructor + Riverpod provider | 50 | L44–L83, final `agentRuntimeEngineProvider` |

---

## Target Architecture

```
runtime_engine.dart         (~500 lines)  - Orchestrator only, delegates to all below
├── confirmation_manager.dart (~350 lines) - Pending action state + confirmation flow
├── task_scope_manager.dart  (~250 lines) - Ledger lifecycle + cancellation
├── execute_loop_runner.dart (~800 lines)  - The main tool-execution loop
├── preflight_checker.dart   (~200 lines)  - Target existence validation
├── completion_verifier.dart (~150 lines)  - Post-completion state re-check
└── (remaining helpers stay)  (~100 lines)  - Static utility methods on engine
```

---

## Phase 1: Extract `PreflightChecker` ✅ DONE (31 May 2026)

**Result:** `dart analyze` clean, `flutter test` 234/234 passed. Engine: 3,759 → 3,558 lines (−201). New file: `preflight_checker.dart` (217 lines).

**Why first:** Pure functions — no shared mutable state, takes everything as parameters, returns `String?`. Zero risk of behavioral regression.

**New file:** `lib/services/agent_runtime/preflight_checker.dart`

**Extracted methods from `runtime_engine.dart`:**
- `_preflightTargetCheck()` — L3278–L3330 (~52 lines)
- `_preflightEmbeddedSnapshotReferences()` — L3332–L3400 (~68 lines)
- `_requiresExistingTargetPreflight()` — L3362–L3374 (~13 lines)
- `_operationForTool()` — L3376–L3388 (~13 lines)
- `_entityTypeForTool()` — L3390–L3398 (~9 lines)
- `_labelSelectorValue()` — L3400–L3412 (~12 lines)
- `_selectorKeysFor()` — L3414–L3430 (~17 lines)
- `_isIdSelectorKey()` — L3432–L3436 (~5 lines)
- `_SelectorValue` private class — L3730–L3740

**Class design:**
```dart
class PreflightChecker {
  PreflightChecker({
    required Future<EcosystemSnapshot> Function() snapshotBuilder,
  });

  /// Returns null when clean, or a localized clarify/block message.
  Future<String?> check({
    required ToolCallRequest tool,
    required ToolDefinition definition,
    required ToolVerbalizer verbalizer,
    required DetectedLanguage language,
    required String userMessage,
  });
}
```

**Call site change in `_executeLoop()`:**
```dart
// Before:
final preflight = await _preflightTargetCheck(
  tool: toolRequest, definition: definition, verbalizer: verbalizer,
  language: detectedLang, userMessage: request.userMessage,
);

// After:
final preflight = await _preflight.check(
  tool: toolRequest, definition: definition, verbalizer: verbalizer,
  language: detectedLang, userMessage: request.userMessage,
);
```

**Verification:** `dart analyze lib/` + `flutter test`

**Estimated lines removed from engine:** ~190

---

## Phase 2: Extract `CompletionVerifier` ✅ DONE (31 May 2026)

**Result:** `dart analyze` clean, `flutter test` 234/234 passed. Engine: 3,558 → 3,429 lines (−129). New file: `completion_verifier.dart` (202 lines).

**Why second:** Also near-pure — reads `agentLoader` from engine, writes nothing. Small, self-contained.

**New file:** `lib/services/agent_runtime/completion_verifier.dart`

**Extracted from `runtime_engine.dart`:**
- `_blockIfCompletionUnverified()` — L2939–L2999 (~60 lines)
- `_verifyAgentRegistryCompletion()` — L3001–L3080 (~80 lines)
- `_expectedAgentNameForSubgoal()` — L3082–L3102 (~20 lines)
- `_CompletionVerification` private class — L3742–L3759

**Class design:**
```dart
class CompletionVerifier {
  CompletionVerifier({
    required List<AgentModel> Function() agentLoader,
  });

  /// Returns null if verified, or a blocker response with ask_user state.
  Future<AgentRuntimeResponse?> blockIfUnverified({...});
}
```

**Call sites change:** Two places in `_executeLoop()` and `_executePendingTool()` call `_blockIfCompletionUnverified`. Both delegate to `_completionVerifier.blockIfUnverified(...)`.

**Verification:** `dart analyze lib/` + `flutter test`

**Estimated lines removed from engine:** ~170

---

## Phase 3: Extract `ConfirmationManager` (MEDIUM RISK)

**Why third:** Owns mutable pending-action state. First extraction that touches engine fields. The pending-action fields (`_pendingActions`, `_pendingClarifications`) move out of the engine.

**New file:** `lib/services/agent_runtime/confirmation_manager.dart`

**Extracted from `runtime_engine.dart`:**
- Fields: `_pendingActions`, `_pendingClarifications`
- `getPendingAction()` — L136
- `clearPendingAction()` — L138
- `clearPendingClarification()` — L140
- `_handlePendingDecision()` — L1311–L1405 (~95 lines)
- `_executePendingTool()` — L1407–L1880 (~473 lines)
- `executeConfirmed()` — L1237–L1309 (~73 lines)
- `_maybeRestorePendingFromLedger()` — L3108–L3160 (~53 lines)

**Dependencies needed from engine (passed via constructor or method args):**
- `toolRouter`, `workspaceLoader`, `ledgerDb` (for `_maybeRestorePendingFromLedger`)
- `_client` (LLM client — passed via constructor)
- `_memory` (pass via reference or have engine pass it)

**Class design:**
```dart
class ConfirmationManager {
  final Map<String, PendingAction> _pendingActions = {};
  final Map<String, PendingClarification> _pendingClarifications = {};

  ConfirmationManager({
    required ToolRouter toolRouter,
    required WorkspaceLoader workspaceLoader,
    required TaskLedgerDatabase ledgerDb,
    required OpenAiCompatibleClient llmClient,
  });

  PendingAction? getPending(String agentId);
  void clearPending(String agentId);
  void clearClarification(String agentId);

  /// Process a pending action decision (deterministic or LLM-classified).
  Future<AgentRuntimeResponse?> handleDecision({...});

  /// Execute a tool the user confirmed via button tap.
  Future<AgentRuntimeResponse> executeConfirmed({...});

  /// Try to restore pending from ledger after app restart.
  Future<void> maybeRestoreFromLedger(String agentId);
}
```

**Engine changes:**
- Remove `_pendingActions`, `_pendingClarifications`, their accessors
- Add `final ConfirmationManager _confirmation;`
- In `run()`, replace ~80 lines of pending flow with delegation to `_confirmation.handleDecision(...)`
- `executeConfirmed()` becomes a thin wrapper or the UI calls `_confirmation.executeConfirmed()` directly

**Verification:** `dart analyze lib/` + `flutter test`

**Estimated lines removed from engine:** ~700

---

## Phase 4: Extract `TaskScopeManager` (MEDIUM RISK)

**Why fourth:** Owns ledger lifecycle and cancellation state. Clear responsibility boundary.

**New file:** `lib/services/agent_runtime/task_scope_manager.dart`

**Extracted from `runtime_engine.dart`:**
- Field: `_cancelledAgents`
- `abortActiveTask()` — L143–L157
- `_finishTaskScopeForRequest()` — L3160–L3170
- `_finishTaskScope()` — L3172–L3190
- `_archiveLedgerForRequest()` — L3192–L3210
- `_persistLedgerAtGate()` — L2750–L2835 (~85 lines)
- `_parkTaskForUserInput()` — L2837–L2888 (~51 lines)
- `_ledgerSourceFor()` — L3155–L3159

**Dependencies:**
- `ledgerDb` — moves from engine to TaskScopeManager
- `_pendingActions`, `_pendingClarifications` — now owned by `ConfirmationManager`, passed as needed

**Class design:**
```dart
class TaskScopeManager {
  final TaskLedgerDatabase ledgerDb;
  final Set<String> _cancelledAgents = {};

  TaskScopeManager({required this.ledgerDb});

  void cancel(String agentId);
  bool isCancelled(String agentId);
  Future<void> abortActive(String agentId, {required RequestSource source, required ConfirmationManager confirmation});
  Future<void> finishScope({required String agentId, required RequestSource source, required LedgerStatus terminal, required ConfirmationManager confirmation});
  Future<void> archiveLedger(AgentRuntimeRequest request, LedgerStatus terminal);
  Future<TaskLedger> persistAtGate({...});
  Future<void> parkForUserInput({...});
}
```

**Engine changes:**
- Remove `_cancelledAgents`, `ledgerDb`, ledger-related methods
- Add `final TaskScopeManager _taskScope;`
- `run()` delegates to `_taskScope.persistAtGate(...)`, `_taskScope.finishScope(...)`
- `_executeLoop()` cancellation check: `_taskScope.isCancelled(agentId)`

**Verification:** `dart analyze lib/` + `flutter test`

**Estimated lines removed from engine:** ~280

---

## Phase 5: Extract `ExecuteLoopRunner` (HIGHEST RISK)

**Why last:** The 1,150-line `_executeLoop()` is the core of the agent runtime. Deeply entangled with engine services. Must extract carefully.

**New file:** `lib/services/agent_runtime/execute_loop_runner.dart`

**Extracted from `runtime_engine.dart`:**
- `_executeLoop()` — L1460–L2570 (~1,110 lines)
- `_maybeRecover()` — L2575–L2630 (~55 lines)
- `_summarizeArgs()` — L2641–L2650 (~10 lines)

**This method depends on practically every service:**
- `executor`, `verbalizer`, `toolRouter`, `workspaceLoader`
- `_memory` (runtime memory)
- `_taskScope` (cancellation check, ledger ops)
- `_confirmation` (pending state)
- `_preflight` (preflight checks)
- `_completionVerifier` (completion verification)
- `_client` (LLM)
- `stuck` (StuckDetector — already local)
- `recovery` (RecoveryCoordinator — passed as param)
- `postExecuteValidator` (passed as param)

**Class design:**
```dart
class ExecuteLoopRunner {
  ExecuteLoopRunner({
    required Executor executor,
    required ToolVerbalizer verbalizer,
    required ToolRouter toolRouter,
    required WorkspaceLoader workspaceLoader,
    required RuntimeMemory memory,
    required TaskScopeManager taskScope,
    required ConfirmationManager confirmation,
    required PreflightChecker preflight,
    required CompletionVerifier completionVerifier,
    required OpenAiCompatibleClient llmClient,
  });

  Future<AgentRuntimeResponse> run({
    required AgentRuntimeRequest request,
    required Map<String, dynamic> plan,
    required GoalTree goalTree,
    required DetectedLanguage detectedLang,
    required List<String> availableTools,
    required RuntimeLogger logger,
    required void Function(RuntimeEvent) emit,
    required String memorySnapshot,
    RecoveryCoordinator? recovery,
    PostExecuteValidator? postExecuteValidator,
    Future<({Map<String, dynamic> plan, GoalTree goalTree})?> Function()? rethink,
    bool autoApproveSensitive = false,
    bool isWorkflowAutoExecute = false,
    List<Map<String, dynamic>>? initialPreviousResults,
    int initialStep = 1,
  });
}
```

**Key risk areas:**
1. The `rethink` closure captures `reflector`, `planner`, `effectiveUserMessage`, `recentMsgs`, `logger` — all `run()` locals. Solution: pass as parameters to the runner or pre-build the rethink closure and pass it.

2. The `_memory.record()` calls inside the loop. Solution: `RuntimeMemory` is passed via constructor.

3. `_permissionDeniedResponseFor()` — this static-like method depends on `languageCode` field. Solution: either make it a static method (it's close) or keep it on the engine.

4. `_isLastPlannedStep()`, `_shouldAnswerFromToolResult()`, `_fail()` — these are standalone helpers that can stay on the engine or become static methods on the runner.

**Engine changes:**
- `_executeLoop()` becomes: `return _loopRunner.run(...);`
- `_maybeRecover()` moves to runner
- `_summarizeArgs()` moves to runner

**Verification:** `dart analyze lib/` + `flutter test` — **this is the gate where bugs surface.**

**Estimated lines removed from engine:** ~1,175

---

## Phase 6: Cleanup & Polish

**Remaining in engine** after all extractions (~500 lines total):

| What stays | Lines |
|---|---|
| Constructor + fields (`_client`, `toolRouter`, `workspaceLoader`, etc.) | 40 |
| `_directResponseRulesFor()`, `_fallbackLanguage()` | 25 |
| `run()` — now ~100-150 lines (pure orchestration) | 150 |
| `_buildGoalTree()`, `_buildSnapshot()`, `_toolDefinitionsFor()` | 80 |
| `_finalForCompletedTree()`, `_fallbackQuestionForToolFailure()` | 120 |
| `_isDestructiveIntent()`, `_isRetrievalTool()`, `_isAnswerOnlySubgoal()`, `_subgoalSlot()` | 80 |
| `_permissionDeniedResponseFor()`, `_fail()`, `_capabilityNotFoundMessage()` | 50 |
| `_isEffectivelyEmpty()` (static), `_isReadOnlyLookup()` (static), `_deliveryDestinationKey()` (static), `_emptyResultMessage()` | 50 |
| `_isLastPlannedStep()`, `_shouldAnswerFromToolResult()` | 30 |
| Riverpod provider | 20 |

**Optional further extraction:** The static utility methods could move to a `RuntimeEngineUtils` class if desired. Not critical — they're small and self-contained.

**Final verification checklist:**
- [ ] `dart analyze lib/` — zero errors
- [ ] `flutter test` — all existing tests pass
- [ ] Manual smoke test: "create agent TestBot" + "delete agent TestBot"
- [ ] Manual smoke test: multi-subgoal task with confirmation gate
- [ ] Manual smoke test: workflow auto-execute with sensitive actions
- [ ] Git diff: verify `runtime_engine.dart` is ~500 lines (down from 3,759)

---

## Risk Mitigation Strategy

### For every phase:
1. **Create the new file** with extracted methods (copy-paste, adjust imports)
2. **Wire the engine** to delegate to the new class
3. **Delete the old methods** from the engine
4. **Run `dart analyze`** — fix any compilation errors immediately
5. **Run `flutter test`** — if tests fail, fix before proceeding
6. **Commit** with message: `refactor(runtime): extract <ClassName> (Phase N)`

### If a phase fails tests:
- Do NOT proceed to the next phase
- The most likely failure point is Phase 5 (`ExecuteLoopRunner`)
- If Phase 5 proves too risky, keep `_executeLoop()` in the engine and only extract Phases 1-4. The engine would still shrink by ~1,340 lines (36% reduction), and the loop would be the last monolithic piece to tackle separately.

---

## Summary Table

| Phase | New File | Lines Out | Risk | Build Impact |
|---|---|---|---|---|
| 1 | `preflight_checker.dart` | ~190 | 🟢 Low | No behavioral change |
| 2 | `completion_verifier.dart` | ~170 | 🟢 Low | No behavioral change |
| 3 | `confirmation_manager.dart` | ~700 | 🟡 Medium | State ownership change |
| 4 | `task_scope_manager.dart` | ~280 | 🟡 Medium | Ledger ownership change |
| 5 | `execute_loop_runner.dart` | ~1,175 | 🔴 High | Core loop extraction |
| 6 | Cleanup (no new files) | ~50 | 🟢 Low | Optional polish |

**Total engine reduction:** 3,759 → ~500 lines (−87%)