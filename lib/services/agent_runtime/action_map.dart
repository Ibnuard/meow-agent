/// Canonical Action Map — the single source of truth for intent → tool routing.
///
/// Each entry maps a user-visible outcome (intent) to its canonical tool path.
/// The runtime uses this to:
///   1. Render a minimal "allowed path" block in prompts (filtered by domain).
///   2. Soft-guard: warn + hint when the LLM picks an off-path tool.
///
/// Design principles:
///   - Generic: no app names, no agent names, no language-specific words.
///   - Positive: tells the LLM what TO do, not what NOT to do.
///   - Stable: adding a tool = adding one entry. No multi-file edits.
library;

/// A single canonical action entry.
class CanonicalAction {
  const CanonicalAction({
    required this.domain,
    required this.intentKeywords,
    required this.canonicalTools,
    this.notTools = const [],
    this.note = '',
  });

  /// Tool group domain (matches analyzer's tool_groups enum).
  final String domain;

  /// Keywords that match this entry. Matched against the analyzer's `intent`
  /// field via substring/contains — e.g. ["create", "agent"] matches
  /// "create_agent", "create.agents", "create_new_agent".
  /// ALL keywords in the list must be present (AND logic).
  final List<String> intentKeywords;

  /// Ordered list of tools that accomplish this outcome.
  /// LLM should call these in order (or a subset when steps are optional).
  final List<String> canonicalTools;

  /// Tools that look plausible but are OFF-PATH for this intent.
  /// Soft guard uses this to detect and hint.
  final List<String> notTools;

  /// Optional short note rendered in prompt to explain WHY.
  /// Keep under 15 words. Empty = no note rendered.
  final String note;
}

/// The canonical action map. Order does not matter — lookup scans all entries.
const List<CanonicalAction> canonicalActionMap = [
  // ─── System / Agent Management ─────────────────────────────────────────────

  CanonicalAction(
    domain: 'system',
    intentKeywords: ['create', 'agent'],
    canonicalTools: ['system.config.patch'],
    notTools: ['files.mkdir', 'files.write', 'files.create'],
    note: 'Runtime auto-creates workspace and template files.',
  ),
  CanonicalAction(
    domain: 'system',
    intentKeywords: ['clone', 'agent'],
    canonicalTools: ['system.config.patch'],
    notTools: ['files.mkdir', 'files.write', 'files.create'],
    note: 'Clone = create with copied config. Runtime handles workspace.',
  ),
  CanonicalAction(
    domain: 'system',
    intentKeywords: ['duplicate', 'agent'],
    canonicalTools: ['system.config.patch'],
    notTools: ['files.mkdir', 'files.write', 'files.create'],
    note: 'Same as clone.',
  ),
  CanonicalAction(
    domain: 'system',
    intentKeywords: ['delete', 'agent'],
    canonicalTools: ['system.config.patch'],
    notTools: ['files.delete'],
    note: 'Runtime deletes workspace folder automatically.',
  ),
  CanonicalAction(
    domain: 'system',
    intentKeywords: ['edit', 'persona'],
    canonicalTools: ['files.write'],
    note: 'Write to Agents/<name>/SOUL.md for persona changes.',
  ),
  CanonicalAction(
    domain: 'system',
    intentKeywords: ['edit', 'soul'],
    canonicalTools: ['files.write'],
    note: 'Write to Agents/<name>/SOUL.md.',
  ),
  CanonicalAction(
    domain: 'system',
    intentKeywords: ['provider'],
    canonicalTools: ['system.config.patch'],
  ),
  CanonicalAction(
    domain: 'system',
    intentKeywords: ['module'],
    canonicalTools: ['system.config.patch'],
  ),
  CanonicalAction(
    domain: 'system',
    intentKeywords: ['active', 'agent'],
    canonicalTools: ['system.config.patch'],
  ),
  CanonicalAction(
    domain: 'system',
    intentKeywords: ['active', 'provider'],
    canonicalTools: ['system.config.patch'],
  ),
  CanonicalAction(
    domain: 'system',
    intentKeywords: ['active', 'model'],
    canonicalTools: ['system.config.patch'],
  ),
  CanonicalAction(
    domain: 'system',
    intentKeywords: ['profile', 'update'],
    canonicalTools: ['system.profile.update'],
    notTools: ['files.write', 'system.config.patch'],
    note: 'Dedicated tool for SOUL.md identity fields.',
  ),
  CanonicalAction(
    domain: 'system',
    intentKeywords: ['identity'],
    canonicalTools: ['system.profile.update'],
    notTools: ['files.write', 'system.config.patch'],
  ),
  CanonicalAction(
    domain: 'system',
    intentKeywords: ['remember'],
    canonicalTools: ['system.memory.append'],
    notTools: ['files.write'],
  ),
  CanonicalAction(
    domain: 'system',
    intentKeywords: ['memory', 'append'],
    canonicalTools: ['system.memory.append'],
    notTools: ['files.write'],
  ),
  CanonicalAction(
    domain: 'system',
    intentKeywords: ['tools', 'list'],
    canonicalTools: ['system.tools.list'],
    note: 'Never answer capability questions from memory.',
  ),
  CanonicalAction(
    domain: 'system',
    intentKeywords: ['capabilities'],
    canonicalTools: ['system.tools.list'],
  ),
  CanonicalAction(
    domain: 'system',
    intentKeywords: ['config', 'read'],
    canonicalTools: ['system.config.read'],
  ),

  // ─── App / Launch ──────────────────────────────────────────────────────────

  CanonicalAction(
    domain: 'app',
    intentKeywords: ['open', 'app'],
    canonicalTools: ['app.resolve', 'app.open'],
    notTools: ['app_agent.inspect', 'app_agent.click'],
    note: 'resolve → open. Done after open unless further UI interaction.',
  ),
  CanonicalAction(
    domain: 'app',
    intentKeywords: ['launch'],
    canonicalTools: ['app.resolve', 'app.open'],
    notTools: ['app_agent.inspect'],
  ),
  CanonicalAction(
    domain: 'app',
    intentKeywords: ['open', 'url'],
    canonicalTools: ['intent.open_url'],
  ),

  // ─── App Agent / Screen Automation ─────────────────────────────────────────

  CanonicalAction(
    domain: 'app_agent',
    intentKeywords: ['find', 'screen'],
    canonicalTools: ['app_agent.find_by_text'],
    notTools: ['app_agent.inspect'],
    note: 'find_by_text is faster and more reliable than inspect+scan.',
  ),
  CanonicalAction(
    domain: 'app_agent',
    intentKeywords: ['return', 'meow'],
    canonicalTools: ['system.rtb'],
    notTools: ['app.open'],
    note: 'Dedicated return-to-base tool. Never use app.open for this.',
  ),
  CanonicalAction(
    domain: 'app_agent',
    intentKeywords: ['return', 'base'],
    canonicalTools: ['system.rtb'],
    notTools: ['app.open'],
  ),

  // ─── Notes ─────────────────────────────────────────────────────────────────

  CanonicalAction(
    domain: 'notes',
    intentKeywords: ['create', 'note'],
    canonicalTools: ['notes.create'],
    notTools: ['files.write', 'files.create'],
  ),
  CanonicalAction(
    domain: 'notes',
    intentKeywords: ['delete', 'note'],
    canonicalTools: ['notes.delete'],
    notTools: ['files.delete'],
  ),

  // ─── Calendar ──────────────────────────────────────────────────────────────

  CanonicalAction(
    domain: 'calendar',
    intentKeywords: ['create', 'event'],
    canonicalTools: ['calendar.create'],
  ),
  CanonicalAction(
    domain: 'calendar',
    intentKeywords: ['delete', 'event'],
    canonicalTools: ['calendar.delete'],
  ),

  // ─── Workflow ──────────────────────────────────────────────────────────────

  CanonicalAction(
    domain: 'workflow',
    intentKeywords: ['create', 'workflow'],
    canonicalTools: ['workflow.create'],
  ),
  CanonicalAction(
    domain: 'workflow',
    intentKeywords: ['delete', 'workflow'],
    canonicalTools: ['workflow.delete'],
  ),
  CanonicalAction(
    domain: 'workflow',
    intentKeywords: ['toggle', 'workflow'],
    canonicalTools: ['workflow.toggle'],
  ),

  // ─── Chat ──────────────────────────────────────────────────────────────────

  CanonicalAction(
    domain: 'chat',
    intentKeywords: ['send', 'chat'],
    canonicalTools: ['chat.send'],
    notTools: ['communication.send_sms'],
    note: 'Internal Meow chat delivery, not external messaging.',
  ),

  // ─── Communication ─────────────────────────────────────────────────────────

  CanonicalAction(
    domain: 'communication',
    intentKeywords: ['call'],
    canonicalTools: ['communication.call'],
  ),
  CanonicalAction(
    domain: 'communication',
    intentKeywords: ['sms'],
    canonicalTools: ['communication.send_sms'],
  ),

  // ─── Web ───────────────────────────────────────────────────────────────────

  CanonicalAction(
    domain: 'web',
    intentKeywords: ['fetch', 'url'],
    canonicalTools: ['web.fetch'],
  ),
];

// ─── Lookup utilities ────────────────────────────────────────────────────────

/// Find all matching canonical actions for a given intent string.
///
/// Matches when ALL keywords in an entry are present as substrings
/// (case-insensitive) in [intent]. Returns entries sorted by specificity
/// (more keywords = more specific = first).
List<CanonicalAction> matchIntent(String intent) {
  final lower = intent.toLowerCase();
  final matches = canonicalActionMap.where((entry) {
    return entry.intentKeywords.every((kw) => lower.contains(kw));
  }).toList();
  // Sort by specificity: more keywords = better match.
  matches.sort((a, b) => b.intentKeywords.length - a.intentKeywords.length);
  return matches;
}

/// Get canonical tools for an intent. Returns empty if no match.
List<String> canonicalToolsFor(String intent) {
  final matches = matchIntent(intent);
  if (matches.isEmpty) return const [];
  return matches.first.canonicalTools;
}

/// Get off-path tools for an intent. Returns empty if no match.
List<String> offPathToolsFor(String intent) {
  final matches = matchIntent(intent);
  if (matches.isEmpty) return const [];
  return matches.first.notTools;
}

/// Check if [toolName] is off-path for [intent].
/// Returns null if no match in map or tool is not off-path.
/// Returns the canonical tools as hint if off-path.
List<String>? checkOffPath(String intent, String toolName) {
  final matches = matchIntent(intent);
  if (matches.isEmpty) return null;
  final best = matches.first;
  if (best.notTools.contains(toolName)) {
    return best.canonicalTools;
  }
  return null;
}

/// Filter action map entries by domain (for prompt rendering).
/// Returns entries matching any of the given [domains].
List<CanonicalAction> filterByDomains(List<String> domains) {
  return canonicalActionMap
      .where((e) => domains.contains(e.domain))
      .toList();
}

/// Render a compact prompt block for the given domains.
/// Used by prompt assembly to inject only relevant action paths.
String renderForPrompt(List<String> domains) {
  final entries = filterByDomains(domains);
  if (entries.isEmpty) return '';
  final buf = StringBuffer()
    ..writeln('CANONICAL ACTION PATHS (use ONLY these tools for each outcome):');
  for (final e in entries) {
    final tools = e.canonicalTools.join(' → ');
    final noteStr = e.note.isNotEmpty ? ' — ${e.note}' : '';
    buf.writeln('• ${e.intentKeywords.join(" + ")} → $tools$noteStr');
  }
  buf.writeln(
    'If your chosen tool is not listed above for your intent, '
    'reconsider — there is likely a shorter correct path.',
  );
  return buf.toString();
}
