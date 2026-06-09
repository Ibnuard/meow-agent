import 'runtime_models.dart';

/// Logs runtime events in memory for later persistence.
class RuntimeLogger {
  final List<RuntimeEvent> _events = [];

  List<RuntimeEvent> get events => List.unmodifiable(_events);

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

  /// LLM-supplied POV-AI narrative attached to a phase JSON.
  /// Surfaced to the UI as the "what is the agent thinking right now" bubble.
  /// [phase] is the phase that produced it (analyze, reflect, plan, ...).
  void logNarrative(String phase, String narrative) {
    if (narrative.trim().isEmpty) return;
    _events.add(
      RuntimeEvent(
        type: 'narrative',
        message: narrative.trim(),
        data: {'phase': phase},
      ),
    );
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
