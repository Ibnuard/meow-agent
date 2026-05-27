import 'dart:convert';

import '../../features/settings/data/llm_provider_config.dart';
import '../llm/openai_compatible_client.dart';
import 'i18n_fallback.dart';
import 'language_detector.dart';
import 'runtime_models.dart';

/// Generic, LLM-backed user-facing string generator.
///
/// Replaces all hardcoded per-tool switch statements that previously lived
/// inside the runtime engine (`_localFinalResponseFor`, `_humanizeConfirmation`,
/// `previewText`, hardcoded cancel string, etc.).
///
/// One LLM call per phase. Internal prompts are English (model-stable);
/// output is always in the user's [DetectedLanguage].
///
/// Caching: per-turn only. Call [resetTurn] at the start of every
/// `engine.run()` invocation. Multi-turn caching is intentionally deferred.
class ToolVerbalizer {
  ToolVerbalizer({
    required this.client,
    required this.config,
  });

  final OpenAiCompatibleClient client;
  final LlmProviderConfig config;

  final Map<String, String> _turnCache = {};

  /// Clear the per-turn cache. MUST be called at the start of every run.
  void resetTurn() => _turnCache.clear();

  // ───────────────────────────────────────────────────────────────────────────
  // Public phases
  // ───────────────────────────────────────────────────────────────────────────

  /// Confirmation message shown before executing a sensitive tool.
  ///
  /// Includes [impacts] (cross-entity side effects discovered by the
  /// reflection phase) and [done] (auto-resolve prep steps already executed
  /// before this confirmation). Both are empty lists during Phase 1.
  Future<String> confirm({
    required ToolCallRequest tool,
    required ToolDefinition definition,
    required DetectedLanguage language,
    List<Map<String, dynamic>> impacts = const [],
    List<Map<String, dynamic>> done = const [],
  }) async {
    final cacheKey = _key(
      'confirm',
      tool.name,
      tool.args,
      language.code,
      extra: {'impacts': impacts, 'done': done},
    );
    final cached = _turnCache[cacheKey];
    if (cached != null) return cached;

    final impactsBlock = impacts.isEmpty
        ? ''
        : '\n\nKnown side effects of this action:\n'
              '${impacts.map((i) => '- ${jsonEncode(i)}').join('\n')}';
    final doneBlock = done.isEmpty
        ? ''
        : '\n\nAlready completed automatically before this confirmation:\n'
              '${done.map((d) => '- ${jsonEncode(d)}').join('\n')}';

    final prompt = '''You write ONE short sentence asking the user to confirm an action.

Action: ${tool.name}
Action description: ${definition.description}
Arguments: ${jsonEncode(tool.args)}$impactsBlock$doneBlock

Rules:
- Reply in ${language.label} (${language.code}). Match this language exactly.
- Speak naturally as a helpful assistant. Never expose internal tool names like "${tool.name}" or any IDs.
- 1–2 short sentences. End with a clear "Proceed?" / "Lanjut?" question (translated).
- If side effects are listed, briefly mention the most important one in human terms.
- If something was already done automatically, briefly acknowledge it before asking.

Reply with the message only. No JSON, no quotes, no markdown.''';

    return _callOrFallback(
      prompt: prompt,
      phase: 'verbalize.confirm',
      languageCode: language.code,
      fallbackPhase: 'confirm',
      cacheKey: cacheKey,
    );
  }

  /// Success message after a tool executes successfully.
  Future<String> success({
    required ToolCallRequest tool,
    required ToolExecutionResult result,
    required DetectedLanguage language,
  }) async {
    final cacheKey = _key(
      'success',
      tool.name,
      tool.args,
      language.code,
      extra: {'success': result.success, 'data': _shrinkData(result.data)},
    );
    final cached = _turnCache[cacheKey];
    if (cached != null) return cached;

    final dataBlock = result.data == null
        ? ''
        : '\nResult data (for context only): ${jsonEncode(_shrinkData(result.data))}';

    final prompt = '''You write ONE natural confirmation that an action just completed.

Action: ${tool.name}
Arguments: ${jsonEncode(tool.args)}$dataBlock

Rules:
- Reply in ${language.label} (${language.code}). Match this language exactly.
- Speak naturally. Never expose internal tool names or IDs (e.g. "${tool.name}", "note_xxx", "agent_xxx").
- 1–2 short sentences confirming what was done in human terms.
- Do NOT promise additional steps. Only confirm what already happened.

Reply with the message only. No JSON, no quotes, no markdown.''';

    return _callOrFallback(
      prompt: prompt,
      phase: 'verbalize.success',
      languageCode: language.code,
      fallbackPhase: 'success',
      cacheKey: cacheKey,
    );
  }

  /// Message shown when the user rejects a pending action.
  Future<String> cancel({
    required ToolCallRequest tool,
    required DetectedLanguage language,
  }) async {
    final cacheKey = _key('cancel', tool.name, const {}, language.code);
    final cached = _turnCache[cacheKey];
    if (cached != null) return cached;

    final prompt = '''You write ONE short message acknowledging that the user cancelled the action.

Action that was cancelled: ${tool.name}

Rules:
- Reply in ${language.label} (${language.code}). Match this language exactly.
- 1 short sentence. Friendly, never blaming the user.
- Never expose the internal action name above.

Reply with the message only. No JSON, no quotes, no markdown.''';

    return _callOrFallback(
      prompt: prompt,
      phase: 'verbalize.cancel',
      languageCode: language.code,
      fallbackPhase: 'cancel',
      cacheKey: cacheKey,
    );
  }

  /// Preview message — show what would happen without actually executing.
  Future<String> preview({
    required ToolCallRequest tool,
    required DetectedLanguage language,
  }) async {
    final cacheKey = _key('preview', tool.name, tool.args, language.code);
    final cached = _turnCache[cacheKey];
    if (cached != null) return cached;

    final prompt = '''You write ONE short preview of what an action WOULD do, without actually doing it.

Action: ${tool.name}
Arguments: ${jsonEncode(tool.args)}

Rules:
- Reply in ${language.label} (${language.code}). Match this language exactly.
- 1–2 short sentences describing the expected outcome in human terms.
- Make it clear this is a preview, not the executed result.
- Never expose internal tool names or IDs.

Reply with the message only. No JSON, no quotes, no markdown.''';

    return _callOrFallback(
      prompt: prompt,
      phase: 'verbalize.preview',
      languageCode: language.code,
      fallbackPhase: 'preview',
      cacheKey: cacheKey,
    );
  }

  /// Abort message — runtime gave up (e.g. stuck loop, max steps, hard error).
  Future<String> abort({
    required String reason,
    required DetectedLanguage language,
    Map<String, dynamic>? goalState,
  }) async {
    final cacheKey = _key(
      'abort',
      'runtime',
      const {},
      language.code,
      extra: {'reason': reason, 'goal': goalState ?? const {}},
    );
    final cached = _turnCache[cacheKey];
    if (cached != null) return cached;

    final goalBlock = goalState == null || goalState.isEmpty
        ? ''
        : '\nProgress at the time of abort: ${jsonEncode(goalState)}';

    final prompt = '''You write ONE short message explaining that the agent is stopping a multi-step task it cannot finish.

Reason (internal): $reason$goalBlock

Rules:
- Reply in ${language.label} (${language.code}). Match this language exactly.
- 1–2 short sentences. Honest, calm, never blaming the user.
- If progress information was given, briefly mention what was completed before stopping.
- Suggest the user try rephrasing or breaking the request down.
- Never expose internal tool names, error codes, or stack traces.

Reply with the message only. No JSON, no quotes, no markdown.''';

    return _callOrFallback(
      prompt: prompt,
      phase: 'verbalize.abort',
      languageCode: language.code,
      fallbackPhase: 'abort',
      cacheKey: cacheKey,
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Internals
  // ───────────────────────────────────────────────────────────────────────────

  Future<String> _callOrFallback({
    required String prompt,
    required String phase,
    required String languageCode,
    required String fallbackPhase,
    required String cacheKey,
  }) async {
    try {
      final out = await client.chat(
        config: config,
        phase: phase,
        messages: [
          {
            'role': 'system',
            'content':
                'You are a concise message writer. Reply with plain text only — no JSON, no markdown, no quotes.',
          },
          {'role': 'user', 'content': prompt},
        ],
      );
      final cleaned = _cleanOutput(out);
      if (cleaned.isEmpty) {
        return _fallback(fallbackPhase, languageCode, cacheKey);
      }
      _turnCache[cacheKey] = cleaned;
      return cleaned;
    } catch (_) {
      return _fallback(fallbackPhase, languageCode, cacheKey);
    }
  }

  String _fallback(String phase, String languageCode, String cacheKey) {
    final s = I18nFallback.get(phase, languageCode);
    _turnCache[cacheKey] = s;
    return s;
  }

  /// Strip leading/trailing quotes, code fences, and surrounding whitespace.
  static String _cleanOutput(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return s;
    if (s.startsWith('```')) {
      s = s.replaceFirst(RegExp(r'^```[a-zA-Z]*\n?'), '');
      final close = s.lastIndexOf('```');
      if (close >= 0) s = s.substring(0, close);
      s = s.trim();
    }
    if (s.length >= 2) {
      final first = s.codeUnitAt(0);
      final last = s.codeUnitAt(s.length - 1);
      // 0x22="  0x27='  0x60=`
      if ((first == 0x22 && last == 0x22) ||
          (first == 0x27 && last == 0x27) ||
          (first == 0x60 && last == 0x60)) {
        s = s.substring(1, s.length - 1).trim();
      }
    }
    return s;
  }

  /// Build a cache key. Args are JSON-encoded with sorted keys for stability.
  static String _key(
    String phase,
    String toolName,
    Map<String, dynamic> args,
    String langCode, {
    Map<String, dynamic>? extra,
  }) {
    final argsKey = _stableJson(args);
    final extraKey = extra == null || extra.isEmpty ? '' : _stableJson(extra);
    return '$phase|$toolName|$langCode|$argsKey|$extraKey';
  }

  static String _stableJson(Map<String, dynamic> m) {
    final keys = m.keys.toList()..sort();
    final ordered = <String, dynamic>{for (final k in keys) k: m[k]};
    return jsonEncode(ordered);
  }

  /// Drop oversized blobs (e.g. file contents) from result data so the
  /// verbalizer prompt stays under reasonable token budget.
  static Map<String, dynamic>? _shrinkData(Map<String, dynamic>? data) {
    if (data == null) return null;
    final out = <String, dynamic>{};
    data.forEach((k, v) {
      if (v is String && v.length > 240) {
        out[k] = '${v.substring(0, 240)}…';
      } else if (v is List && v.length > 8) {
        out[k] = [...v.take(8), '…(+${v.length - 8} more)'];
      } else {
        out[k] = v;
      }
    });
    return out;
  }
}
