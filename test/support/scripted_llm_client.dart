import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:meow_agent/features/settings/data/llm_provider_config.dart';
import 'package:meow_agent/services/llm/openai_compatible_client.dart';

/// One recorded LLM call made during a scripted run.
class ScriptedLlmCall {
  ScriptedLlmCall({required this.phase, required this.messages});

  final String phase;
  final List<Map<String, String>> messages;

  /// Convenience: the user-content of the last message in the call.
  String get lastUserContent {
    for (final m in messages.reversed) {
      if (m['role'] == 'user') return m['content'] ?? '';
    }
    return messages.isEmpty ? '' : (messages.last['content'] ?? '');
  }
}

/// A deterministic [OpenAiCompatibleClient] test double.
///
/// Returns canned raw responses keyed by the `phase` passed to [chat]. Each
/// phase has its own FIFO queue, so a multi-step run can script several
/// `selectTool`/`review` turns in order. Every call is appended to [callLog]
/// so golden tests can assert the exact LLM call sequence (and count) for a
/// turn — the core regression signal for the orchestration refactor.
///
/// A call to an unstubbed phase throws loudly: an accidental extra LLM call
/// is a test failure, not a silent fallback.
class ScriptedLlmClient extends OpenAiCompatibleClient {
  ScriptedLlmClient(Map<String, List<String>> responsesByPhase) {
    responsesByPhase.forEach((phase, responses) {
      _byPhase[phase] = Queue<String>.from(responses);
    });
  }

  final Map<String, Queue<String>> _byPhase = {};

  /// Ordered log of every [chat] invocation, across all phases.
  final List<ScriptedLlmCall> callLog = [];

  /// Number of times a given phase was invoked.
  int countOf(String phase) => callLog.where((c) => c.phase == phase).length;

  /// Total LLM calls in this run.
  int get totalCalls => callLog.length;

  /// Phases invoked, in order (handy for `expect(client.phaseSequence, [...])`).
  List<String> get phaseSequence => callLog.map((c) => c.phase).toList();

  @override
  Future<String> chat({
    required LlmProviderConfig config,
    required List<Map<String, String>> messages,
    String phase = 'chat',
    List<String> imageDataUrls = const [],
    CancelToken? cancelToken,
  }) async {
    final resolvedPhase = _resolvePhaseAlias(phase);
    callLog.add(ScriptedLlmCall(phase: resolvedPhase, messages: messages));

    final queue = _byPhase[resolvedPhase];
    if (queue == null || queue.isEmpty) {
      throw StateError(
        'ScriptedLlmClient: no scripted response for phase "$phase" '
        '(resolved "$resolvedPhase", call #${callLog.length}). '
        'Scripted phases: ${_byPhase.keys.toList()}. '
        'An unexpected LLM call usually means the orchestration took a path '
        'the test did not anticipate.',
      );
    }
    return queue.removeFirst();
  }

  String _resolvePhaseAlias(String phase) {
    switch (phase) {
      case 'classify':
        if ((_byPhase['chat_route']?.isNotEmpty ?? false)) {
          return 'chat_route';
        }
        return phase;
      case 'analyze':
        if ((_byPhase['classify']?.isNotEmpty ?? false)) return 'classify';
        if ((_byPhase['chat_route']?.isNotEmpty ?? false)) {
          return 'chat_route';
        }
        return phase;
      case 'select_tool':
        if ((_byPhase['selectTool']?.isNotEmpty ?? false)) {
          return 'selectTool';
        }
        return phase;
      default:
        return phase;
    }
  }
}
