import '../../core/storage/agent_memory_repository.dart';
import '../../core/storage/agent_soul_repository.dart';
import '../../core/storage/agent_skills_repository.dart';
import 'runtime_models.dart';

/// Builds LLM-facing workspace context from SQLite-backed repos.
///
/// Phase 7: SOUL/MEMORY data lives in `agent_soul` and `agent_memory` tables.
/// This class renders the structured rows into markdown-shaped strings that
/// the existing prompt templates expect, so we can swap the data source
/// without rewriting every prompt builder.
///
/// Extracted from `AgentRuntimeEngine` to keep the engine focused on
/// orchestration and reduce its line count.
class WorkspaceContextBuilder {
  WorkspaceContextBuilder({this.soulRepo, this.memoryRepo, this.skillsRepo});

  final AgentSoulRepository? soulRepo;
  final AgentMemoryRepository? memoryRepo;
  final AgentSkillsRepository? skillsRepo;

  /// Max recent entries pulled from DB before relevance filtering.
  static const int _recentMemoryPoolSize = 60;

  /// Max entries surfaced into the prompt after relevance scoring. Recent +
  /// relevant entries combined; we cap so the prompt never bloats.
  static const int _maxPromptMemoryEntries = 12;

  /// Always-keep recency window. Anything within this window is kept
  /// regardless of keyword match — fresh facts are usually relevant.
  static const Duration _alwaysKeepRecency = Duration(days: 3);

  /// Build an [AgentWorkspace] from SQLite. Falls back to empty when repos
  /// aren't injected (e.g. in tests using a default-constructed engine).
  ///
  /// When [userMessage] is provided, memory entries are scored by keyword
  /// overlap and only the top-scoring + recent ones are surfaced. Without it,
  /// the previous behavior (latest N entries) is preserved.
  Future<AgentWorkspace> build(
    String agentName,
    String agentId, {
    String? userMessage,
    List<AgentSkill>? preFilteredSkills,
  }) async {
    if (soulRepo == null && memoryRepo == null && skillsRepo == null && preFilteredSkills == null) {
      return const AgentWorkspace(
        soul: '',
        memory: '',
        skills: '',
        heartbeat: '',
      );
    }

    final soulFuture = soulRepo?.get(agentId);
    final memoryFuture = memoryRepo?.recent(
      agentId,
      limit: _recentMemoryPoolSize,
    );
    final skillsFuture = preFilteredSkills != null
        ? null
        : skillsRepo?.getActiveSkillsForAgent(agentId);

    final soul = soulFuture == null ? null : await soulFuture;
    final memoryPool = memoryFuture == null
        ? const <AgentMemoryEntry>[]
        : await memoryFuture;
    final activeSkills = preFilteredSkills ??
        (skillsFuture == null
            ? const <AgentSkill>[]
            : await skillsFuture);

    final selected = _selectRelevantMemory(
      pool: memoryPool,
      userMessage: userMessage,
    );

    return AgentWorkspace(
      soul: formatSoul(agentName, soul),
      memory: formatMemory(selected),
      skills: formatSkills(activeSkills),
      heartbeat: '',
    );
  }

  /// Pick which memory entries to inject into the prompt.
  ///
  /// Strategy:
  /// 1. Always keep entries within [_alwaysKeepRecency] (fresh wins).
  /// 2. For older entries, score by keyword overlap with [userMessage] and
  ///    pick the top scorers.
  /// 3. Cap final list at [_maxPromptMemoryEntries].
  /// 4. If [userMessage] is null/empty, fall back to the most recent N — same
  ///    behavior as before this method existed.
  static List<AgentMemoryEntry> _selectRelevantMemory({
    required List<AgentMemoryEntry> pool,
    required String? userMessage,
  }) {
    if (pool.isEmpty) return const [];

    final now = DateTime.now();
    final keywords = _extractKeywords(userMessage);

    if (keywords.isEmpty) {
      // No useful query — preserve the legacy "latest N" behavior.
      return pool.take(_maxPromptMemoryEntries).toList(growable: false);
    }

    final fresh = <AgentMemoryEntry>[];
    final scored = <_ScoredEntry>[];
    for (final entry in pool) {
      final age = now.difference(entry.createdAt);
      if (age <= _alwaysKeepRecency) {
        fresh.add(entry);
        continue;
      }
      final score = _scoreEntry(entry, keywords);
      if (score > 0) {
        scored.add(_ScoredEntry(entry: entry, score: score));
      }
    }

    scored.sort((a, b) => b.score.compareTo(a.score));

    final remainingSlots = _maxPromptMemoryEntries - fresh.length;
    final picked = <AgentMemoryEntry>[
      ...fresh,
      if (remainingSlots > 0)
        ...scored.take(remainingSlots).map((e) => e.entry),
    ];

    // Re-order chronologically (newest first) so the rendered markdown
    // matches the existing prompt expectation.
    picked.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return picked;
  }

  /// Tokenize the user message into language-generic terms.
  ///
  /// No stopword lists: runtime policy forbids per-language word lists. We keep
  /// this deliberately simple and only require a minimum token length.
  static Set<String> _extractKeywords(String? userMessage) {
    if (userMessage == null) return const {};
    final trimmed = userMessage.trim();
    if (trimmed.isEmpty) return const {};

    final tokens = trimmed
        .toLowerCase()
        .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
        .where((t) => t.length >= 4);
    return tokens.toSet();
  }

  /// Score an entry by counting language-generic term overlap with its content.
  /// Category match is a small bonus.
  static int _scoreEntry(AgentMemoryEntry entry, Set<String> keywords) {
    final content = entry.content.toLowerCase();
    var score = 0;
    for (final kw in keywords) {
      if (content.contains(kw)) score += 2;
    }
    if (keywords.contains(entry.category.toLowerCase())) score += 1;
    return score;
  }

  /// True if the user hasn't introduced themselves yet. Drives the
  /// introduction gate. Treats null, empty, and bracketed placeholders
  /// ("[Your Name]") as missing.
  static bool isUserNameMissing(AgentSoul? soul) {
    if (soul == null) return true;
    final value = (soul.userName ?? '').trim();
    if (value.isEmpty) return true;
    if (RegExp(r'^\[.*\]$').hasMatch(value)) return true;
    return false;
  }

  /// Render [AgentSoul] to the markdown shape prompt templates expect.
  static String formatSoul(String agentName, AgentSoul? soul) {
    if (soul == null) {
      return '''# Soul — $agentName

## User Identity
Name: [Your Name]
Nickname:
Preferred Language:
Timezone:

## Profile
Work Role:
Main Project:
Communication Style:
Design Preference:
''';
    }
    final buf = StringBuffer()
      ..writeln('# Soul — $agentName')
      ..writeln()
      ..writeln('## User Identity')
      ..writeln('Name: ${soul.userName ?? '[Your Name]'}')
      ..writeln('Nickname: ${soul.userNickname ?? ''}')
      ..writeln('Preferred Language: ${soul.preferredLanguage ?? ''}')
      ..writeln('Timezone: ${soul.timezone ?? ''}')
      ..writeln()
      ..writeln('## Profile')
      ..writeln('Work Role: ${soul.workRole ?? ''}')
      ..writeln('Main Project: ${soul.mainProject ?? ''}')
      ..writeln('Communication Style: ${soul.communicationStyle ?? ''}')
      ..writeln('Design Preference: ${soul.designPreference ?? ''}');
    if ((soul.persona ?? '').isNotEmpty) {
      buf
        ..writeln()
        ..writeln('## Persona')
        ..writeln(soul.persona);
    }
    return buf.toString();
  }

  /// Render memory entries to the markdown shape prompt templates expect.
  static String formatMemory(List<AgentMemoryEntry> entries) {
    if (entries.isEmpty) return '';
    final buf = StringBuffer()
      ..writeln('# Memory')
      ..writeln();
    final byCat = <String, List<AgentMemoryEntry>>{};
    for (final e in entries) {
      byCat.putIfAbsent(e.category, () => []).add(e);
    }
    for (final entry in byCat.entries) {
      buf
        ..writeln('## ${_categoryLabel(entry.key)}')
        ..writeln();
      for (final m in entry.value) {
        final date = m.createdAt.toIso8601String().split('T').first;
        buf.writeln('- $date: ${m.content}');
      }
      buf.writeln();
    }
    return buf.toString();
  }

  static String _categoryLabel(String category) {
    switch (category) {
      case 'fact':
        return 'Facts';
      case 'preference':
        return 'Preferences';
      case 'bookmark':
        return 'Bookmarks';
      case 'session':
        return 'Session Notes';
      default:
        return category;
    }
  }

  /// Filter markdown content to ensure only mobile-compatible instructions are included.
  /// Ignores paragraphs or code blocks containing desktop/terminal shell commands or folders.
  static String filterMobileCompatibleSkills(String markdownContent) {
    if (markdownContent.isEmpty) return '';

    // Split into paragraph/block units
    final blocks = markdownContent.split(RegExp(r'\n\s*\n'));
    final filteredBlocks = <String>[];

    for (var block in blocks) {
      final lowerBlock = block.toLowerCase();
      
      // Look for desktop indicators:
      final hasDesktopTerm = 
        lowerBlock.contains('desktop') ||
        lowerBlock.contains('terminal') ||
        lowerBlock.contains('bash') ||
        lowerBlock.contains('powershell') ||
        lowerBlock.contains('cmd.exe') ||
        lowerBlock.contains('cmd ') ||
        lowerBlock.contains('cmd\n') ||
        lowerBlock.contains('shell command') ||
        lowerBlock.contains('execute shell') ||
        lowerBlock.contains('/etc/') ||
        lowerBlock.contains('/var/') ||
        lowerBlock.contains('c:\\windows') ||
        lowerBlock.contains('c:\\program files');

      // Check if block contains shell/bash code blocks
      final hasDesktopCodeBlock =
        lowerBlock.contains('```bash') ||
        lowerBlock.contains('```sh') ||
        lowerBlock.contains('```cmd') ||
        lowerBlock.contains('```powershell') ||
        lowerBlock.contains('```shell');

      if (!hasDesktopTerm && !hasDesktopCodeBlock) {
        filteredBlocks.add(block);
      }
    }

    return filteredBlocks.join('\n\n').trim();
  }

  /// Render skills list to the markdown shape prompt templates expect.
  static String formatSkills(List<AgentSkill> skills) {
    if (skills.isEmpty) return '';
    final buf = StringBuffer()
      ..writeln('# Skills & Guidelines')
      ..writeln('This agent has the following mobile-compatible skills and custom guidelines active:')
      ..writeln();

    for (final skill in skills) {
      final filteredContent = filterMobileCompatibleSkills(skill.content);
      if (filteredContent.isNotEmpty) {
        buf.writeln('## Skill: ${skill.title}');
        buf.writeln(filteredContent);
        buf.writeln();
      }
    }
    return buf.toString().trim();
  }
}

/// A memory entry paired with its relevance score during recall selection.
class _ScoredEntry {
  const _ScoredEntry({required this.entry, required this.score});

  final AgentMemoryEntry entry;
  final int score;
}
