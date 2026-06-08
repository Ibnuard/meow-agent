class PeerAgentPath {
  const PeerAgentPath({
    required this.originalPath,
    required this.agentSegment,
    required this.suffix,
  });

  final String originalPath;
  final String agentSegment;
  final String suffix;
}

class TargetReferenceUtils {
  TargetReferenceUtils._();

  static PeerAgentPath? parsePeerAgentPath(String value) {
    var cleaned = value.trim().replaceAll('\\', '/');
    cleaned = _stripEdgeQuotes(cleaned);
    if (cleaned.startsWith('./')) cleaned = cleaned.substring(2);

    final match = RegExp(
      r'^agents/([^/]+)(/.*)?$',
      caseSensitive: false,
    ).firstMatch(cleaned);
    if (match == null) return null;

    final segment = match.group(1)?.trim() ?? '';
    if (segment.isEmpty) return null;
    return PeerAgentPath(
      originalPath: cleaned,
      agentSegment: segment,
      suffix: match.group(2) ?? '',
    );
  }

  static String canonicalPeerAgentPath(PeerAgentPath path, String agentName) {
    return 'Agents/${sanitizeWorkspaceName(agentName)}${path.suffix}';
  }

  static String sanitizeWorkspaceName(String name) {
    return name
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .trim();
  }

  static String displayNameFromWorkspaceSegment(String segment) {
    return segment.replaceAll('_', ' ').trim();
  }

  static bool messageMentionsExactAgent(String message, String agentName) {
    final haystack = normalizeForSearch(message);
    final display = normalizeForSearch(agentName);
    final sanitized = normalizeForSearch(sanitizeWorkspaceName(agentName));
    return containsSearchPhrase(haystack, display) ||
        containsSearchPhrase(haystack, sanitized);
  }

  /// Model-facing references for the active chat agent.
  ///
  /// These are English machine tokens used in prompts/tool schemas, not
  /// language-specific user utterance matching.
  static bool isCurrentAgentReference(String value) {
    final token = normalizeForSearch(value).replaceAll(' ', '_');
    return const {
      'current_agent',
      'active_agent',
      'this_agent',
      'calling_agent',
      'self',
      'current',
      'active',
    }.contains(token);
  }

  static bool containsSearchPhrase(String haystack, String phrase) {
    if (haystack.isEmpty || phrase.isEmpty) return false;
    return RegExp(
      '(^| )${RegExp.escape(phrase)}( |\$)',
      caseSensitive: false,
    ).hasMatch(haystack);
  }

  static String normalizeForSearch(String value) {
    return value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[_-]+'), ' ')
        .replaceAll(
          RegExp(r'[\u0000-\u002F\u003A-\u0040\u005B-\u0060\u007B-\u007F]+'),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String _stripEdgeQuotes(String value) {
    var out = value;
    while (out.length >= 2 &&
        ((out.startsWith('"') && out.endsWith('"')) ||
            (out.startsWith("'") && out.endsWith("'")))) {
      out = out.substring(1, out.length - 1).trim();
    }
    return out;
  }
}
