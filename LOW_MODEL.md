# Meow Agent Runtime — Low-Model Reliability Plan

> **Goal**: Make Meow Agent the first reliable Android-first agentic runtime for low-model LLMs.
>
> **Problem**: Even simple tasks (miniapp + DB integration) cause hallucination loops, infinite retries, and failed execution. Root cause is not bugs but architecture — too many LLM decision points for low models to handle reliably.

---

## Current Architecture (Full Scan Results)

### What's already simplified ✅

| Component | Status | File |
|-----------|--------|------|
| **3-phase → 1 call** | ✅ Done | `classifier.dart` merges analyze+reflect+plan into single LLM call |
| **ClassifyPhase wrapper** | ✅ Done | `classify_phase.dart` — thin wrapper, engine calls `classifyPhase.run()` |
| **ClassifyResult** | ✅ Done | Unified output: `analysis` Map + `ReflectionOutput` + `plan` Map |
| **CompletionVerifier** | ✅ Exists | `completion_verifier.dart` — checks `expectedDataKeys` presence in tool result |
| **PostExecuteValidator** | ✅ Exists | `post_execute_validator.dart` — supports `snapshot_contains`, `snapshot_absent`, `tool_result_data` probes |
| **ToolVerificationProbe** | ✅ Exists | `runtime_models.dart` — has `kind`, `expectedDataKeys`, `entityType`, `expectPresent` |
| **Premature done guard** | ✅ Done | `execute_loop_runner.dart` — threshold=2, oscillation detection |
| **Setup-only guard** | ✅ Done | `execute_loop_runner.dart` — prevents "done" after mkdir/install |
| **Retrieval-can't-complete guard** | ✅ Done | `execute_loop_runner.dart` — retrieval in mutation subgoal → force continue |
| **Empty-result loop guard** | ✅ Done | `execute_loop_runner.dart` — prevents infinite empty-result loops |
| **Full-rewrite patch mode** | ✅ Done | `miniapp_module_plugin.dart` — easiest mode for low models |
| **codeInspection in read** | ✅ Done | `miniapp_module_plugin.dart` — objective booleans |
| **codeInspection grounding rules** | ✅ Done | `prompt_execute.dart` — LLM instructed to trust inspection flags |

### The gap — what's missing ❌

| Gap | Impact | P0? |
|-----|--------|-----|
| **No semantic value checking** in verification probes | `CompletionVerifier` checks key *presence* (`id`, `patched`, `persisted`) but NOT field *values* (`codeInspection.usesUserDatabase == false`) | ✅ P0 |
| **No `requiredCapabilities`** in classify output | ClassifyResult has intent/goal/strategy/subgoals but no "what capabilities must the final result have" | ✅ P0 |
| **No deterministic gate** at review `done` | ExecuteLoopRunner has many guards (premature, setup-only, retrieval, empty) but NONE check codeInspection against user goal | ✅ P0 |
| **No action hints** in selectTool context | Previous results are injected as text, but no deterministic "NEXT ACTION: miniapp.patch" hint | P2 |
| **No toolHint** in subgoals | Executor always calls full selectTool LLM, even when tool is obvious from plan | P1 |
| **No composite tools** | Common patterns (DB integration, theme integration) require multi-step LLM | P3 |

---

## Root Cause Analysis (Updated)

### Why "simple" tasks still fail despite simplification

The 3-phase merge (P1 from old plan) is **already done** — classify is 1 LLM call. But the **execution loop** is still fully LLM-directed:

```
classify (1 call) → selectTool → review → selectTool → review → ... → done
                     ↑___________↑ repeat per subgoal step
```

For "miniapp + DB integration":
- classify: 1 call → emits subgoals (read app, patch with DB, verify)
- selectTool #1: 1 call → picks miniapp.read
- review #1: 1 call → says continue
- selectTool #2: 1 call → should pick miniapp.patch (but low model may hallucinate)
- review #2: 1 call → should say continue (but may hallucinate done)
- selectTool #3: 1 call → should verify (but may not happen)
- review #3: 1 call → should say done

**Total: 7 LLM calls** (classify + 3×selectTool + 3×review). The merge saved 2 calls (analyze+reflect+plan → 1), but execution is still 6 calls.

### The #1 failure mode (confirmed by code scan)

```
review returns status=done
→ ExecuteLoopRunner checks: goalTree.isComplete? 
→ If yes: accept done, return to user
→ If no: override done, inject error, continue
```

**But**: `goalTree.isComplete` only checks subgoal **status labels** (done/skipped). It does NOT check whether the subgoal's **actual semantic outcome** was achieved. If the reviewer marks a subgoal `done` (hallucination), `goalTree.isComplete` returns true, and the loop exits — even if `codeInspection.usesUserDatabase=false`.

**The fix (P0)**: Before accepting `reviewStatus == 'done'`, check `codeInspection` (or other objective data) against `requiredCapabilities` from classify result. If contradiction → auto-reject done, force continue.

---

## Phased Implementation Plan (Updated)

### P0 — Deterministic Verification Gate (Semantic)
**Priority**: Critical — kills hallucination loops permanently
**Effort**: Small (infrastructure exists, just needs semantic extension)
**Risk**: Low (additive — adds a code gate, doesn't change LLM flow)

#### What
Extend the existing `CompletionVerifier` / `PostExecuteValidator` to check **field values**, not just key presence. When reviewer returns `done`, gate against `requiredCapabilities` from classify result.

#### How — 3 small changes

**Change 1: Add `postCompletionChecks` to `ToolVerificationProbe`**

File: `lib/services/agent_runtime/runtime_models.dart` (line ~292)

```dart
class ToolVerificationProbe {
  const ToolVerificationProbe({
    required this.kind,
    this.entityType = '',
    this.expectPresent = true,
    this.selectorArgKey = '',
    this.expectedDataKeys = const [],
    this.postCompletionChecks = const [],  // NEW
  });

  // ... existing fields ...

  /// Semantic checks: verify specific field VALUES in result.data.
  /// Each check specifies a dotted path, expected value, and reject reason.
  /// Evaluated AFTER expectedDataKeys presence check passes.
  final List<PostCompletionCheck> postCompletionChecks;
}

class PostCompletionCheck {
  const PostCompletionCheck({
    required this.fieldPath,    // e.g. "codeInspection.usesUserDatabase"
    required this.mustBe,       // true or false
    required this.rejectReason, // injected as error if check fails
  });

  final String fieldPath;
  final bool mustBe;
  final String rejectReason;
}
```

**Change 2: Add `requiredCapabilities` to classify schema + result**

File: `lib/services/agent_runtime/prompt_classify.dart` (line ~102, response format)

Add to JSON schema:
```json
{
  ...
  "required_capabilities": ["usesUserDatabase", "initializesTables"],
  ...
}
```

Add to prompt rules:
```
- required_capabilities: list of capability strings the final result MUST have.
  Use "usesUserDatabase" when user asks for database/DB/persistent storage.
  Use "initializesTables" when user asks for table creation.
  Leave empty when no specific capability is required.
```

File: `lib/services/agent_runtime/classifier.dart` (line ~264, `_parseResult`)

Add to analysis Map:
```dart
'required_capabilities': json['required_capabilities'] ?? const [],
```

File: `lib/services/agent_runtime/classifier.dart` — add getter to `ClassifyResult`:
```dart
List<String> get requiredCapabilities =>
    (raw['required_capabilities'] ?? const []).cast<String>();
```

**Change 3: Wire gate in `ExecuteLoopRunner`**

File: `lib/services/agent_runtime/execute_loop_runner.dart`

At **two** `reviewStatus == 'done'` points (line ~259 for selector-done, line ~1273 for reviewer-done), add before accepting done:

```dart
// P0: Deterministic semantic verification gate
if (reviewStatus == 'done' && result.success) {
  final caps = classifyResult?.requiredCapabilities ?? [];
  if (caps.isNotEmpty && result.data != null) {
    final inspection = result.data!['codeInspection'] as Map?;
    if (inspection != null) {
      for (final cap in caps) {
        final actual = inspection[cap];
        if (actual is bool && !actual) {
          // Auto-reject: capability missing
          reviewStatus = 'continue';
          review?['status'] = 'continue';
          previousResults.add({
            'step': currentStep,
            'note': 'SYSTEM GATE: Reviewer returned done but '
                '$cap=false in codeInspection. '
                'The required capability is missing. '
                'You MUST call miniapp.patch to add it. '
                'Do NOT return done until $cap=true.',
          });
          logger.logDivergence('capability_gate_rejected', {
            'capability': cap,
            'tool': toolRequest.name,
            'step': currentStep,
          });
          break;
        }
      }
    }
  }
}
```

#### Files to touch
1. `lib/services/agent_runtime/runtime_models.dart` — add `PostCompletionCheck` class + field
2. `lib/services/agent_runtime/prompt_classify.dart` — add `required_capabilities` to schema + rules
3. `lib/services/agent_runtime/classifier.dart` — parse + expose `requiredCapabilities`
4. `lib/services/agent_runtime/execute_loop_runner.dart` — inject gate at both `done` points
5. `test/miniapp_patch_test.dart` — new test: reviewer says done, codeInspection contradicts → auto-reject

#### Acceptance criteria
- [ ] When `codeInspection.usesUserDatabase=false` and `requiredCapabilities` includes `"usesUserDatabase"`, reviewer's `done` is auto-rejected
- [ ] Auto-reject injects clear error message with the contradiction
- [ ] Loop continues (not fails) — agent gets another chance to patch
- [ ] If agent patches correctly (usesUserDatabase=true), `done` is accepted
- [ ] `flutter analyze` clean
- [ ] Permission + module tests pass

---

### P1 — Plan-Directed Execution (toolHint)
**Priority**: High — reduces selectTool LLM calls
**Effort**: Medium
**Risk**: Medium (changes execution flow)

#### What
Add optional `toolHint` to subgoals. When present, executor skips `selectTool` LLM call and calls the hinted tool directly. LLM only fills args via a lightweight `fillArgs` call.

#### Current state
- `Subgoal` class in `goal_tree.dart` does NOT have `toolHint`
- Classify prompt schema does NOT include `toolHint` per subgoal
- Executor always calls full `selectTool` prompt

#### How
1. Add `toolHint` field to `Subgoal` in `goal_tree.dart`
2. Add `toolHint` to subgoal schema in `prompt_classify.dart`
3. In `execute_loop_runner.dart`, before selectTool LLM: if `activeSubgoal.toolHint != null && !hintConsumed` → skip to args
4. New lightweight `fillArgs` prompt in `prompt_execute.dart`
5. Fallback: if fillArgs fails → full selectTool

#### Files to touch
- `lib/services/agent_runtime/goal_tree.dart` — add `toolHint` to `Subgoal`
- `lib/services/agent_runtime/prompt_classify.dart` — add `toolHint` to subgoal schema
- `lib/services/agent_runtime/execute_loop_runner.dart` — plan-directed path
- `lib/services/agent_runtime/prompt_execute.dart` — new `fillArgs` prompt
- `test/runtime_golden_test.dart` — update for new phase

#### Acceptance criteria
- [ ] When subgoal has `toolHint`, executor calls that tool without `selectTool` LLM call
- [ ] `fillArgs` LLM call is lighter (smaller prompt)
- [ ] Falls back to `selectTool` if `fillArgs` fails
- [ ] Subgoals without `toolHint` still use `selectTool`
- [ ] LLM calls for "read → patch → verify" drops from 7 to 4-5

---

### P2 — Action Hints Injection
**Priority**: Medium — helps low models follow breadcrumbs
**Effort**: Small
**Risk**: Low (additive)

#### What
After each tool result, inject deterministic next-action hint into selectTool context based on goal tree state + tool result data.

#### How
1. New `_buildActionHint()` method in `execute_loop_runner.dart`
2. Pattern-based: codeInspection.usesUserDatabase=false + goal mentions DB → "NEXT ACTION: miniapp.patch with full-rewrite mode"
3. Inject as system note in `previousResults`

#### Files to touch
- `lib/services/agent_runtime/execute_loop_runner.dart` — `_buildActionHint()` + injection

#### Acceptance criteria
- [ ] When `codeInspection.usesUserDatabase=false` and goal mentions DB, selectTool context includes patch hint
- [ ] Hints are deterministic (not LLM-generated)
- [ ] Hints guide, don't override LLM decision

---

### P3 — Composite Tools
**Priority**: Lower — one-shot instead of multi-step
**Effort**: Medium per tool
**Risk**: Low (additive)

#### What
Composite tools that encapsulate common multi-step patterns into single call.

#### Candidates
| Tool | Replaces | LLM calls saved |
|------|----------|----------------|
| `miniapp.integrate_db` | read → patch → verify | 4-5 → 1 |
| `miniapp.integrate_theme` | read → patch | 2 → 1 |
| `miniapp.add_script` | read → patch | 2 → 1 |

#### How
1. Each composite tool = 1 `ModulePlugin` file (per AGENTS.md §4.2)
2. Internally calls same logic as `miniapp.patch` but deterministically
3. Returns `codeInspection` so P0 gate still works
4. Registered in `runtime_module_plugins.dart` with one line

#### Files to touch (per tool)
- `lib/features/miniapp/tools/miniapp_integrate_db_tool.dart`
- `lib/services/agent_runtime/runtime_module_plugins.dart`
- `lib/services/agent_runtime/tool_permission_requirements.dart`
- `test/miniapp_integrate_db_test.dart`

---

## Execution Order

```
P0 (Semantic Verification Gate)     ← START HERE
 ├── Infrastructure exists (probes, verifiers)
 ├── Just needs: postCompletionChecks + requiredCapabilities + gate wiring
 ├── 3 small code changes, 1 test
 └── Kills hallucination loops permanently

P2 (Action Hints)                   ← quick win after P0
 ├── Additive, low risk
 └── Immediate help for low models

P1 (Plan-Directed Execution)        ← structural change
 ├── Needs P0 as safety net
 └── Biggest impact on LLM call count

P3 (Composite Tools)                ← incremental
 ├── Needs P0 for verification
 └── Add per-pattern as needed
```

---

## Measuring Success

| Metric | Current | Target | How |
|--------|---------|--------|-----|
| LLM calls for "miniapp + DB" task | 7 | 3-4 | P1 + P3 |
| Hallucination loop rate | High | ~0% | P0 |
| Reviewer false-positive `done` rate | High | 0% | P0 |
| Low-model task completion rate | Low | High | P0 + P1 + P2 |
| `miniapp.patch` failure rate (low models) | High | Low | Full-rewrite (done) + P0 |

---

## Architecture Principles

- **One source of truth per concern** — tools in `ModulePlugin`, prompts in `prompt_*`, permissions in gate maps
- **Language-generic** — no per-language branches in engine, routing, or prompts
- **Reusable first** — find existing widget/helper before writing new one
- **Verify before declaring done** — state re-check gates every mutation
- **Accuracy over everything** — never hallucinate capability or claim unverified success
