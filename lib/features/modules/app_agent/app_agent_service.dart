import 'package:flutter/services.dart';

import '../../../services/agent_runtime/runtime_models.dart';

class AppAgentService {
  static const _channel = MethodChannel('com.meowagent/app_agent');

  Future<ToolExecutionResult> inspect(Map<String, dynamic> args) async {
    try {
      final data = await _capture();
      return ToolExecutionResult(
        success: data['success'] == true,
        toolName: 'app_agent.inspect',
        data: data,
        error: data['success'] == true ? null : _errorFrom(data),
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'app_agent.inspect',
        error: 'Failed to inspect current screen: $e',
      );
    }
  }

  Future<ToolExecutionResult> click(Map<String, dynamic> args) {
    return _perform('app_agent.click', {
      'action': 'click',
      'node_id': _readNodeId(args),
    });
  }

  Future<ToolExecutionResult> setText(Map<String, dynamic> args) {
    final text = (args['text'] as String?) ?? '';
    if (text.isEmpty) {
      return Future.value(
        const ToolExecutionResult(
          success: false,
          toolName: 'app_agent.set_text',
          error: 'text cannot be empty.',
        ),
      );
    }
    return _perform('app_agent.set_text', {
      'action': 'set_text',
      'node_id': _readNodeId(args),
      'text': text,
    });
  }

  Future<ToolExecutionResult> scroll(Map<String, dynamic> args) {
    final direction = ((args['direction'] as String?) ?? 'down').toLowerCase();
    final action = switch (direction) {
      'up' || 'backward' => 'scroll_up',
      _ => 'scroll_down',
    };
    return _perform('app_agent.scroll', {
      'action': action,
      'node_id': _readNodeId(args),
      'direction': direction,
    });
  }

  Future<Map<String, dynamic>> _capture() async {
    final result = await _channel.invokeMethod<Map>('captureScreen');
    return Map<String, dynamic>.from(result ?? const {});
  }

  Future<ToolExecutionResult> _perform(
    String toolName,
    Map<String, dynamic> args,
  ) async {
    final nodeId = args['node_id'];
    if (nodeId is! int || nodeId < 0) {
      return ToolExecutionResult(
        success: false,
        toolName: toolName,
        error: 'node_id must be a non-negative integer from app_agent.inspect.',
      );
    }

    try {
      final result = await _channel.invokeMethod<Map>('performAction', args);
      final data = Map<String, dynamic>.from(result ?? const {});
      final success = data['success'] == true;
      return ToolExecutionResult(
        success: success,
        toolName: toolName,
        data: data,
        error: success ? null : _errorFrom(data),
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: toolName,
        error: 'Failed to perform app action: $e',
      );
    }
  }

  int _readNodeId(Map<String, dynamic> args) {
    final raw = args['node_id'] ?? args['node'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw) ?? -1;
    return -1;
  }

  String _errorFrom(Map<String, dynamic> data) {
    final error = data['error']?.toString();
    final message = data['message']?.toString();
    if (error != null && message != null && message.isNotEmpty) {
      return '$error: $message';
    }
    return error ?? 'app_agent_action_failed';
  }
}
