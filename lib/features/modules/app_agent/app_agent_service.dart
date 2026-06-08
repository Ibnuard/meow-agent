import 'package:flutter/services.dart';

import '../../../services/agent_runtime/runtime_models.dart';
import '../../../services/shizuku/shizuku_device_service.dart';

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

  Future<ToolExecutionResult> back(Map<String, dynamic> args) async {
    try {
      final result = await _channel.invokeMethod<Map>('globalBack');
      final data = Map<String, dynamic>.from(result ?? const {});
      final success = data['success'] == true;
      return ToolExecutionResult(
        success: success,
        toolName: 'app_agent.back',
        data: data,
        error: success ? null : _errorFrom(data),
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'app_agent.back',
        error: 'Failed to perform back action: $e',
      );
    }
  }

  Future<ToolExecutionResult> findByText(Map<String, dynamic> args) async {
    final query = (args['query'] as String?)?.trim() ?? '';
    if (query.isEmpty) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'app_agent.find_by_text',
        error: 'query cannot be empty.',
      );
    }
    final mode = (args['mode'] as String?)?.toLowerCase() ?? 'contains';
    try {
      final result = await _channel.invokeMethod<Map>('findByText', {
        'query': query,
        'mode': mode == 'exact' ? 'exact' : 'contains',
      });
      final data = Map<String, dynamic>.from(result ?? const {});
      final success = data['success'] == true;
      return ToolExecutionResult(
        success: success,
        toolName: 'app_agent.find_by_text',
        data: data,
        error: success ? null : _errorFrom(data),
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'app_agent.find_by_text',
        error: 'Failed to find by text: $e',
      );
    }
  }

  Future<ToolExecutionResult> clickByText(Map<String, dynamic> args) async {
    final query = (args['query'] as String?)?.trim() ?? '';
    if (query.isEmpty) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'app_agent.click_by_text',
        error: 'query cannot be empty.',
      );
    }
    final mode = (args['mode'] as String?)?.toLowerCase() ?? 'contains';
    try {
      final result = await _channel.invokeMethod<Map>('clickByText', {
        'query': query,
        'mode': mode == 'exact' ? 'exact' : 'contains',
      });
      final data = Map<String, dynamic>.from(result ?? const {});
      final success = data['success'] == true;
      return ToolExecutionResult(
        success: success,
        toolName: 'app_agent.click_by_text',
        data: data,
        error: success ? null : _errorFrom(data),
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'app_agent.click_by_text',
        error: 'Failed to click by text: $e',
      );
    }
  }

  Future<ToolExecutionResult> key(Map<String, dynamic> args) async {
    final keycodeRaw = args['keycode'];
    final keycode = keycodeRaw is int
        ? keycodeRaw
        : (keycodeRaw is num ? keycodeRaw.toInt() : null);
    if (keycode == null || keycode <= 0) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'app_agent.key',
        error: 'keycode must be a positive integer (e.g. 66 for Enter/Send).',
      );
    }

    // For Enter/Search (keycode 66), try accessibility IME action first.
    // This works without Shizuku and covers keyboard submit/search buttons.
    if (keycode == 66) {
      try {
        final imeResult = await _channel.invokeMethod<Map>('imeEnter');
        final imeData = Map<String, dynamic>.from(imeResult ?? const {});
        if (imeData['success'] == true) {
          return ToolExecutionResult(
            success: true,
            toolName: 'app_agent.key',
            data: {'keycode': keycode, 'dispatched': true, 'method': 'ime'},
          );
        }
      } catch (_) {
        // Accessibility IME failed, fall through to Shizuku.
      }
    }

    // Fallback: Shizuku-based key injection.
    try {
      final svc = ShizukuDeviceService();
      final ok = await svc.keyEvent(keycode);
      return ToolExecutionResult(
        success: ok,
        toolName: 'app_agent.key',
        data: {'keycode': keycode, 'dispatched': ok, 'method': 'shizuku'},
        error: ok ? null : 'keyEvent returned false (Shizuku may not be ready).',
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'app_agent.key',
        error: 'Failed to inject key event: $e',
      );
    }
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
