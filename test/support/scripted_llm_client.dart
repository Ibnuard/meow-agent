import 'dart:collection';
import 'dart:convert';

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

  String get combinedContent =>
      messages.map((m) => m['content'] ?? '').join('\n\n');
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
      if (phase == 'classify') {
        final synthesized = _synthesizeClassifyFromLegacyPhases();
        if (synthesized != null) return synthesized;
      }
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

  String? _synthesizeClassifyFromLegacyPhases() {
    final analyzeQueue = _byPhase['analyze'];
    if (analyzeQueue == null || analyzeQueue.isEmpty) return null;

    Map<String, dynamic> parse(String raw) {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic>
          ? decoded
          : Map<String, dynamic>.from(decoded as Map);
    }

    final analysis = parse(analyzeQueue.removeFirst());
    final reflectionQueue = _byPhase['reflect'];
    final planQueue = _byPhase['plan'];
    final reflection = reflectionQueue != null && reflectionQueue.isNotEmpty
        ? parse(reflectionQueue.removeFirst())
        : <String, dynamic>{};
    final plan = planQueue != null && planQueue.isNotEmpty
        ? parse(planQueue.removeFirst())
        : <String, dynamic>{};

    final missingInfo = analysis['missing_info'];
    final requiresTools =
        analysis['requires_tools'] ??
        (missingInfo is List && missingInfo.isNotEmpty ? false : true);
    final reflectionGoalTree = reflection['goal_tree'];
    final reflectionSubgoals = reflectionGoalTree is Map
        ? reflectionGoalTree['subgoals']
        : reflection['subgoals'];
    final subgoals = reflectionSubgoals ?? plan['subgoals'] ?? const [];
    final completionCriteria =
        (reflectionGoalTree is Map
            ? reflectionGoalTree['completion_criteria']
            : null) ??
        reflection['completion_criteria'] ??
        plan['completion_criteria'] ??
        const [];
    final mainGoal =
        (reflectionGoalTree is Map ? reflectionGoalTree['main_goal'] : null) ??
        reflection['main_goal'] ??
        plan['main_goal'] ??
        analysis['goal'] ??
        '';
    final goalTree = reflectionGoalTree is Map
        ? reflectionGoalTree
        : {
            'main_goal': mainGoal,
            'completion_criteria': completionCriteria,
            'subgoals': subgoals,
          };

    final classify = <String, dynamic>{
      'route': requiresTools == true ? 'agentic' : 'agentic',
      'direct_response': '',
      'intent': analysis['intent'] ?? '',
      'goal': analysis['goal'] ?? mainGoal,
      'requires_tools': requiresTools,
      'risk': analysis['risk'] ?? 'safe',
      'detected_language': analysis['detected_language'] ?? '',
      'selected_skill_ids': analysis['selected_skill_ids'] ?? const [],
      'tool_groups': analysis['tool_groups'] ?? const [],
      'missing_info': analysis['missing_info'] ?? const [],
      'subgoal_seeds': analysis['subgoal_seeds'] ?? const [],
      'requested_item_count': analysis['requested_item_count'],
      'bulk_selector': analysis['bulk_selector'] ?? false,
      'task_relation': analysis['task_relation'] ?? 'none',
      'strategy': reflection['strategy'] ?? 'direct_execute',
      'targets': reflection['targets'] ?? const [],
      'impacts': reflection['impacts'] ?? const [],
      'clarify_questions':
          reflection['clarify_questions'] ??
          analysis['clarify_questions'] ??
          analysis['missing_info'] ??
          const [],
      'block_reason': reflection['block_reason'] ?? '',
      'reasoning': reflection['reasoning'] ?? '',
      'goal_tree': goalTree,
      'main_goal': mainGoal,
      'completion_criteria': completionCriteria,
      'required_capabilities':
          analysis['required_capabilities'] ??
          plan['required_capabilities'] ??
          const [],
      'tool_call': analysis['tool_call'],
      'subgoals': subgoals,
      'narrative': analysis['narrative'] ?? reflection['narrative'] ?? '',
      'next_narrative':
          analysis['next_narrative'] ??
          reflection['next_narrative'] ??
          plan['next_narrative'] ??
          '',
    };
    return jsonEncode(classify);
  }
}
