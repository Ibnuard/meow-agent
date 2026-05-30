import 'package:meow_agent/services/agent_runtime/runtime_models.dart';
import 'package:meow_agent/services/agent_runtime/tool_router.dart';

/// One recorded tool dispatch during a scripted run.
class ScriptedDispatch {
  ScriptedDispatch({required this.name, required this.args});

  final String name;
  final Map<String, dynamic> args;
}

/// A deterministic [ToolRouter] test double.
///
/// Overrides [execute]/[forceExecute] to return canned results keyed by tool
/// name, and records every dispatch in [dispatchLog] (order + args) so golden
/// tests can assert the exact tool sequence. Metadata methods (getDefinition,
/// validate, build*Descriptions, registeredTools) are NOT overridden — they
/// fall through to the real registry, so genuine [ToolDefinition] risk and
/// confirmation flags still drive the engine's confirmation gate.
///
/// Permission policy and cross-workspace checks are short-circuited so tests
/// don't touch real module repositories or the filesystem.
class ScriptedToolRouter extends ToolRouter {
  ScriptedToolRouter({
    required Map<String, ToolExecutionResult> results,
    super.agentName = 'TestAgent',
    super.agentId = 'test-agent',
  }) : _results = results;

  /// Canned results keyed by tool name. A name may map to a queue-like list
  /// via [resultsByCall] when the same tool is called multiple times with
  /// different outcomes.
  final Map<String, ToolExecutionResult> _results;

  /// Optional per-call override: tool name → ordered results. When present for
  /// a tool, each call pops the next entry (falling back to [_results] once
  /// exhausted). Lets a scenario script "first delete fails, retry succeeds".
  final Map<String, List<ToolExecutionResult>> resultsByCall = {};

  final List<ScriptedDispatch> dispatchLog = [];

  ToolExecutionResult _resultFor(ToolCallRequest request) {
    final perCall = resultsByCall[request.name];
    if (perCall != null && perCall.isNotEmpty) {
      return perCall.removeAt(0);
    }
    final canned = _results[request.name];
    if (canned != null) return canned;
    return ToolExecutionResult(
      success: false,
      toolName: request.name,
      error: 'ScriptedToolRouter: no canned result for ${request.name}',
    );
  }

  @override
  Future<ToolExecutionResult> execute(ToolCallRequest request) async {
    dispatchLog.add(ScriptedDispatch(name: request.name, args: request.args));
    return _resultFor(request);
  }

  @override
  Future<ToolExecutionResult> forceExecute(ToolCallRequest request) async {
    dispatchLog.add(ScriptedDispatch(name: request.name, args: request.args));
    return _resultFor(request);
  }

  /// No real permission policy in tests — nothing is ever denied.
  @override
  Future<ToolExecutionResult?> permissionDeniedResult(String toolName) async =>
      null;

  /// No filesystem in tests — never escalate to a cross-workspace gate.
  @override
  Future<bool> requiresCrossWorkspaceConfirmation(
    ToolCallRequest request,
  ) async => false;

  /// Number of times a given tool was dispatched.
  int dispatchCountOf(String toolName) =>
      dispatchLog.where((d) => d.name == toolName).length;

  /// Tool names dispatched, in order.
  List<String> get dispatchSequence => dispatchLog.map((d) => d.name).toList();
}
