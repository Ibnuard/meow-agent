/// A lightweight per-agent scratchpad that remembers recent tool calls and
/// their structured results across conversation turns.
///
/// Reviewer compresses tool data into natural replies (losing IDs and
/// structured fields), so without this memory the planner cannot reference
/// prior tool output (e.g. "delete that note", "open the one I just found").
class RuntimeMemory {
  /// Max tool results to keep per agent. Older entries are dropped FIFO.
  static const int maxEntries = 8;

  /// agentId → ordered list of tool result entries (oldest first).
  final Map<String, List<ToolMemoryEntry>> _byAgent = {};

  void record({
    required String agentId,
    required String toolName,
    required Map<String, dynamic> args,
    required Map<String, dynamic>? data,
    required bool success,
    String? error,
  }) {
    final list = _byAgent.putIfAbsent(agentId, () => []);
    list.add(
      ToolMemoryEntry(
        toolName: toolName,
        args: args,
        data: data,
        success: success,
        error: error,
        at: DateTime.now(),
      ),
    );
    if (list.length > maxEntries) {
      list.removeRange(0, list.length - maxEntries);
    }
  }

  List<ToolMemoryEntry> recent(String agentId) =>
      List.unmodifiable(_byAgent[agentId] ?? const []);

  void clear(String agentId) => _byAgent.remove(agentId);

  /// Remove failed entries for a tool after the same tool succeeds. This keeps
  /// mutable failures (module toggles/Android permissions) from poisoning future
  /// analyzer/selector prompts after the user fixes the permission.
  void purgeFailuresForTool(String agentId, String toolName) {
    final list = _byAgent[agentId];
    if (list == null || list.isEmpty) return;
    list.removeWhere((e) => e.toolName == toolName && !e.success);
    if (list.isEmpty) _byAgent.remove(agentId);
  }

  /// Build a compact string block describing recent tool results for prompts.
  /// Returns empty string if no entries.
  String formatForPrompt(String agentId) {
    final entries = _byAgent[agentId];
    if (entries == null || entries.isEmpty) return '';

    final buf = StringBuffer();
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      buf.writeln(
        '[${i + 1}] ${e.toolName} '
        '(${e.success ? 'success' : 'failed'}) '
        'args=${_compact(e.args)} '
        'result=${_compact(e.data)}'
        '${e.error != null ? ' error="${e.error}"' : ''}',
      );
    }
    return buf.toString().trim();
  }

  static String _compact(Object? value) {
    if (value == null) return 'null';
    final s = value.toString();
    if (s.length > 1200) return '${s.substring(0, 1200)}...';
    return s;
  }
}

/// One captured tool execution.
class ToolMemoryEntry {
  ToolMemoryEntry({
    required this.toolName,
    required this.args,
    required this.data,
    required this.success,
    required this.error,
    required this.at,
  });

  final String toolName;
  final Map<String, dynamic> args;
  final Map<String, dynamic>? data;
  final bool success;
  final String? error;
  final DateTime at;
}
