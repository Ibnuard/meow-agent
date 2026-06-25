/// Per-turn language detection for the runtime.
///
/// Drives every user-facing string in the runtime via [ToolVerbalizer].
/// This is a fast, heuristic BOOTSTRAP only:
///   1. Unicode script detection (Han/Hiragana/Hangul/Cyrillic/Arabic/Thai/Devanagari/Hebrew)
///      → high-confidence language mapping, available instantly before any LLM call.
///   2. For Latin script: heuristic word-probing across the many Latin
///      languages is unreliable and privileges whichever languages have a
///      hardcoded word list, so we DO NOT guess here. We return the caller's
///      [fallbackCode] from the runtime language-priority chain as a provisional,
///      low-confidence value.
///
/// The AUTHORITATIVE per-turn language comes from the analyzer LLM, which
/// natively knows the user's language. The engine refines [DetectedLanguage]
/// from the analyzer's `detected_language` field after analysis (see
/// [DetectedLanguage.fromAnalyzerCode]). This file stays language-agnostic: no
/// per-language word lists, no Indonesian special casing.
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

  /// Build an authoritative [DetectedLanguage] from an ISO code the analyzer
  /// reported. Used by the engine to override the heuristic bootstrap once the
  /// analyzer has classified the turn's language. Unknown codes keep the
  /// provided [code] with an English label fallback.
  factory DetectedLanguage.fromAnalyzerCode(String code) {
    final normalized = code.trim().toLowerCase();
    return DetectedLanguage(
      code: normalized,
      label: LanguageDetector.labelForCode(normalized),
      script: 'Latin',
      confidence: 0.9,
    );
  }
}

class LanguageDetector {
  LanguageDetector();

  final Map<int, DetectedLanguage> _cache = {};

  void clearCache() => _cache.clear();

  /// Detect the language of [userMessage].
  ///
  /// [fallbackCode] is used for Latin-script text and when detection is
  /// ambiguous. The runtime owns the fallback priority chain.
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

    // Latin script: do NOT guess between Latin languages here. Word-probe
    // heuristics privilege whichever languages have a hardcoded list and
    // mis-detect the rest. Return the caller's fallback as a low-confidence
    // provisional value; the analyzer's `detected_language` refines it
    // authoritatively for this turn.
    return _fallback(fallbackCode);
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
        code: 'ja',
        label: 'Japanese',
        script: 'Japanese',
        confidence: 0.9,
      ),
      'Hangul' => const DetectedLanguage(
        code: 'ko',
        label: 'Korean',
        script: 'Hangul',
        confidence: 0.95,
      ),
      'Han' => const DetectedLanguage(
        code: 'zh',
        label: 'Chinese',
        script: 'Han',
        confidence: 0.85,
      ),
      'Cyrillic' => const DetectedLanguage(
        code: 'ru',
        label: 'Russian',
        script: 'Cyrillic',
        confidence: 0.8,
      ),
      'Arabic' => const DetectedLanguage(
        code: 'ar',
        label: 'Arabic',
        script: 'Arabic',
        confidence: 0.9,
      ),
      'Thai' => const DetectedLanguage(
        code: 'th',
        label: 'Thai',
        script: 'Thai',
        confidence: 0.95,
      ),
      'Devanagari' => const DetectedLanguage(
        code: 'hi',
        label: 'Hindi',
        script: 'Devanagari',
        confidence: 0.8,
      ),
      'Hebrew' => const DetectedLanguage(
        code: 'he',
        label: 'Hebrew',
        script: 'Hebrew',
        confidence: 0.95,
      ),
      _ => const DetectedLanguage(
        code: 'en',
        label: 'English',
        script: 'Latin',
        confidence: 0.3,
      ),
    };
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
}
