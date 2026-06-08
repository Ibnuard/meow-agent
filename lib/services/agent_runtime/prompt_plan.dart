/// Planner prompt constants extracted from [PromptConstants].
library;

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
  "narrative": "1\\u20132 casual, stream-of-thought sentences in the user's language describing how you'll approach this. Show your thinking about the steps. Examples: 'I\\u0027ll split this into a few moves \\u2014 clear the old ones first, then set up the new config.' / 'Simple one \\u2014 just need to update the name and save. Quick.'"
}

Rules:
- One subgoal per user-visible outcome. Multi-target requests (e.g. "create 3 agents X, Y, Z") MUST emit one subgoal per target.
- For existing-entity work, include a validation/list/resolve subgoal before acting when the user gave a partial name, nickname, typo, or ambiguous target. Do not construct a peer workspace path from an unvalidated agent nickname.
- For information requests that need a tool, include both the retrieval/validation outcome and the final answer outcome. The task is not complete until the user receives the answer based on retrieved data.
- For the final answer outcome, set required_slots {"_operation":"respond"} (or {"tool":"none"}) and leave missing_slots empty.
- ids must be short, stable, unique within the tree (e.g. sg1, sg2, sg_create_X).
- required_slots is what the subgoal needs to be executable. Leave empty when not applicable.
- missing_slots lists slot keys still unknown. Empty means subgoal is ready to execute.
- Use status="pending" for all subgoals at planning time.
- completion_criteria are short, verifiable conditions — the reviewer uses them to confirm the task is fully done before returning final.
- narrative MUST be in the user's language, first-person, 1\\u20132 sentences max, stream-of-thought style. Show your thinking about the steps. NO tool names, NO IDs, NO mention of "goal tree" or "subgoals". Use everyday words.''';