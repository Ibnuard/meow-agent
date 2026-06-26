# RUNTIME_ENGINE_V5.md — Progressive Skill-Loaded Runtime Plan

> Draft plan for making Meow Agent faster, lighter, and more accurate by
> replacing the current "load everything upfront" prompt strategy with
> progressive context loading.
>
> This document is a plan for runtime-v5. It does not replace
> **[AGENTS.md](./AGENTS.md)** or **[ARCHITECTURE.md](./ARCHITECTURE.md)**.
> All implementation must still follow the existing development rules:
> prompt text stays in `prompt_*` files, tools come from `ModulePlugin`,
> permissions come from the gate maps, and mutations must be verified.

---

## 1. Problem

The current runtime analyzer carries too much context before it knows what the
user wants. `prompt_analyze.dart` currently includes broad routing rules, world
model notes, database schema details, tool group definitions, module examples,
multi-target behavior, ambiguity rules, and response schema details.

That makes the first LLM call expensive and slow even for simple turns. It also
increases the chance that irrelevant examples influence routing.

The goal of runtime-v5 is to keep the first decision small:

```
What kind of turn is this?
Which capability area is needed?
Do we need tools?
Do we need to ask a clarification first?
```

Only after that decision should the runtime load detailed tool/module context.

---

## 2. Goals

1. **Faster first response**
   - Chat-only messages should bypass the full agentic runtime.
   - Agentic messages should load only relevant capability context.

2. **Smaller analyzer prompt**
   - `prompt_analyze.dart` should keep generic analyzer rules only.
   - Module-specific examples and world-model details move into predefined
     skill profiles.

3. **Better accuracy through narrower context**
   - The model should see the exact relevant capability context instead of all
     tools and all examples.
   - Runtime selection should be capability-aware, permission-aware, and
     risk-aware.

4. **No loss of safety**
   - Tool risk and confirmation still come from `ToolDefinition`.
   - Permissions still come from `tool_permission_requirements.dart`.
   - Mutating tools still require `verificationProbe`.
   - LLM "done" is still not proof.

---

## 3. Non-Goals

- Do not create a second tool registry.
- Do not duplicate `ModulePlugin` tool definitions.
- Do not move LLM prompt prose into random feature files.
- Do not add per-language word lists or per-language routing branches.
- Do not remove deterministic validation, permission gates, or confirmation
  gates for speed.
- Do not make the master skill a giant prompt dump.

---

## 4. Proposed Flow

Runtime-v5 should use progressive context loading:

```
User message
  │
  ▼
Fast route/classifier
  │
  ├─ route = chat
  │    └─ reply directly with minimal context, no tool schemas, no planner
  │
  └─ route = agentic
       │
       ▼
Load master skill index
       │
       ▼
Select 1..N predefined skill profiles
       │
       ▼
Load only selected skill context + exact relevant tool definitions
       │
       ▼
Analyze/reflect/plan as needed
       │
       ▼
Execute through ToolRouter
       │
       ▼
Validate with PostExecuteValidator / result data / snapshot probes
       │
       ▼
Verbalize final response
```

The master skill index is a routing map, not a full manual. It should help the
runtime choose exact skill profiles. Detailed examples and contracts live in the
selected profiles.

---

## 5. Predefined Skills

Predefined skills are runtime capability profiles. They describe when a module
or capability should be loaded, what tools belong to it, and what constraints
the model must respect.

Recommended location:

```text
lib/services/agent_runtime/predefined_skills/
  predefined_skill.dart
  predefined_skill_registry.dart
  meow_agent_skill.dart
  modules/
    app_skill.dart
    clipboard_skill.dart
    database_skill.dart
    files_skill.dart
    system_skill.dart
    workflow_skill.dart
```

Use underscores in the Dart path. If an external asset folder is ever needed,
keep it data-only and still assemble LLM-facing prompt text through
`prompt_*`/`PromptConstants`.

### 5.1 Skill Profile Shape

A skill profile should be short and structured:

```dart
class PredefinedSkill {
  final String id;
  final String title;
  final String summary;
  final List<String> toolGroups;
  final List<String> toolNames;
  final List<String> useWhen;
  final List<String> avoidWhen;
  final List<String> requiredContextKeys;
  final List<String> examples;
}
```

The examples must be English-only and language-generic. They should describe
intent patterns semantically, not enumerate language-specific trigger words.

### 5.2 Master Skill

`meow_agent_skill.dart` should be a compact index:

- available skill ids
- one-line summary per skill
- related tool group names
- risk category hints
- permission/context hints
- "load this skill when..." notes

It should not contain full SQLite schemas, long examples, or full tool manuals.

### 5.3 Module Skills

Each module skill can contain the details currently bloating
`prompt_analyze.dart`, for example:

- app opening/listing rules
- database user-table contract
- system database introspection contract
- files workspace world model
- workflow scheduling constraints
- notification read/reply constraints
- attachment inspection contract

The skill may reference tool names, but the source of truth for tool existence
remains `ModulePlugin`.

---

## 6. Analyzer Slimming Plan

`prompt_analyze.dart` should keep:

- analyzer identity and response schema
- chat vs agentic decision rules
- language detection rules
- missing-info behavior
- task relation behavior
- generic multi-target rules
- generic bulk selector rules
- generic ambiguity policy
- selected skill id output contract

`prompt_analyze.dart` should move out:

- long module-specific examples
- database schema details
- file workspace manual
- system/profile/memory use-case list
- exact tool-chain examples such as `app.resolve` then `app.open`
- module-by-module capability explanation

New analyzer response shape should include skill selection:

```json
{
  "route": "chat | agentic",
  "intent": "short.intent.name",
  "goal": "one sentence describing what user wants",
  "requires_tools": true,
  "selected_skill_ids": ["meow.database"],
  "risk": "safe | sensitive | dangerous",
  "detected_language": "ISO 639-1 code",
  "tool_groups": ["database"],
  "missing_info": [],
  "subgoal_seeds": [],
  "task_relation": "none | continuation | revision | new_task",
  "direct_response": null
}
```

The analyzer may select multiple skills when the intent crosses capability
boundaries, for example `["meow.files", "meow.agent"]`.

---

## 7. Prompt Ownership

Runtime-v5 must still obey the existing prompt rules:

- reusable prompt prose stays in `prompt_*` files
- `PromptConstants` exposes prompt accessors
- `PromptTemplates` assembles final prompts
- dynamic context is passed through typed parameters
- predefined skills provide structured context, not scattered inline prompts

If a skill contains LLM-facing text, that text must be intentionally assembled
through the runtime prompt layer. Do not concatenate arbitrary prose inside
`runtime_engine.dart`, `planner.dart`, or module plugins.

---

## 8. Execution And Validation

Skill loading changes what the model sees. It must not change the safety model.

Required invariants:

- Tool availability is read from registered `ModulePlugin`s.
- Tool risk and confirmation are read from `ToolDefinition`.
- Permission checks happen in `ToolRouter`.
- Mutating tools must have verification probes.
- `PostExecuteValidator` re-checks successful mutations.
- Database/system state claims must be grounded by live reads.
- Capability questions use live tool/config reads, not generic model memory.

The skill layer is a routing/context layer only. It is not an execution layer.

---

## 9. Suggested Implementation Phases

### Phase 1 — Add Skill Data Model

- Add `predefined_skills/` models and registry.
- Add compact master skill index.
- Add initial module skills for the highest-volume areas:
  - `meow.app`
  - `meow.system`
  - `meow.database`
  - `meow.files`
  - `meow.workflow`
- Add tests that skill ids are unique and referenced tool groups are valid.

### Phase 2 — Add Skill Selection To Analyzer

- Extend analyzer JSON with `selected_skill_ids`.
- Keep old `tool_groups` for compatibility.
- Use selected skill ids to narrow later prompt context.
- Fall back to current behavior when skill selection is empty or invalid.

### Phase 3 — Move Examples Out Of Analyzer

- Move module-specific examples from `prompt_analyze.dart` into skill profiles.
- Keep only generic analyzer rules in `prompt_analyze.dart`.
- Verify analyzer outputs remain stable for golden tests.

### Phase 4 — Lazy Tool Context

- Load exact tool definitions only after selected skills/tool groups are known.
- Keep deterministic fallback for low-confidence or multi-domain requests.
- Measure token count before and after.

### Phase 5 — Fast Chat Bypass

- Ensure chat route avoids analyzer/reflect/plan/execute when tools are not
  needed.
- Use minimal memory/persona context only when needed.
- Never answer state/capability questions from chat route without tools.

---

## 10. Test Plan

Update or add focused tests:

- analyzer returns `route="chat"` for ordinary chat
- analyzer returns `route="agentic"` for state mutation
- analyzer selects one skill for single-domain tasks
- analyzer selects multiple skills for cross-domain tasks
- ambiguous requests ask clarification and do not select execution tools
- invalid skill ids are ignored or repaired deterministically
- module plugin tests still pass
- permission coverage still passes
- runtime golden tests still pass after prompt migration

Relevant suites:

```text
test/runtime_golden_test.dart
test/module_plugin_test.dart
test/tool_permission_coverage_test.dart
```

---

## 11. Success Metrics

Track before/after:

- analyzer prompt token count
- total tokens per simple chat turn
- total tokens per simple tool turn
- first response latency
- number of LLM calls per turn
- route accuracy on chat vs agentic benchmark set
- tool selection accuracy on module benchmark set
- mutation verification failure/recovery rate

The target is not only fewer tokens. The target is fewer irrelevant tokens while
preserving grounded execution.

---

## 12. Open Questions

1. Should skill profiles be Dart constants first, or JSON assets loaded at
   runtime?
2. Should skill selection be one LLM call, deterministic keyword/capability
   matching, or hybrid?
3. Should `ToolCatalog.select` become skill-aware, or should skills sit one
   layer above it?
4. How much live registry metadata should be included in the master skill index?
5. Should capability questions route to `system.tools.list` immediately, or use
   `meow.system` first and let execution pick the exact tool?

---

## 13. Guiding Principle

Runtime-v5 should make the model see less, but know exactly where to look next.

The analyzer should not be a full manual. It should be a fast, accurate router.
The selected skill profile should provide the relevant manual. The registered
tools, permission gates, and validators remain the source of truth for what the
agent can safely do.
