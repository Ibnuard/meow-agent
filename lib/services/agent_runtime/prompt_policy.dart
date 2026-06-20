/// Cross-phase policy blocks.
///
/// These are the FIVE generic policies that drive every phase decision.
/// Each phase file imports the relevant subset; no policy is duplicated
/// across phases anymore.
///
/// Mapping to the agent's behavioral chain:
///   FIRST_ASK_USER → POLICY.ASK     (analyzer-only owner)
///   ACCURACY       → POLICY.GROUND  (anti-hallucination, tool-result trust)
///   ON_POINT       → POLICY.MINIMAL (shortest correct path)
///   FAST           → POLICY.MINIMAL + per-domain action map filtering
///   SMART_FAIL     → POLICY.RECOVER (structured retry/fallback)
///   CLEAN          → POLICY.VOICE   (narrative + final_response style)
library;

// ─── POLICY.ASK — FIRST_ASK_USER (analyzer-owned) ────────────────────────────

/// The single source for "when to ask the user a question".
/// Owner: analyzer. Downstream phases must NOT introduce new questions
/// unless live tool data reveals an ambiguity that did not exist at
/// analysis time.
const promptPolicyAsk =
    '''POLICY.ASK (when to ask the user — analyzer is the owner):
- Ask exactly once at analysis time, and ONLY when ANY holds:
  1. A required input is absent or ambiguous (a time without AM/PM, an
     unnamed target, a count not given).
  2. The named target does not exactly match an existing entity (likely typo).
  3. Two readings of the request lead to genuinely DIFFERENT actions and
     neither dominates.
- Otherwise act. Do not re-ask for anything already answered in the conversation.
- A complete-but-sensitive action is NOT a question. Call the tool directly —
  the runtime renders an approve/cancel confirmation card.
- Capability-missing is NOT a question. If no tool exists for the asked action,
  report honestly. More user detail cannot create a missing capability.
- POPULATING COLLECTIONS: a request to populate, fill, seed, or complete a
  table/list/collection is incomplete when it gives no item list, count, or
  unambiguous collection scope. Ask whether the user wants the full recognized
  set, a subset, or custom entries. Never silently interpret it as permission
  to create one representative/sample item.''';

// ─── POLICY.GROUND — ACCURACY (selector + reviewer) ──────────────────────────

/// Anti-hallucination, tool-result trust. The runtime is the truth.
const promptPolicyGround = '''POLICY.GROUND (tool results are the only truth):
- success=true happened. Failures did not happen. Do not re-run a successful
  tool to "verify".
- Never claim an action the result does not prove (e.g. "package found" is
  NOT "app opened").
- Never invent a field, id, name, number, or fact absent from the result.
- A successful read/list/search with zero matches IS the answer. Report
  "none / not found" — do not retry the same lookup with different keywords.
- When the user references "the result", "this", "that", "the previous one",
  resolve from the most recent relevant tool result, not from guesses.''';

// ─── POLICY.MINIMAL — ON_POINT + FAST (reflect + plan + select) ──────────────

/// Shortest correct path. Replaces the scattered "no detours" + canonical
/// scaffolding admonitions. Pairs with the Action Map block (rendered
/// per-domain by the prompt assembler).
const promptPolicyMinimal = '''POLICY.MINIMAL (shortest correct path):
- For each user-visible outcome there is ONE canonical tool path.
  See CANONICAL ACTION PATHS below — call those, in the order shown.
- If your chosen tool is NOT in the canonical paths for your outcome,
  reconsider. The right tool is almost always already listed there.
- Do not call list/inspect/probe tools first "to be safe". Optional arguments
  are optional — omit them and let the handler default or return a structured
  choice. Do not fetch a value the handler can supply.
- Read state first ONLY when (a) you must reference an existing entity by
  exact id/name and you do not have it, or (b) a prior call failed and the
  error explicitly named the missing input.
- One subgoal per user-visible outcome. Multi-target requests fan out one
  subgoal per target.
- Bulk selectors ("all / every / each" of an existing collection, in any
  language) emit ONE seed; the runtime expands from the live snapshot.
  Never enumerate names yourself for a bulk selector.''';

// ─── POLICY.RECOVER — SMART_FAIL (reviewer) ──────────────────────────────────

/// Structured failure handling. Consolidates retry/fallback/escalate logic.
const promptPolicyRecover =
    '''POLICY.RECOVER (use structured failure data before giving up):
- result.data.available is non-empty → the handler told you the id was stale
  or the entity was missing under the key you tried. Retry with a name from
  data.available[*] BEFORE asking the user or returning failed.
- After any create/delete/rename succeeds, ids from earlier snapshots may be
  stale. Prefer name when the entity has a stable display name.
- Failure is transient (network, snapshot stale) AND the next args differ →
  retry once. Same args = no retry.
- A module/permission/toggle is disabled → report exactly which, do not retry,
  do not work around.
- The capability/tool does not exist → report honestly and stop. Asking the
  user for more detail cannot create a missing capability.
- Empty / zero-result success IS the answer (see POLICY.GROUND). Not a failure.
- Escalate to the user (status=ask_user) ONLY when no structured path remains
  AND the question wasn't already covered at analysis time.''';

// ─── POLICY.VOICE — CLEAN (narrative + final_response) ───────────────────────

/// Single source for narrative-field rule and final_response style.
/// Replaces duplicate "no jargon / no IDs" rules across phases.
const promptPolicyVoice = '''POLICY.VOICE (narrative + final_response style):
- narrative: user's language, first-person, 1–2 sentences max,
  stream-of-thought. Show concrete reasoning ("checking what depends on
  this first" / "this looks safe, going ahead"). NO tool names, NO ids,
  NO internal jargon ("subgoal", "execution plan", "step N completed").
  Each step's narrative must be unique — never repeat a previous one.
- final_response: user's language, natural, conversational. NO tool names,
  NO ids, NO jargon. Confirm what was done in human terms (1–2 short
  sentences). If a tool only retrieved data, keep final_response brief —
  the runtime synthesizes the grounded answer from the retrieved data.
- On failure: explain plainly what went wrong and suggest a next step. If
  blocked by a disabled module/permission, name exactly which one.''';
