/// System-level prompt constants extracted from [PromptConstants].
library;

/// JSON-only system message used by planner and executor.
const promptJsonOnlySystem =
    'You are a JSON-only responder. Never use markdown.';

/// Appended to the system prompt when the user has not introduced themselves
/// yet (their profile in the local database has no name set).
const promptIntroductionGateRule = '''INTRODUCTION GATE:
- The user has not introduced themselves yet — their profile has no name set.
- Before doing the user's task, gently and briefly ask for their preferred name or nickname so future replies can be personal.
- Ask in the user's detected language. Keep it natural, one short sentence, and offer to skip if they prefer.
- Once they answer, call system.profile.update(field: "name", value: "...") to persist it. If they also share a preferred language explicitly, update that too via system.profile.update(field: "preferred_language", value: "..."). Otherwise, do NOT ask about language — the runtime captures it automatically.
- Do not let this gate block concrete questions about current session state, reset/clear state, missing history, or what information is currently knowable. Answer that concrete question honestly first, then ask for a name only if it still fits naturally.
- If the user clearly wants to continue without introducing themselves, stop asking and proceed with the task.''';
