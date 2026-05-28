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

  /// Answer the user's request using data returned by a retrieval/read tool.
  ///
  /// This is deliberately different from [success]: the task is not "the tool
  /// ran", it is "use the retrieved information to answer the user".
  Future<String> answerFromToolResult({
    required String userMessage,
    required ToolCallRequest tool,
    required ToolExecutionResult result,
    required DetectedLanguage language,
  }) async {
    final cacheKey = _key(
      'answer_from_tool_result',
      tool.name,
      tool.args,
      language.code,
      extra: {
        'user_message': userMessage,
        'success': result.success,
        'data': _answerData(result.data),
      },
    );
    final cached = _turnCache[cacheKey];
    if (cached != null) return cached;

    final prompt = '''You answer the user's request using ONLY the tool result data.

User request:
$userMessage

Tool action:
${tool.name}

Tool arguments:
${jsonEncode(tool.args)}

Tool result data:
${jsonEncode(_answerData(result.data))}

Rules:
- Reply in ${language.label} (${language.code}). Match this language exactly.
- Answer the user's actual question, not merely that the tool succeeded.
- Never expose internal tool names or raw IDs.
- If the data is a file/content blob, extract the relevant answer and summarize it naturally.
- If the data does not contain enough information, say what is missing briefly.
- Keep it concise but useful. No markdown unless the user clearly asked for structured output.

Reply with the answer only. No JSON, no quotes.''';

    return _callOrFallback(
      prompt: prompt,
      phase: 'verbalize.answer_from_tool_result',
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

  /// Final summary for a multi-subgoal task.
  ///
  /// Replaces the per-tool [success] call when more than one subgoal was
  /// completed, so the user sees a holistic recap instead of "the last tool
  /// finished" only. The model receives the full completed-subgoal list (with
  /// status + short notes) and produces 1-3 short sentences in the user's
  /// language.
  ///
  /// [completedSubgoals] entries should be `{label, status, notes?, resultRef?}`.
  /// [mainGoal] is the user's overall goal (one sentence).
  Future<String> taskSummary({
    required String mainGoal,
    required List<Map<String, dynamic>> completedSubgoals,
    required DetectedLanguage language,
  }) async {
    final cacheKey = _key(
      'task_summary',
      'multi',
      const {},
      language.code,
      extra: {
        'main_goal': mainGoal,
        'subgoals': completedSubgoals,
      },
    );
    final cached = _turnCache[cacheKey];
    if (cached != null) return cached;

    final subgoalsBlock = completedSubgoals
        .map((s) => '- [${s['status'] ?? 'done'}] ${s['label'] ?? ''}'
            '${(s['notes'] ?? '').toString().isEmpty ? '' : ' (${s['notes']})'}')
        .join('\n');

    final prompt = '''You write ONE natural recap of a multi-step task that just finished.

Overall goal: $mainGoal

Subgoals completed:
$subgoalsBlock

Rules:
- Reply in ${language.label} (${language.code}). Match this language exactly.
- 1–3 short sentences. Cover EVERY subgoal in human terms — never single one out and ignore the rest.
- Speak naturally as a helpful assistant who just finished the work. No bullet lists. No checkmarks.
- Never expose internal tool names, IDs, or status codes (e.g. "system.agents.delete", "agent_xxx", "[done]").
- If any subgoal was skipped or failed, briefly acknowledge that too.

Reply with the message only. No JSON, no quotes, no markdown.''';

    return _callOrFallback(
      prompt: prompt,
      phase: 'verbalize.task_summary',
      languageCode: language.code,
      fallbackPhase: 'success',
      cacheKey: cacheKey,
    );
  }

  /// Pre-flight typo / missing-target message.
  ///
  /// Used when the deterministic [EntityResolver] catches a target name that
  /// does not match any existing entity. Two flavors:
  /// - `suggestion != null`: probable typo. Ask "did you mean X?".
  /// - `suggestion == null`: no plausible match. Surface available options.
  ///
  /// Pure safety-net path; the reflector usually catches this earlier via
  /// the EXISTENCE & TYPO RULES in its prompt.
  Future<String> clarifyTarget({
    required String entityType,
    required String userTyped,
    String? suggestion,
    List<String> available = const [],
    required DetectedLanguage language,
  }) async {
    final cacheKey = _key(
      'clarify_target',
      entityType,
      const {},
      language.code,
      extra: {
        'user_typed': userTyped,
        'suggestion': suggestion ?? '',
        'available': available,
      },
    );
    final cached = _turnCache[cacheKey];
    if (cached != null) return cached;

    final availBlock = available.isEmpty
        ? 'none'
        : available.take(8).join(', ');

    final prompt = suggestion != null
        ? '''You write ONE short clarifying question because the user referenced a $entityType that does not exactly match anything that exists.

User typed: "$userTyped"
Closest existing $entityType: "$suggestion"
All existing ${entityType}s: $availBlock

Rules:
- Reply in ${language.label} (${language.code}). Match this language exactly.
- 1 short sentence. Politely ask if they meant the closest match, e.g. "Did you mean $suggestion?".
- Do not expose internal IDs.

Reply with the message only. No JSON, no quotes, no markdown.'''
        : '''You write ONE short message because the user referenced a $entityType that does not exist.

User typed: "$userTyped"
All existing ${entityType}s: $availBlock

Rules:
- Reply in ${language.label} (${language.code}). Match this language exactly.
- 1–2 short sentences. Tell the user the $entityType was not found, then list the available ones briefly so they can choose.
- Friendly tone, never blaming the user.

Reply with the message only. No JSON, no quotes, no markdown.''';

    return _callOrFallback(
      prompt: prompt,
      phase: 'verbalize.clarify_target',
      languageCode: language.code,
      fallbackPhase: 'preview',
      cacheKey: cacheKey,
    );
  }

  /// Heads-up emitted when the analyzer classifies a new user request as
  /// unrelated to an active in-flight task. The runtime archives the old
  /// task as aborted; this string tells the user politely so they aren't
  /// surprised that their previous task is no longer being worked on.
  Future<String> taskAborted({
    required String previousMainGoal,
    required DetectedLanguage language,
  }) async {
    final cacheKey = _key(
      'task_aborted',
      'ledger',
      const {},
      language.code,
      extra: {'goal': previousMainGoal},
    );
    final cached = _turnCache[cacheKey];
    if (cached != null) return cached;

    final prompt = '''You write ONE short, friendly note because the user just sent a request that is unrelated to a task that was still in progress.

Previous task in progress: "$previousMainGoal"

Rules:
- Reply in ${language.label} (${language.code}). Match this language exactly.
- 1 short sentence in first-person, casual tone.
- Acknowledge the previous task is being set aside (not "deleted", not "failed").
- Do not promise to come back to it. Do not ask the user anything.
- No tool names, no IDs, no jargon.

Reply with the message only. No JSON, no quotes, no markdown.''';

    return _callOrFallback(
      prompt: prompt,
      phase: 'verbalize.task_aborted',
      languageCode: language.code,
      fallbackPhase: 'preview',
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

  /// Keep enough content for answer synthesis while still avoiding huge prompts.
  static Map<String, dynamic>? _answerData(Map<String, dynamic>? data) {
    if (data == null) return null;
    final out = <String, dynamic>{};
    data.forEach((k, v) {
      if (v is String && v.length > 6000) {
        out[k] = '${v.substring(0, 6000)}\n...[truncated]';
      } else if (v is List && v.length > 20) {
        out[k] = [...v.take(20), '...(+${v.length - 20} more)'];
      } else {
        out[k] = v;
      }
    });
    return out;
  }

  /// Deterministic provider disambiguation prompt.
  ///
  /// Used by the engine fallback when `system.agents.create` returned a
  /// providers list. The verbalizer doesn't need to be smart here — just
  /// natural and localized.
  Future<String> providerDisambiguation({
    required String availableProviders,
    required DetectedLanguage language,
  }) async {
    final prompt = '''You write ONE short sentence asking the user to pick a provider.

Available: ${availableProviders.isEmpty ? '(none listed)' : availableProviders}

Rules:
- Reply in ${language.label} (${language.code}). Match this language exactly.
- Speak naturally as a helpful assistant.
- 1 sentence. End with a clear question.
- List the available options if any.''';

    return _callOrFallback(
      prompt: prompt,
      phase: 'verbalize.provider_disambiguation',
      languageCode: language.code,
      fallbackPhase: 'confirm',
      cacheKey: 'provider_disambiguation|${language.code}|$availableProviders',
    );
  }

  /// Context-aware fallback question when a tool fails and the reviewer LLM
  /// didn't provide a `question` field.
  ///
  /// Delegates to the LLM so the output is naturally localized to the user's
  /// detected language — no hardcoded bilingual branching.
  Future<String> fallbackQuestion({
    required String error,
    String? availableNames,
    String? triedName,
    required DetectedLanguage language,
  }) async {
    final parts = <String>[
      'You write ONE short natural question to help the user resolve a tool failure.',
      '',
      'Context:',
      if (error.isNotEmpty) 'Error: $error',
      if (triedName != null && triedName.isNotEmpty) 'The user tried: "$triedName"',
      if (availableNames != null && availableNames.isNotEmpty) 'Available options: $availableNames',
      '',
      'Rules:',
      '- Reply in ${language.label} (${language.code}). Match this language exactly.',
      '- Speak naturally as a helpful assistant. Never expose internal tool names or IDs.',
      '- 1–2 short sentences. End with a clear question.',
      if (triedName != null && availableNames != null)
        '- If options are available, ask the user to pick from them.',
      if (error.contains('required') || error.contains('is required'))
        '- The issue is a missing required field. Ask what it should be.',
      if (error.contains('Refusing'))
        '- The action is not allowed. Explain briefly and ask what else they want.',
      '- If nothing else applies, ask them to clarify or try a different approach.',
    ];

    final prompt = parts.join('\n');
    final promptHash = error.hashCode.toRadixString(16);
    return _callOrFallback(
      prompt: prompt,
      phase: 'verbalize.fallback_question',
      languageCode: language.code,
      fallbackPhase: 'error',
      cacheKey: 'fallback_q|${language.code}|$promptHash',
    );
  }
}
