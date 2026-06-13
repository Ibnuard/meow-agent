import '../../core/storage/agent_memory_repository.dart';
import '../../core/storage/agent_soul_repository.dart';
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
  WorkspaceContextBuilder({this.soulRepo, this.memoryRepo});

  final AgentSoulRepository? soulRepo;
  final AgentMemoryRepository? memoryRepo;

  /// Build an [AgentWorkspace] from SQLite. Falls back to empty when repos
  /// aren't injected (e.g. in tests using a default-constructed engine).
  Future<AgentWorkspace> build(String agentName, String agentId) async {
    if (soulRepo == null && memoryRepo == null) {
      return const AgentWorkspace(
        soul: '',
        memory: '',
        skills: '',
        heartbeat: '',
      );
    }

    final soulFuture = soulRepo?.get(agentId);
    final memoryFuture = memoryRepo?.recent(agentId, limit: 30);

    final soul = soulFuture == null ? null : await soulFuture;
    final memoryEntries = memoryFuture == null
        ? const <AgentMemoryEntry>[]
        : await memoryFuture;

    return AgentWorkspace(
      soul: formatSoul(agentName, soul),
      memory: formatMemory(memoryEntries),
      skills: '',
      heartbeat: '',
    );
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
}
