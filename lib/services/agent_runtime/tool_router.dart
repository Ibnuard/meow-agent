import 'package:flutter/services.dart';

import 'runtime_models.dart';

/// Routes tool calls to their implementations.
/// Validates tool existence and enforces risk/confirmation rules.
class ToolRouter {
  ToolRouter();

  /// Registry of all known tools with their definitions.
  final Map<String, ToolDefinition> _registry = {
    'clipboard.read': const ToolDefinition(
      name: 'clipboard.read',
      description: 'Read current clipboard text.',
      risk: 'safe',
      requiresConfirmation: false,
    ),
    'clipboard.write': const ToolDefinition(
      name: 'clipboard.write',
      description: 'Write text to clipboard.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {'text': 'string'},
    ),
  };

  /// Get all registered tool names.
  List<String> get registeredTools => _registry.keys.toList();

  /// Check if a tool is registered.
  bool isRegistered(String name) => _registry.containsKey(name);

  /// Get the authoritative definition for a tool.
  /// Risk level comes from HERE, not from LLM output.
  ToolDefinition? getDefinition(String name) => _registry[name];

  /// Validate a tool call request against the registry.
  /// Returns null if valid, or an error message if invalid.
  String? validate(ToolCallRequest request) {
    if (!isRegistered(request.name)) {
      return 'Unknown tool: ${request.name}. Not registered.';
    }
    return null;
  }

  /// Execute a tool. Returns the result.
  /// IMPORTANT: Does NOT execute if tool requires confirmation.
  Future<ToolExecutionResult> execute(ToolCallRequest request) async {
    final definition = _registry[request.name];
    if (definition == null) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'Tool not found: ${request.name}',
      );
    }

    // Enforce confirmation from registry definition, not LLM.
    if (definition.requiresConfirmation) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'REQUIRES_CONFIRMATION',
      );
    }

    return _dispatch(request);
  }

  /// Force-execute a tool (user already confirmed). Bypasses confirmation.
  Future<ToolExecutionResult> forceExecute(ToolCallRequest request) async {
    final definition = _registry[request.name];
    if (definition == null) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'Tool not found: ${request.name}',
      );
    }
    return _dispatch(request);
  }

  Future<ToolExecutionResult> _dispatch(ToolCallRequest request) async {
    switch (request.name) {
      case 'clipboard.read':
        return _executeClipboardRead();
      case 'clipboard.write':
        return _executeClipboardWrite(request.args);
      default:
        return ToolExecutionResult(
          success: false,
          toolName: request.name,
          error: 'No implementation for tool: ${request.name}',
        );
    }
  }

  Future<ToolExecutionResult> _executeClipboardRead() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text ?? '';
      return ToolExecutionResult(
        success: true,
        toolName: 'clipboard.read',
        data: {'text': text},
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'clipboard.read',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> _executeClipboardWrite(
      Map<String, dynamic> args) async {
    try {
      final text = args['text'] as String? ?? '';
      await Clipboard.setData(ClipboardData(text: text));
      return ToolExecutionResult(
        success: true,
        toolName: 'clipboard.write',
        data: {'written': true},
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'clipboard.write',
        error: e.toString(),
      );
    }
  }
}
