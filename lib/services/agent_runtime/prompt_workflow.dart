library;

/// Workflow runner prompt constants.
///
/// Contains reusable prompt blocks used by the WorkflowRunner when building
/// context for chained steps and notification-triggered runs.
/// English-only by design — the LLM handles the user's language naturally.

// ─── Chained step instruction block ─────────────────────────────────────────

/// Builds the user message for a chained workflow step (i ≥ 1).
///
/// The previous step output is delivered as a [recentMessages] conversation
/// turn, NOT inlined here, so the analyzer keys on the actual instruction
/// rather than the previous payload's keywords.
String promptChainedUserMessage({
  required int stepIndex,
  required int totalSteps,
  required String userInstruction,
}) {
  return '''[CHAINED WORKFLOW STEP ${stepIndex + 1} of $totalSteps]
The previous step's output is in the conversation above (most recent assistant turn). Treat it as data already retrieved — do NOT call any tool to fetch, read, list, or summarize the same kind of data again.
If this step asks to send / share / save / write / forward / post / deliver the data, choose a delivery tool that takes a content body (chat.send, notes.create, files.write, intent.open_url, etc.). Decide the body from the instruction: if it asks to relay / forward the data as-is, use the previous turn's content verbatim; if it asks you to respond / react / reply / comment on / rephrase the data, WRITE YOUR OWN new text that builds on it (do not just resend the same content). Either way, stay grounded in the real facts (items, names, numbers, dates) — never invent details that are not in the previous output.

Instruction for this step:
$userInstruction''';
}

// ─── Step markers (synthetic conversation turns) ────────────────────────────

/// Synthetic user turn placed BEFORE the assistant turn holding the previous
/// step output. Gives the conversation a natural user-asked shape so the
/// planner sees turn-taking instead of an orphaned assistant turn.
String promptPreviousStepMarker(int stepIndex) {
  return '[Previous workflow step $stepIndex output below — already '
      'produced for this chain. Use it as authoritative data for the '
      'next step instead of fetching again.]';
}

/// Synthetic user turn placed BEFORE the assistant turn holding an
/// explicitly-referenced earlier step's output (`@stepN`, n < current).
String promptEarlierStepMarker(int stepNumber) {
  return '[Workflow step $stepNumber output below — referenced via @step'
      '$stepNumber. Authoritative data already produced earlier in this '
      'chain; use it directly, do not re-fetch.]';
}

// ─── Trigger context wrapper (notification-keyword fired workflows) ─────────

/// Wraps a user prompt with a [TRIGGER CONTEXT] block describing the single
/// notification that fired the workflow. Tells the agent the data is inline
/// so it doesn't hunt for notification-reading tools.
///
/// Returns [prompt] unchanged when [notif] is empty.
String promptTriggerContextWrapper({
  required String prompt,
  required String notif,
  String app = '',
  String keyword = '',
  String title = '',
  String body = '',
}) {
  if (notif.isEmpty) return prompt;

  final buf = StringBuffer()
    ..writeln('[TRIGGER CONTEXT]')
    ..writeln(
      'This workflow run was fired by ONE specific incoming Android '
      'notification — the single one that matched your trigger keyword. '
      'That notification is delivered to you INLINE below and is the '
      'COMPLETE and ONLY input for this step. You already have it; you do '
      'NOT need any tool to read, fetch, or look it up.',
    )
    ..writeln(
      'CRITICAL: Do NOT call notification.read_recent, '
      'notification.summarize, notification.classify, or any other tool '
      'that reads the notification tray. Those return DIFFERENT, unrelated '
      'notifications and will produce the wrong result (a general digest of '
      'everything instead of this one item). Work ONLY from the single '
      'inline notification below.',
    )
    ..writeln(
      'Treat the inline notification text as the authoritative source. '
      'When summarizing / extracting, work directly from this text and '
      'preserve only facts that are actually present in it. Do NOT invent '
      'items, names, numbers, or details that are not in the notification, '
      'and do NOT ask the user to forward / paste the content again.',
    );
  if (app.isNotEmpty) buf.writeln('- App: $app');
  if (keyword.isNotEmpty) buf.writeln('- Matched keyword: $keyword');
  if (title.isNotEmpty) buf.writeln('- Title: $title');
  if (body.isNotEmpty) buf.writeln('- Body: $body');
  buf
    ..writeln('[/TRIGGER CONTEXT]')
    ..writeln()
    ..writeln('[USER PROMPT]')
    ..write(prompt);
  return buf.toString();
}
