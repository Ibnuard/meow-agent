import '../workspace/workspace_paths.dart';
import 'runtime_models.dart';

/// Manages workspace folder access for agent runtime.
///
/// Phase 7 architecture: SOUL/MEMORY/SKILLS/HEARTBEAT data lives in
/// `meow_core.db` (tables: `agent_soul`, `agent_memory`, `agent_events`).
/// The workspace folder is for user-uploaded files only. This class retains
/// the public API surface expected by the runtime engine but all file-based
/// identity/memory operations are now no-ops — the engine reads context
/// from SQLite repositories directly.
class WorkspaceLoader {
  /// Load workspace context for a given agent.
  ///
  /// Returns an empty workspace. The runtime engine builds LLM context from
  /// the DB repos directly via `_buildWorkspace`.
  Future<AgentWorkspace> load(String agentName) async {
    return const AgentWorkspace(soul: '', memory: '', skills: '', heartbeat: '');
  }

  /// Legacy load by agentId — no longer reads from filesystem.
  Future<AgentWorkspace> loadById(String agentId, {String? agentName}) async {
    return const AgentWorkspace(soul: '', memory: '', skills: '', heartbeat: '');
  }

  /// No-op. Heartbeat data is recorded via `AgentEventRepository` in the
  /// runtime engine. This method is retained so existing call sites compile
  /// without changes; a follow-up can remove them incrementally.
  Future<void> updateHeartbeat(
    String agentName, {
    required String state,
    required String task,
    String? lastTool,
    String? lastResult,
    String? lastError,
  }) async {
    // No-op: heartbeat state lives in agent_events table.
  }

  /// Ensure the agent workspace directory exists.
  ///
  /// The directory is still created lazily so the `files.*` tools have a
  /// place to read/write user-requested files (e.g. when the user drops a
  /// PDF in there and asks the agent to read it). Best-effort — never throws.
  Future<void> ensureWorkspace(
    String agentName, {
    String languageCode = 'id',
  }) async {
    try {
      final dir = await WorkspacePaths.getAgentWorkspace(agentName);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    } catch (_) {
      // Non-fatal: the runtime works entirely from SQLite. The folder is
      // only needed if the user explicitly invokes a `files.*` tool.
    }
  }

  /// No-op. Preferred language is managed via `AgentSoulRepository.updateField`
  /// triggered by `system.profile.update`. The runtime auto-detects the user's
  /// language and writes it to the `agent_soul.preferred_language` column.
  Future<void> maybeFillPreferredLanguage(
    String agentName,
    String languageLabel,
  ) async {
    // No-op: canonical preferred-language lives in agent_soul table.
  }

  /// True if the user hasn't introduced themselves yet.
  ///
  /// Checks the formatted soul content (markdown-shaped string rendered from
  /// `AgentSoul`) for a missing or placeholder Name field. This drives the
  /// introduction gate in `AgentRuntimeEngine.run`.
  static bool isUserNameMissing(String soulContent) {
    if (soulContent.trim().isEmpty) return true;
    // Find the User Identity section.
    final sectionMatch = RegExp(
      r'##\s*User Identity[^\n]*\n([\s\S]*?)(?=\n##\s|---\s*\n|$)',
      caseSensitive: false,
    ).firstMatch(soulContent);
    if (sectionMatch == null) return true;
    final body = sectionMatch.group(1) ?? '';
    final nameMatch = RegExp(
      r'^Name:[ \t]*(.*?)[ \t]*$',
      multiLine: true,
    ).firstMatch(body);
    if (nameMatch == null) return true;
    final value = (nameMatch.group(1) ?? '').trim();
    if (value.isEmpty) return true;
    // Bracketed placeholder like [Your Name].
    if (RegExp(r'^\[.*\]$').hasMatch(value)) return true;
    return false;
  }
}
