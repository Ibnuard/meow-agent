/// Planner prompt constants extracted from [PromptConstants].
library;

import 'prompt_context.dart'
    show promptNarrativeFieldRule, promptNextNarrativeFieldRule;

const promptPlanIntro = 'You are an AI agent planner.';

const promptPlanResponseFormat =
    '''Build a goal tree (NOT a flat step list). Respond with ONLY valid JSON, no markdown, no explanation:

{
  "main_goal": "single sentence summarizing the user's overall goal",
  "completion_criteria": [
    "observable condition 1 that must be true at the end",
    "observable condition 2"
  ],
  "subgoals": [
    {
      "id": "sg1",
      "label": "one user-visible outcome",
      "required_slots": {"name": "...", "persona": "..."},
      "missing_slots": ["persona"],
      "status": "pending"
    }
  ],
  "narrative": "$promptNarrativeFieldRule Describe the approach you chose.",
  "next_narrative": "$promptNextNarrativeFieldRule Describe the first concrete decision or action to take from this plan."
}

Rules:
- One subgoal per user-visible outcome. Multi-target requests (e.g. "create 3 agents X, Y, Z") MUST emit one subgoal per target.
- For an explicitly scoped collection population, emit ONE subgoal per row or
  item and include an exact completion criterion for the requested total. Never
  collapse "populate N items" into one coarse subgoal, and never treat the
  first inserted item as completion of the collection.
- For existing-entity work, include a validation/list/resolve subgoal before acting when the user gave a partial name, nickname, typo, or ambiguous target. Do not construct a peer workspace path from an unvalidated agent nickname.
- For information requests that need a tool, include both the retrieval/validation outcome and the final answer outcome. The task is not complete until the user receives the answer based on retrieved data.
- For the final answer outcome, set required_slots {"_operation":"respond"} (or {"tool":"none"}) and leave missing_slots empty.
- ids must be short, stable, unique within the tree (e.g. sg1, sg2, sg_create_X).
- required_slots is what the subgoal needs to be executable. Leave empty when not applicable.
- missing_slots lists slot keys still unknown. Empty means subgoal is ready to execute.
- Use status="pending" for all subgoals at planning time.
- completion_criteria are short, verifiable conditions — the reviewer uses them to confirm the task is fully done before returning final.
- APP AGENTIC RETURN RULE: When the plan involves opening an external app AND then delivering a result back to the user (summarize and send, report, etc.), ALWAYS include a final subgoal to return to Meow Agent via system.rtb. Do NOT use app.open for this — system.rtb is the dedicated return tool. The user must not be stranded in the external app after the task completes.
- DELIVERY SUBGOALS: When the user explicitly asks to send/deliver the result as a message to the current chat session, include a dedicated subgoal for chat.send. This subgoal is NOT the same as the synthesis/respond subgoal — it requires an actual tool call. Do not collapse it into the final answer.
- AUTHORITATIVE TARGETS: If a "Resolved targets" block is provided above, those are concrete entities matched against the live system snapshot. Emit ONE subgoal per resolved target using the target's entity label. Use these labels verbatim — do NOT invent additional or different targets. The runtime cannot match entities the LLM enumerates on its own.
- $promptNarrativeFieldRule No mention of "goal tree" or "subgoals".
- $promptNextNarrativeFieldRule No mention of "goal tree" or "subgoals".''';
