import 'runtime_models.dart';

/// Logs runtime events in memory for later persistence.
class RuntimeLogger {
  final List<RuntimeEvent> _events = [];

  List<RuntimeEvent> get events => List.unmodifiable(_events);

  /// Phases allowed to surface a narrative bubble to the user.
  ///
  /// The narrative is the ambient "what I'm doing" line. We only show it at
  /// THINKING / DECISION / REFLECT moments — not on every tool step — so the
  /// user gets one coherent line per turn instead of 3–4 near-identical bubbles
  /// ("Oke saya akan buka X...") restated by analyze → reflect → plan → select.
  ///
  /// Excluded on purpose: 'plan' (restates reflect), 'select_tool' and
  /// 'review' (per-tool-step chatter). Those phases still drive the overlay /
  /// thinking indicator elsewhere; they just don't emit a chat bubble.
  static const _narrativeBubblePhases = <String>{
    'analyze',
    'reflect',
    'relation',
    'direct',
  };

  // Cross-phase de-duplication of narrative bubbles for the CURRENT turn.
  // Loop-local dedup missed repeats ACROSS phases (analyze vs reflect vs
  // select), which is exactly where the user saw stacked duplicates. Keyed on
  // normalized text with a small rolling window.
  static const int _narrativeWindow = 6;
  final List<String> _recentNarratives = [];

  /// Emit a narrative bubble for [phase]. Returns true if it was actually
  /// logged (caller should `emit` only then). Drops the event when the phase
  /// isn't bubble-eligible or the text duplicates a recent narrative.
  bool logNarrative(String phase, String narrative) {
    final text = narrative.trim();
    if (text.isEmpty) return false;
    if (!_narrativeBubblePhases.contains(phase)) return false;

    final norm = _normalizeNarrative(text);
    for (final prior in _recentNarratives) {
      if (prior == norm) return false;
      if (norm.length >= 12 && (prior.contains(norm) || norm.contains(prior))) {
        return false;
      }
    }
    _recentNarratives.add(norm);
    if (_recentNarratives.length > _narrativeWindow) {
      _recentNarratives.removeAt(0);
    }

    _events.add(
      RuntimeEvent(
        type: 'narrative',
        message: text,
        data: {'phase': phase},
      ),
    );
    return true;
  }

  static String _normalizeNarrative(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  void logStateChange(AgentRuntimeState state, String message) {
    _events.add(
      RuntimeEvent(
        type: 'state_change',
        message: message,
        data: {'state': state.name},
      ),
    );
  }

  void logLlmDecision(String phase, Map<String, dynamic> json, {String? version}) {
    _events.add(
      RuntimeEvent(
        type: 'llm_decision',
        message: '$phase decision',
        data: {'_prompt_version': ?version, ...json},
      ),
    );
  }

  void logToolCall(ToolCallRequest request) {
    _events.add(
      RuntimeEvent(
        type: 'tool_call',
        message: 'Calling tool: ${request.name}',
        data: {
          'name': request.name,
          'args': request.args,
          'risk': request.risk,
        },
      ),
    );
  }

  void logToolResult(ToolExecutionResult result) {
    _events.add(
      RuntimeEvent(
        type: 'tool_result',
        message: result.success
            ? 'Tool ${result.toolName} succeeded'
            : 'Tool ${result.toolName} failed: ${result.error}',
        data: {
          'tool': result.toolName,
          'success': result.success,
          if (result.data != null) 'data': result.data,
          if (result.error != null) 'error': result.error,
        },
      ),
    );
  }

  void logError(String message, [Object? error]) {
    _events.add(
      RuntimeEvent(
        type: 'error',
        message: message,
        data: error != null ? {'error': error.toString()} : null,
      ),
    );
  }

  void logFinalResponse(String response) {
    _events.add(RuntimeEvent(type: 'final_response', message: response));
  }

  /// A self-correction moment — the runtime caught and recovered from a
  /// model mistake or a stale-state mismatch. Surfaced in /log for visibility
  /// into how often each recovery path fires. [kind] is a stable enum-like
  /// string (e.g. 'fast_path_exhausted', 'narrative_gate_override').
  void logDivergence(String kind, Map<String, dynamic> details) {
    _events.add(
      RuntimeEvent(
        type: 'divergence',
        message: 'Recovery: $kind',
        data: {'kind': kind, ...details},
      ),
    );
  }

  void clear() => _events.clear();
}
