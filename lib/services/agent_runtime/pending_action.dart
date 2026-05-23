import 'dart:convert';

/// Decision for pending confirmation actions.
enum ConfirmationDecision {
  confirmed,
  rejected,
  previewOnly,
  unclear,
  none,
}

/// Represents a pending sensitive action awaiting user confirmation.
class PendingAction {
  PendingAction({
    required this.toolName,
    required this.toolArgs,
    required this.userFacingSummary,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String toolName;
  final Map<String, dynamic> toolArgs;
  final String userFacingSummary;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
        'tool': toolName,
        'args': toolArgs,
        'summary': userFacingSummary,
        'created_at': createdAt.toIso8601String(),
      };

  factory PendingAction.fromJson(Map<String, dynamic> json) => PendingAction(
        toolName: json['tool'] as String,
        toolArgs: (json['args'] as Map<String, dynamic>?) ?? {},
        userFacingSummary: json['summary'] as String? ?? '',
        createdAt: json['created_at'] != null
            ? DateTime.parse(json['created_at'] as String)
            : DateTime.now(),
      );

  /// Preview string for the pending action result.
  String get previewText {
    if (toolName == 'clipboard.write') {
      final text = toolArgs['text'] as String? ?? '';
      return 'Hasilnya akan menjadi: "$text"';
    }
    return 'Pending action: $toolName with args: ${jsonEncode(toolArgs)}';
  }
}

/// Deterministic pre-check for user responses to pending confirmations.
/// Avoids unnecessary LLM calls for clear accept/reject/preview patterns.
class ConfirmationChecker {
  static const _rejectKeywords = [
    'tidak',
    'ga ',
    'gak',
    'nggak',
    'jangan',
    'batal',
    'cancel',
    'no',
    'nope',
    'ga usah',
    'gausah',
    'gaperlu',
  ];

  static const _previewKeywords = [
    'cukup',
    'kasih tau',
    'kasih tahu',
    'hasilnya',
    'preview',
    'lihat dulu',
    'seperti apa',
    'kayak apa',
    'kaya apa',
    'tampilkan',
    'tunjukkan',
    'tunjukin',
    'show',
  ];

  static const _confirmKeywords = [
    'ya',
    'iya',
    'yap',
    'yep',
    'yes',
    'oke',
    'ok',
    'lanjut',
    'gas',
    'confirm',
    'lakukan',
    'jalankan',
    'eksekusi',
    'setuju',
    'boleh',
    'silakan',
    'proceed',
    'go',
  ];

  /// Check user message against pending action.
  /// Returns the decision based on keyword matching.
  static ConfirmationDecision check(String message) {
    final lower = message.toLowerCase().trim();

    // Check preview first (takes priority over reject).
    for (final kw in _previewKeywords) {
      if (lower.contains(kw)) return ConfirmationDecision.previewOnly;
    }

    // Check rejection.
    for (final kw in _rejectKeywords) {
      if (lower.contains(kw)) return ConfirmationDecision.rejected;
    }

    // Check confirmation.
    for (final kw in _confirmKeywords) {
      // For short keywords, match as whole word or at start.
      if (kw.length <= 3) {
        if (lower == kw || lower.startsWith('$kw ') || lower.startsWith('$kw,')) {
          return ConfirmationDecision.confirmed;
        }
      } else if (lower.contains(kw)) {
        return ConfirmationDecision.confirmed;
      }
    }

    return ConfirmationDecision.unclear;
  }
}
