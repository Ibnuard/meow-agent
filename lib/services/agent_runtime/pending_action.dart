import 'dart:convert';

import '../../features/settings/data/llm_provider_config.dart';
import '../llm/openai_compatible_client.dart';
import 'json_utils.dart';

/// Decision for pending confirmation actions.
enum ConfirmationDecision { confirmed, rejected, previewOnly, unclear, none }

/// Represents a pending sensitive action awaiting user confirmation.
///
/// [userFacingSummary] is the human-readable confirmation message. Built once
/// by the runtime via the verbalizer and cached on this object so subsequent
/// turns can reuse it without re-asking the LLM.
///
/// [userFacingPreview] is the "what would happen" preview message, used when
/// the user asks to see the result before approving. Pre-verbalized at the
/// same time as the summary.
class PendingAction {
  PendingAction({
    required this.toolName,
    required this.toolArgs,
    required this.userFacingSummary,
    this.userFacingPreview = '',
    this.languageCode = 'en',
    this.resumeContext,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String toolName;
  final Map<String, dynamic> toolArgs;
  final String userFacingSummary;
  final String userFacingPreview;
  final String languageCode;
  final DateTime createdAt;

  /// Optional snapshot of runtime state captured when the confirmation gate
  /// fired in the middle of a multi-subgoal task. Lets [executeConfirmed]
  /// resume the execute loop after the confirmed tool runs, instead of
  /// short-circuiting to a single "done" reply.
  ///
  /// Shape (all JSON-serializable):
  ///   {
  ///     'plan': `Map`,                  // planner output
  ///     'goal_tree': `Map`,             // GoalTree.toJson()
  ///     'previous_results': `List<Map>`,// loop scratchpad
  ///     'current_step': int,          // 1-indexed
  ///     'available_tools': `List<String>`,
  ///     'memory_snapshot': String,
  ///     'auto_approve_sensitive': bool,
  ///     'is_workflow_auto_execute': bool,
  ///   }
  ///
  /// Null when the pending action does not need a resumable context
  /// (single-target tasks, legacy callers).
  final Map<String, dynamic>? resumeContext;

  Map<String, dynamic> toJson() => {
    'tool': toolName,
    'args': toolArgs,
    'summary': userFacingSummary,
    'preview': userFacingPreview,
    'lang': languageCode,
    'created_at': createdAt.toIso8601String(),
    if (resumeContext != null) 'resume': resumeContext,
  };

  factory PendingAction.fromJson(Map<String, dynamic> json) => PendingAction(
    toolName: json['tool'] as String,
    toolArgs: (json['args'] as Map<String, dynamic>?) ?? {},
    userFacingSummary: json['summary'] as String? ?? '',
    userFacingPreview: json['preview'] as String? ?? '',
    languageCode: json['lang'] as String? ?? 'en',
    resumeContext: (json['resume'] as Map<String, dynamic>?),
    createdAt: json['created_at'] != null
        ? DateTime.parse(json['created_at'] as String)
        : DateTime.now(),
  );

  /// Compact debug description used by the analyzer prompt only.
  ///
  /// Never shown to the user — the prompt receives this so the LLM can
  /// reason about a pending tool. The user-facing message is stored in
  /// [userFacingPreview].
  String get debugDescriptor =>
      'Pending action: $toolName with args: ${jsonEncode(toolArgs)}';
}

/// Deterministic pre-check for user responses to pending confirmations.
/// Avoids unnecessary LLM calls for clear accept/reject/preview patterns.
///
/// Tier-1: ID + EN whole-word keyword match (this class).
/// Tier-2: LLM classifier for non-ID/EN languages or [unclear] tier-1 results.
/// See [ConfirmationClassifier] below.
class ConfirmationChecker {
  static const _rejectKeywords = {
    // ID
    'tidak', 'ga', 'gak', 'nggak', 'enggak', 'jangan', 'batal', 'gausah',
    // EN
    'no', 'nope', 'cancel', 'stop', 'abort',
  };

  static const _rejectPhrases = {
    'ga usah',
    'gak usah',
    'tidak usah',
    'jangan dulu',
    "don't",
    'do not',
    'not now',
    'never mind',
    'nevermind',
  };

  static const _previewKeywords = {
    // ID single-word
    'cukup', 'tampilkan', 'tunjukkan', 'tunjukin',
    // EN + cross-lingual
    'preview', 'show',
  };

  static const _previewPhrases = {
    'kasih tau',
    'kasih tahu',
    'lihat dulu',
    'lihat hasilnya',
    'hasilnya seperti',
    'hasilnya kayak',
    'hasilnya gimana',
    'seperti apa',
    'kayak apa',
    'kaya apa',
    "what does it",
    'show me',
    'just show',
    'just preview',
  };

  static const _confirmKeywords = {
    // ID
    'ya', 'iya', 'yoi', 'yap', 'lanjut', 'gas',
    'lakukan', 'jalankan', 'eksekusi',
    'setuju', 'boleh', 'silakan', 'silahkan',
    // EN
    'yes', 'yeah', 'yep', 'sure', 'confirm', 'proceed', 'go',
    'ok', 'okay', 'do', 'execute',
  };

  static const _confirmPhrases = {
    'go ahead',
    'go for it',
    "let's go",
    'lets go',
    'do it',
  };

  /// Check user message against pending action.
  /// Returns the decision based on whole-word matching.
  static ConfirmationDecision check(String message) {
    final lower = message.toLowerCase().trim();
    if (lower.isEmpty) return ConfirmationDecision.unclear;

    final tokens = lower
        .split(RegExp(r"[^\w']+"))
        .where((t) => t.isNotEmpty)
        .toSet();

    // Phrases (multi-word) take precedence — substring is OK because they're
    // long enough to avoid false positives.
    bool matchesAnyPhrase(Set<String> phrases) {
      for (final p in phrases) {
        if (lower.contains(p)) return true;
      }
      return false;
    }

    bool matchesAnyToken(Set<String> kws) {
      for (final kw in kws) {
        if (tokens.contains(kw)) return true;
      }
      return false;
    }

    if (matchesAnyPhrase(_previewPhrases) ||
        matchesAnyToken(_previewKeywords)) {
      return ConfirmationDecision.previewOnly;
    }
    if (matchesAnyPhrase(_rejectPhrases) || matchesAnyToken(_rejectKeywords)) {
      return ConfirmationDecision.rejected;
    }
    if (matchesAnyPhrase(_confirmPhrases) ||
        matchesAnyToken(_confirmKeywords)) {
      return ConfirmationDecision.confirmed;
    }
    return ConfirmationDecision.unclear;
  }
}

/// Tier-2 LLM classifier for confirmation responses.
///
/// Used when:
///   - [ConfirmationChecker.check] returns [ConfirmationDecision.unclear], or
///   - the detected user language is not ID/EN (the keyword maps don't cover
///     other languages).
///
/// One tiny LLM call per ambiguous response. Failure → returns [unclear] so
/// the engine falls through to its standard analysis path.
class ConfirmationClassifier {
  ConfirmationClassifier({required this.client, required this.config});

  final OpenAiCompatibleClient client;
  final LlmProviderConfig config;

  Future<ConfirmationDecision> classify({
    required String userMessage,
    required String pendingSummary,
    required String languageCode,
  }) async {
    if (userMessage.trim().isEmpty) return ConfirmationDecision.unclear;

    final prompt =
        '''The user previously saw this confirmation prompt (in their language):

"$pendingSummary"

The user just replied:

"$userMessage"

Classify the reply into ONE of these intents:
- confirmed     → user agrees to proceed
- rejected      → user declines or asks to cancel
- preview_only  → user wants to see the result without executing
- unclear       → cannot tell

User language: $languageCode

Respond with ONLY a JSON object: {"decision":"confirmed|rejected|preview_only|unclear"}''';

    try {
      final response = await client.chat(
        config: config,
        phase: 'verbalize.classify_confirmation',
        messages: [
          {
            'role': 'system',
            'content': 'You are a JSON-only responder. Never use markdown.',
          },
          {'role': 'user', 'content': prompt},
        ],
      );
      final parsed = JsonUtils.tryParseObject(response);
      final decision = parsed?['decision'] as String?;
      switch (decision) {
        case 'confirmed':
          return ConfirmationDecision.confirmed;
        case 'rejected':
          return ConfirmationDecision.rejected;
        case 'preview_only':
          return ConfirmationDecision.previewOnly;
        default:
          return ConfirmationDecision.unclear;
      }
    } catch (_) {
      return ConfirmationDecision.unclear;
    }
  }
}
