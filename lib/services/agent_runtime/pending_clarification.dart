/// Pending clarification state for multi-turn disambiguation.
///
/// When the runtime asks the user for missing information, the next user reply
/// should not be treated as a standalone request. This model stores the
/// original request + questions so the follow-up can be deterministically
/// rewritten into a merged request before analysis.
class PendingClarification {
  const PendingClarification({
    required this.originalMessage,
    required this.questions,
    required this.createdAt,
  });

  final String originalMessage;
  final List<String> questions;
  final DateTime createdAt;

  bool get isExpired => DateTime.now().difference(createdAt).inMinutes > 30;

  String mergedWith(String answer) {
    final questionBlock = questions.map((q) => '- $q').join('\n');
    return '''Original user request:
$originalMessage

Assistant asked these clarifying questions:
$questionBlock

User answered:
$answer

Interpretation instruction:
Treat the user's answer as clarification for the original request. Merge all answered details into the original request. Only ask for details that remain truly missing.''';
  }
}
