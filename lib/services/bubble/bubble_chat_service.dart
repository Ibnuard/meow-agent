import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/agents/data/agent_repository.dart';
import '../../features/providers/data/provider_repository.dart';
import '../agent_runtime/runtime_engine.dart';
import '../agent_runtime/runtime_models.dart';

/// Handles chat messages from the floating bubble overlay.
///
/// Listens for 'onBubbleChat' calls from native, runs the message through
/// the FULL AgentRuntimeEngine (with tool support), and sends the response
/// back to the bubble via 'sendResponse'.
class BubbleChatService {
  BubbleChatService(this._ref);

  final WidgetRef _ref;
  static const _channel = MethodChannel('com.meowagent/bubble');
  static bool _initialized = false;

  /// Initialize the listener. Call once during app startup.
  void init() {
    if (_initialized) return;
    _initialized = true;

    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onBubbleChat':
          final args = Map<String, dynamic>.from(call.arguments as Map);
          final message = args['message'] as String? ?? '';
          if (message.isNotEmpty) {
            await _handleBubbleMessage(message);
          }
          return null;
        case 'onRequestInfo':
          await _sendChatInfo();
          return null;
        case 'onCancelBubbleChat':
          // Abort the active runtime task for default agent
          final agents = await _ref.read(agentRepositoryProvider).loadAll();
          if (agents.isEmpty) return null;
          final defaultAgent = agents.firstWhere(
            (a) => a.id == 'default',
            orElse: () => agents.first,
          );
          final engine = _ref.read(agentRuntimeEngineProvider);
          await engine.abortActiveTask(defaultAgent.id);
          return null;
        default:
          throw MissingPluginException('Not implemented: ${call.method}');
      }
    });
  }

  /// Process a bubble chat message through the full runtime engine.
  Future<void> _handleBubbleMessage(String message) async {
    try {
      // Load providers directly from repository (async-safe)
      final repo = _ref.read(providerRepositoryProvider);
      final providers = await repo.loadAll();

      if (providers.isEmpty) {
        await _sendResponse(
            'No AI provider configured. Open Meow Agent to set up.');
        return;
      }

      // Resolve default agent and provider
      final agents = await _ref.read(agentRepositoryProvider).loadAll();
      if (agents.isEmpty) {
        await _sendResponse(
            'No agent configured. Open Meow Agent to create one.');
        return;
      }
      final defaultAgent = agents.firstWhere(
        (a) => a.id == 'default',
        orElse: () => agents.first,
      );

      final provider = providers.firstWhere(
        (p) => p.id == defaultAgent.providerId,
        orElse: () => providers.first,
      );

      final modelName = provider.effectiveModel(defaultAgent.model);
      final effectiveProvider = provider.copyWith(model: modelName);

      // Use the full AgentRuntimeEngine with tool support
      final engine = _ref.read(agentRuntimeEngineProvider);

      final response = await engine.run(
        AgentRuntimeRequest(
          agentId: defaultAgent.id,
          agentName: defaultAgent.name,
          userMessage: message,
          recentMessages: const [], // Bubble is stateless per-message
          attachments: const [],
        ),
        provider: effectiveProvider,
        onEvent: (event) {
          // Send narrative updates to bubble for real-time feedback
          if (event.type == 'narrative') {
            final msg = event.message.trim();
            if (msg.isNotEmpty) {
              _sendNarrative(msg);
            }
          }
        },
      );

      await _sendResponse(response.finalMessage);
    } catch (e) {
      final errorMsg = e.toString().split('\n').first;
      await _sendResponse('Error: $errorMsg');
    }
  }

  /// Send agent/model info to the bubble header subtitle.
  Future<void> _sendChatInfo() async {
    try {
      final repo = _ref.read(providerRepositoryProvider);
      final providers = await repo.loadAll();

      if (providers.isEmpty) {
        await _channel.invokeMethod('updateChatInfo', {'info': 'No provider'});
        return;
      }

      final agents = await _ref.read(agentRepositoryProvider).loadAll();
      if (agents.isEmpty) {
        await _channel.invokeMethod('updateChatInfo', {'info': 'No agent'});
        return;
      }
      final defaultAgent = agents.firstWhere(
        (a) => a.id == 'default',
        orElse: () => agents.first,
      );

      final provider = providers.firstWhere(
        (p) => p.id == defaultAgent.providerId,
        orElse: () => providers.first,
      );

      final modelName = provider.effectiveModel(defaultAgent.model);
      final info = '${defaultAgent.name} · ${provider.nickname} · $modelName';

      await _channel.invokeMethod('updateChatInfo', {'info': info});
    } catch (_) {
      // Non-fatal
    }
  }

  /// Send narrative progress text to the bubble (shown while loading).
  void _sendNarrative(String text) {
    _channel.invokeMethod('sendNarrative', {'text': text}).catchError((_) {});
  }

  /// Send response text back to the native bubble overlay.
  Future<void> _sendResponse(String response) async {
    try {
      await _channel.invokeMethod('sendResponse', {
        'response': response,
      });
    } catch (_) {
      // Flutter engine might not be connected — ignore silently
    }
  }
}
