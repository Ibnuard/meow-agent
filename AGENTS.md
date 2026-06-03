# AGENTS.md — Meow Agent Design System & UI Consistency Rules

## Purpose

This document defines the visual identity, layout rules, spacing system, interaction behavior, UI philosophy, AND runtime engineering principles for Meow Agent.

All coding/design agents working on this project MUST follow this document to maintain a consistent experience and a correct, non-hallucinating agent runtime.

---

## Scope & Cross-References

AGENTS.md governs **design, UX, visual identity, and runtime engineering principles**.

For detailed code architecture, tool/module registration procedures, runtime loop mechanics, and testing requirements, you MUST also read:

> **[SKILLS.md](./SKILLS.md)** — the canonical codebase guide for Meow Agent.

SKILLS.md contains:
* Current architecture overview (self-registering module plugins, runtime layout)
* Runtime loop (Planner → Reflector → Executor → ToolVerbalizer)
* **One-file module plugin pattern** (extend ModulePlugin, add to runtime_module_plugins.dart)
* LLM client patterns, prompt architecture, language detection
* Verification & anti-hallucination gates
* Bulk/predicate selector architecture
* Testing requirements (golden suite, drift guard, unit tests)

---

## Runtime Engineering Principles (READ FIRST)

These override everything else in this document when coding the agent engine:

### 1. Accuracy is #1
The agent must never hallucinate a capability it doesn't have or claim success it cannot verify. When data is missing or a capability doesn't exist, tell the user honestly and quickly — do not retry, guess, or fabricate.

### 2. Language-generic, always
- NO per-language word lists for classification or routing.
- NO per-case patches ("kalau user bilang X, lakukan Y").
- NO Indonesian-specific examples in engine code or prompts.
- English-only examples in system prompts are the standard.
- The LLM handles the user's language naturally via `detected_language`.

### 3. LLM-driven, not keyword-driven
Tool selection uses the analyzer's `tool_groups` enum, NOT hardcoded keyword matching. The analyzer sees every tool and semantically decides which groups are relevant — works in any language.

### 4. Efficient ≠ stingy
More LLM calls are acceptable if they improve accuracy. But ZERO calls should be wasted (proven-redundant phases are gated by deterministic skip conditions). The engine skips reflection for trivial safe single-tool reads and skips review for terminal retrievals.

### 5. Self-registering modules
Adding a tool or module = one file (a `ModulePlugin`). There is no central registry map, dispatch switch, or catalog group map to hand-edit. `runtime_module_plugins.dart` holds one list of all plugins.

### 6. Validation before declaration
Task completion is only declared after state re-check (snapshot probe, registry re-read, or tool result data keys). Never trust the LLM's self-report of "done" alone.

### 7. Generic entity matching
Bulk operations (delete all, filter by predicate) use structured selectors (`"scope":"all"`, `"scope":"predicate"` with `op: ends_with/starts_with/contains/equals/regex`). The runtime evaluates against live snapshot data. The LLM supplies the pattern; the runtime does the matching — the LLM never enumerates entity names.

### 8. Real LLM testing for flow validation
When testing a complex multi-turn flow (create + delete, bulk predicate, cross-reference impact analysis, workflow chaining) where scripted LLM doubles cannot capture real model behavior, use the real OpenAI-compatible provider configured in `.env`. The test harness in `test/support/` accepts a live `OpenAiCompatibleClient` — swap the `ScriptedLlmClient` for it when running manual accuracy tests.

Credentials live in `.env` (gitignored). Copy `.env.example` to `.env` and fill in your provider details:
```
MEOW_TEST_BASE_URL=https://your-provider.example.com/v1
MEOW_TEST_API_KEY=sk-your-key-here
MEOW_TEST_MODEL=your-model-name
```

Never hardcode credentials. Never commit `.env`.

---

## Meow Agent Identity

Meow Agent is NOT:
* a developer dashboard
* a terminal app
* an enterprise admin panel
* a hacker-style UI

Meow Agent IS:
> a modern Android-native AI companion operating system.

The app should feel:
* calm
* futuristic
* lightweight
* ambient
* premium
* minimal
* approachable

Inspired by:
* OpenAI Mobile
* Arc Search
* Linear
* Perplexity
* Raycast
* Nothing OS
* visionOS floating surfaces

---

# CORE DESIGN PRINCIPLES

## 1. Controlled Emptiness

The UI must breathe.

Do NOT stack elements tightly. Do NOT overfill the screen.

Good UI relies on: spacing, rhythm, hierarchy, subtle contrast.

The app should feel: spacious but intentional.

## 2. Floating Surfaces

Most UI components should feel detached from the background.

Use: floating cards, rounded surfaces, soft shadows, translucent layers, subtle depth.
Avoid: flat harsh containers, heavy separators, rigid dashboard layouts.

## 3. Soft Futuristic

The app should feel futuristic WITHOUT cyberpunk overload, neon everywhere, hacker aesthetics, or excessive gradients.

Target: ambient AI operating system.

## 4. Calm Interaction

Animations and transitions must feel: smooth, subtle, premium, lightweight.
Avoid: aggressive bounce, flashy transitions, exaggerated motion.

---

# GLOBAL STYLE RULES

## Background

Primary background: `#020817`. Deep navy, clean, minimal. No pure black, colorful backgrounds, or busy textures.

## Color System

| Role | Value |
|------|-------|
| Primary Blue (active states, focused inputs, FAB) | `#3B82F6` |
| Surface (cards, modals, dock, floating containers) | `rgba(15,23,42,0.82)` |
| Text primary | `#E5E7EB` |
| Text secondary | `#94A3B8` |
| Text muted/inactive | `#64748B` |
| Borders | `rgba(255,255,255,0.05)` |

Never use: thick borders, bright outlines, hard dividers.

## Spacing System

Spacing consistency is critical. The app should NEVER feel cramped.

| Context | Value |
|---------|-------|
| Section Title → Subtitle | 10–14px |
| Subtitle → Input | 8–10px |
| Input → Input | 14–18px |
| Section → Section | 24–32px |
| Card Internal Padding | 18–24px |

## Safe Area

Always support: Android edge-to-edge, gesture navigation, floating bottom dock.

UI elements must NEVER collide with: Android gesture area, virtual navigation bar, floating FAB. Use SafeArea properly.

## Typography

Typography should feel modern, calm, highly readable, soft.
Avoid: overly bold typography, giant headings, compressed text.

Hierarchy:
* Screen Title: medium weight, slightly emphasized, never oversized
* Section Title: subtle emphasis, clean spacing
* Field Labels: small, muted, secondary hierarchy
* Body Text: clean, readable, relaxed line height

## Containers

All surfaces: large rounded corners (20–28px), subtle depth, soft translucent backgrounds.
Floating dock: 999px (pill shape).
FAB: rounded rectangle (16px radius), NOT circular. Matches the overall rounded-surface language.
Avoid: flat rectangles, harsh cards, Material default appearance.

Shadows must be: soft, ambient, subtle. Goal: floating AI surfaces.

## FAB (Floating Action Button)

All list screens that own their own Scaffold (not embedded in the bottom-nav shell) use a unified FAB:

```dart
FloatingActionButton(
  backgroundColor: cs.primary,
  foregroundColor: Colors.white,
  elevation: 0,
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(16),
  ),
  child: const Icon(Icons.add_rounded, size: 28),
)
```

Rules:
* Hide FAB during multi-select mode (`_selectionMode ? null : FAB`).
* Screens inside the main bottom-nav shell (e.g. Agent list) must NOT use FAB — use AppBar action instead, since the floating dock clips FABs unpredictably across devices.
* Never use `CircleBorder()` — the app's visual language is rounded rectangles, not circles.

## Input Fields

Inputs must feel: soft, modern, premium, calm.
Rounded, slightly translucent, subtle gradient, faint inner highlight.
Focused: softly glow blue, slightly brighten border, ambient.
Avoid: Flutter default TextField, thick borders, enterprise form styling.

## Buttons

Soft and premium, subtle gradients, rounded corners, minimal elevation.
Primary CTA: blue accent, subtle glow, clean typography.
Avoid: bulky buttons, enterprise buttons, excessive shadows.

## Icons

Consistent stroke weight, minimal, modern, slightly rounded.
Avoid mixing filled / outline / thin / thick styles randomly.

## Cards

Interactive, lightweight, floating.
Use: translucent navy surfaces, subtle border, soft shadow, rounded corners.
Avoid: giant dashboard cards, excessive padding, rigid grid systems.

## Empty States

Educate naturally, feel friendly, guide the user.
Avoid: technical language, cold placeholders, generic empty boxes.

Structure: Icon/Illustration → Title → Description → Primary Action.

## Motion

Animations: soft, elegant, premium, ambient.
Recommended: fade, smooth slide, subtle scale, gentle glow pulse.
Avoid: spring explosions, exaggerated bounce, flashy transitions.

## Bottom Navigation

Floating dock style, full pill shape, translucent surface, soft blur.
Must float above bottom edge, respect SafeArea, never touch Android gesture area.

## Chat FAB

The center Chat button is the heart of the app.
Slightly larger than others, softly glowing, premium and calm.
Avoid: giant oversized FAB, aggressive neon glow, cartoonish bounce.

---

# COMPONENT SYSTEM

Reusable components: `AppScaffold`, `FloatingDock`, `ChatFAB`, `GlassCard`, `MeowTextField`, `SectionHeader`, `SettingsTile`, `ModuleCard`, `EmptyStateCard`, `PrimaryButton`.

Avoid duplicated styling.

---

# DEVELOPMENT RULES

Optimize for: Flutter Material 3, reusable widgets, dark mode first, responsive layouts, edge-to-edge Android.

## No Hardcoded Language Strings

All user-facing text MUST go through `AppStrings` (defined in `lib/features/settings/data/app_language_provider.dart`).

* Every string getter returns the correct variant based on `isId` (Indonesian) or English.
* Screens receive `AppStrings` via `final s = AppStrings(resolveLanguageCode(langPref));`.
* NEVER write inline Indonesian or English text directly in widget trees.
* Pattern: `s.wfListRunNow` → `isId ? 'Jalankan sekarang' : 'Run now'`.
* New features must add their strings to AppStrings BEFORE referencing them in UI code.

## No Hardcoded Prompts

All LLM prompt strings MUST live in the prompt constants system under `lib/services/agent_runtime/`:

* `prompt_constants.dart` — central accessor class (`PromptConstants.*`)
* `prompt_system.dart` — system-level rules
* `prompt_analyze.dart` — analyzer phase
* `prompt_reflect.dart` — reflector phase
* `prompt_plan.dart` — planner phase
* `prompt_execute.dart` — tool selector & reviewer
* `prompt_context.dart` — chat, compactor, repair, pending action, memory, workflow API context

Rules:
* NEVER write inline prompt text in feature code (workflow_runner, runtime_engine, etc.).
* Add new prompt constants to the appropriate phase file, then expose via `PromptConstants`.
* Prompts are English-only. The LLM responds in the user's detected language naturally.
* Use interpolation parameters (e.g. `String promptFoo(String name)`) for dynamic values.

---

# DESIGN PHILOSOPHY

Every screen should feel like: _"You are interacting with an ambient AI operating system."_

NOT: server management software, Android settings app, terminal wrapper, cyberpunk dashboard.

The UI should communicate: intelligence, calmness, safety, modernity, simplicity.

---

# FINAL RULE

When designing anything in Meow Agent, always ask:

> "Does this feel like a calm futuristic AI companion?"

If the answer is no: simplify it.
