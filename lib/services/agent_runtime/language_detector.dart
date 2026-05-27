/// Per-turn language detection for the runtime.
///
/// Drives every user-facing string in the runtime via [ToolVerbalizer].
/// Detection is heuristic-only (no LLM call) to keep this phase fast:
///   1. Unicode script detection (Han/Hiragana/Hangul/Cyrillic/Arabic/Thai/Devanagari/Hebrew).
///   2. For Latin script: ID vs EN word probe.
///   3. Fallback to caller-provided code when ambiguous (typically the user's app setting).
///
/// Cache is per-instance, keyed by message hash. Cleared when the engine resets.
class DetectedLanguage {
  const DetectedLanguage({
    required this.code,
    required this.label,
    required this.script,
    required this.confidence,
  });

  /// ISO 639-1 code: 'id', 'en', 'ja', 'ko', 'zh', 'es', 'fr', ...
  final String code;

  /// Human-readable label used in LLM prompts (e.g. "Indonesian").
  final String label;

  /// Detected script family ('Latin', 'Han', 'Japanese', 'Hangul', ...).
  final String script;

  /// 0.0–1.0. Heuristic confidence.
  final double confidence;

  bool get isHighConfidence => confidence >= 0.7;
}

class LanguageDetector {
  LanguageDetector();

  final Map<int, DetectedLanguage> _cache = {};

  void clearCache() => _cache.clear();

  /// Detect the language of [userMessage].
  ///
  /// [fallbackCode] is used when detection is ambiguous (typically
  /// the user's app language setting).
  DetectedLanguage detect({
    required String userMessage,
    required String fallbackCode,
  }) {
    if (userMessage.trim().isEmpty) {
      return _fallback(fallbackCode);
    }

    final key = userMessage.hashCode;
    final cached = _cache[key];
    if (cached != null) return cached;

    final result = _detectImpl(userMessage, fallbackCode);
    _cache[key] = result;
    return result;
  }

  DetectedLanguage _detectImpl(String text, String fallbackCode) {
    final script = _detectScript(text);

    // Non-Latin scripts → high-confidence script-based mapping.
    if (script != 'Latin') {
      return _scriptToLanguage(script);
    }

    // Latin: ID vs EN word probe.
    return _latinProbe(text, fallbackCode);
  }

  /// Walks runes once, picks the dominant non-Latin script if present.
  String _detectScript(String text) {
    var hanCount = 0;
    var hiraganaCount = 0;
    var katakanaCount = 0;
    var hangulCount = 0;
    var cyrillicCount = 0;
    var arabicCount = 0;
    var thaiCount = 0;
    var devanagariCount = 0;
    var hebrewCount = 0;

    for (final rune in text.runes) {
      if ((rune >= 0x4E00 && rune <= 0x9FFF) ||
          (rune >= 0x3400 && rune <= 0x4DBF)) {
        hanCount++;
      } else if (rune >= 0x3040 && rune <= 0x309F) {
        hiraganaCount++;
      } else if (rune >= 0x30A0 && rune <= 0x30FF) {
        katakanaCount++;
      } else if (rune >= 0xAC00 && rune <= 0xD7AF) {
        hangulCount++;
      } else if (rune >= 0x0400 && rune <= 0x04FF) {
        cyrillicCount++;
      } else if (rune >= 0x0600 && rune <= 0x06FF) {
        arabicCount++;
      } else if (rune >= 0x0E00 && rune <= 0x0E7F) {
        thaiCount++;
      } else if (rune >= 0x0900 && rune <= 0x097F) {
        devanagariCount++;
      } else if (rune >= 0x0590 && rune <= 0x05FF) {
        hebrewCount++;
      }
    }

    // Order matters: Japanese (kana) takes precedence over bare Han because
    // a JP message commonly contains a few kanji + a lot of kana. Bare Han
    // without kana → Chinese.
    if (hiraganaCount + katakanaCount > 0) return 'Japanese';
    if (hangulCount > 0) return 'Hangul';
    if (cyrillicCount > 0) return 'Cyrillic';
    if (arabicCount > 0) return 'Arabic';
    if (thaiCount > 0) return 'Thai';
    if (devanagariCount > 0) return 'Devanagari';
    if (hebrewCount > 0) return 'Hebrew';
    if (hanCount > 0) return 'Han';
    return 'Latin';
  }

  DetectedLanguage _scriptToLanguage(String script) {
    return switch (script) {
      'Japanese' => const DetectedLanguage(
          code: 'ja', label: 'Japanese', script: 'Japanese', confidence: 0.9),
      'Hangul' => const DetectedLanguage(
          code: 'ko', label: 'Korean', script: 'Hangul', confidence: 0.95),
      'Han' => const DetectedLanguage(
          code: 'zh', label: 'Chinese', script: 'Han', confidence: 0.85),
      'Cyrillic' => const DetectedLanguage(
          code: 'ru', label: 'Russian', script: 'Cyrillic', confidence: 0.8),
      'Arabic' => const DetectedLanguage(
          code: 'ar', label: 'Arabic', script: 'Arabic', confidence: 0.9),
      'Thai' => const DetectedLanguage(
          code: 'th', label: 'Thai', script: 'Thai', confidence: 0.95),
      'Devanagari' => const DetectedLanguage(
          code: 'hi', label: 'Hindi', script: 'Devanagari', confidence: 0.8),
      'Hebrew' => const DetectedLanguage(
          code: 'he', label: 'Hebrew', script: 'Hebrew', confidence: 0.95),
      _ => const DetectedLanguage(
          code: 'en', label: 'English', script: 'Latin', confidence: 0.3),
    };
  }

  /// Latin script: count language-specific markers.
  /// Tie or zero hits → caller's fallback.
  DetectedLanguage _latinProbe(String text, String fallbackCode) {
    final lower = text.toLowerCase();
    final tokens = lower
        .split(RegExp(r'[^\w\u00C0-\u024F]+'))
        .where((t) => t.isNotEmpty)
        .toSet();

    var idScore = 0;
    var enScore = 0;
    for (final w in _idMarkers) {
      if (tokens.contains(w)) idScore++;
    }
    for (final w in _enMarkers) {
      if (tokens.contains(w)) enScore++;
    }

    // Phrase markers (multi-word).
    for (final p in _idPhrases) {
      if (lower.contains(p)) idScore++;
    }
    for (final p in _enPhrases) {
      if (lower.contains(p)) enScore++;
    }

    if (idScore == 0 && enScore == 0) {
      return _fallback(fallbackCode);
    }
    if (idScore == enScore) {
      return _fallback(fallbackCode);
    }

    final winner = idScore > enScore ? 'id' : 'en';
    final winnerScore = idScore > enScore ? idScore : enScore;
    final total = idScore + enScore;
    final conf = (winnerScore / total).clamp(0.55, 0.95).toDouble();

    return DetectedLanguage(
      code: winner,
      label: winner == 'id' ? 'Indonesian' : 'English',
      script: 'Latin',
      confidence: conf,
    );
  }

  DetectedLanguage _fallback(String code) {
    return DetectedLanguage(
      code: code,
      label: labelForCode(code),
      script: 'Latin',
      confidence: 0.4,
    );
  }

  /// Best-effort label for an ISO code. Defaults to English.
  static String labelForCode(String code) => switch (code) {
        'id' => 'Indonesian',
        'en' => 'English',
        'ja' => 'Japanese',
        'ko' => 'Korean',
        'zh' => 'Chinese',
        'es' => 'Spanish',
        'fr' => 'French',
        'de' => 'German',
        'pt' => 'Portuguese',
        'it' => 'Italian',
        'ru' => 'Russian',
        'ar' => 'Arabic',
        'hi' => 'Hindi',
        'vi' => 'Vietnamese',
        'th' => 'Thai',
        'tr' => 'Turkish',
        'ms' => 'Malay',
        'he' => 'Hebrew',
        _ => 'English',
      };

  // Indonesian function-word and pronoun markers — high specificity.
  static const _idMarkers = {
    'saya', 'aku', 'kamu', 'gue', 'gw', 'gua', 'lo', 'lu',
    'yang', 'ini', 'itu',
    'tidak', 'ga', 'gak', 'nggak', 'enggak', 'belum', 'sudah', 'udah',
    'buat', 'dengan', 'untuk', 'akan', 'sama',
    'atau', 'tapi', 'kalau', 'kalo',
    'bisa', 'mau', 'pakai', 'pake',
    'apa', 'kenapa', 'bagaimana', 'gimana', 'dimana', 'kapan',
    'tolong', 'mohon', 'minta',
    'banget', 'aja', 'dong', 'sih', 'kok', 'deh', 'nih',
    'ada', 'jangan', 'jadi', 'juga', 'lagi', 'cuma', 'hanya',
    'bikin', 'bikinin', 'tuh', 'yaa', 'yaaa',
    'agen', 'modul',
  };

  static const _enMarkers = {
    'the', 'is', 'are', 'was', 'were', 'be', 'been', 'being',
    'have', 'has', 'had', 'do', 'does', 'did',
    'will', 'would', 'could', 'should', 'might', 'must', 'shall',
    'this', 'that', 'these', 'those',
    'you', 'your', 'yours', 'me', 'my', 'mine',
    'we', 'our', 'us', 'they', 'their', 'them',
    'and', 'but', 'because', 'if', 'when',
    'what', 'why', 'how', 'where',
    'please', 'thanks', 'thank',
    'with', 'from', 'about', 'into', 'onto',
    'something', 'someone', 'anything', 'everything',
    'agent', 'module',
  };

  static const _idPhrases = {
    'saya mau', 'saya ingin', 'aku mau', 'gue mau',
    'tolong buatkan', 'tolong buat', 'tolong bantu',
    'apakah kamu', 'kamu bisa',
    'jangan lupa', 'jadwalkan',
  };

  static const _enPhrases = {
    "i'd like", "i want", 'i need',
    'can you', 'could you', 'would you',
    'please help', 'help me', 'tell me', 'show me',
    "don't", "doesn't", "won't", "can't", "i'm",
  };
}
