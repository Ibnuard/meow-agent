import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/agent_runtime/runtime_engine.dart';
import '../../../services/agent_runtime/runtime_models.dart';
import '../../agents/data/agent_repository.dart';
import '../../providers/data/provider_config.dart';
import '../../providers/data/provider_repository.dart';
import '../../settings/data/llm_debug_provider.dart';
import 'chat_history_service.dart';

/// Per-agent runtime state. Survives ChatScreen disposal so navigating away
/// does not cancel in-flight work; results are persisted regardless of UI.
class ChatRuntimeSession {
  ChatRuntimeSession({
    required this.agentId,
    this.isRunning = false,
    this.debugMessages = const [],
    this.pendingTool,
    this.pendingToolArgs,
    this.lastReplyAt,
  });

  final String agentId;
  final bool isRunning;
  final List<ChatMessage> debugMessages;
  final String? pendingTool;
  final Map<String, dynamic>? pendingToolArgs;
  final DateTime? lastReplyAt;

  ChatRuntimeSession copyWith({
    bool? isRunning,
    List<ChatMessage>? debugMessages,
    String? pendingTool,
    Map<String, dynamic>? pendingToolArgs,
    DateTime? lastReplyAt,
    bool clearPending = false,
  }) {
    return ChatRuntimeSession(
      agentId: agentId,
      isRunning: isRunning ?? this.isRunning,
      debugMessages: debugMessages ?? this.debugMessages,
      pendingTool: clearPending ? null : (pendingTool ?? this.pendingTool),
      pendingToolArgs: clearPending
          ? null
          : (pendingToolArgs ?? this.pendingToolArgs),
      lastReplyAt: lastReplyAt ?? this.lastReplyAt,
    );
  }
}

/// Owns active per-agent runtime sessions. Outlives the chat screen.
class ChatRuntimeManager extends ChangeNotifier {
  ChatRuntimeManager({
    required this.engine,
    required this.history,
    required this.ref,
  });

  final AgentRuntimeEngine engine;
  final ChatHistoryService history;
  final Ref ref;

  final Map<String, ChatRuntimeSession> _sessions = {};

  ChatRuntimeSession sessionFor(String agentId) =>
      _sessions[agentId] ?? ChatRuntimeSession(agentId: agentId);

  /// True if any agent has an in-flight runtime session.
  /// Used by the home FAB to show a live activity indicator.
  bool get hasAnyRunning => _sessions.values.any((s) => s.isRunning);

  void _set(String agentId, ChatRuntimeSession s) {
    _sessions[agentId] = s;
    notifyListeners();
  }

  Future<ProviderConfig?> _resolveProvider(String agentId) async {
    final agents = ref.read(agentListProvider);
    final providers = ref.read(providerListProvider).value ?? [];
    final agent = agents.where((a) => a.id == agentId).firstOrNull
        ?? (agents.isNotEmpty ? agents.first : null);
    if (agent == null) return null;
    return providers.where((p) => p.id == agent.providerId).firstOrNull;
  }

  /// Send user message + run runtime. Persists user msg and final reply
  /// to history unconditionally.
  Future<void> send({
    required String agentId,
    required String userMessage,
    required List<ChatMessage> recentMessages,
  }) async {
    final provider = await _resolveProvider(agentId);
    if (provider == null) return;

    // Persist user message immediately.
    final userMsg = ChatMessage(role: 'user', content: userMessage);
    await history.addMessage(agentId, userMsg);

    _set(agentId, sessionFor(agentId).copyWith(
      isRunning: true,
      debugMessages: [],
      clearPending: true,
    ));

    final debugMode = ref.read(llmDebugModeProvider);

    try {
      final response = await engine.run(
        AgentRuntimeRequest(
          agentId: agentId,
          userMessage: userMessage,
          recentMessages: recentMessages,
        ),
        provider: provider,
        onEvent: debugMode
            ? (event) {
                final s = sessionFor(agentId);
                _set(agentId, s.copyWith(
                  debugMessages: [
                    ...s.debugMessages,
                    ChatMessage(
                      role: 'assistant',
                      content: '⚙️ ${event.message}',
                    ),
                  ],
                ));
              }
            : null,
      );

      final isConfirm =
          response.state == AgentRuntimeState.waitingConfirmation;
      final replyMsg = ChatMessage(
        role: 'assistant',
        content: isConfirm
            ? '🔐 ${response.finalMessage}\n\n[[CONFIRMATION_REQUIRED]]'
            : response.finalMessage,
      );
      await history.addMessage(agentId, replyMsg);

      _set(agentId, sessionFor(agentId).copyWith(
        isRunning: false,
        debugMessages: [],
        pendingTool: response.pendingTool,
        pendingToolArgs: response.pendingToolArgs,
        lastReplyAt: DateTime.now(),
      ));
    } catch (e) {
      await history.addMessage(
        agentId,
        ChatMessage(role: 'assistant', content: 'Error: $e'),
      );
      _set(agentId, sessionFor(agentId).copyWith(
        isRunning: false,
        debugMessages: [],
        lastReplyAt: DateTime.now(),
      ));
    }
  }

  /// Approve a pending sensitive tool.
  Future<void> confirm(String agentId) async {
    final s = sessionFor(agentId);
    final tool = s.pendingTool;
    if (tool == null) return;

    final provider = await _resolveProvider(agentId);
    if (provider == null) return;

    _set(agentId, s.copyWith(
      isRunning: true,
      debugMessages: [],
      clearPending: true,
    ));

    final debugMode = ref.read(llmDebugModeProvider);

    try {
      final response = await engine.executeConfirmed(
        AgentRuntimeRequest(
          agentId: agentId,
          userMessage: '',
          recentMessages: const [],
        ),
        provider: provider,
        toolName: tool,
        toolArgs: s.pendingToolArgs ?? {},
        onEvent: debugMode
            ? (event) {
                final cur = sessionFor(agentId);
                _set(agentId, cur.copyWith(
                  debugMessages: [
                    ...cur.debugMessages,
                    ChatMessage(
                      role: 'assistant',
                      content: '⚙️ ${event.message}',
                    ),
                  ],
                ));
              }
            : null,
      );

      await history.addMessage(
        agentId,
        ChatMessage(role: 'assistant', content: response.finalMessage),
      );

      _set(agentId, sessionFor(agentId).copyWith(
        isRunning: false,
        debugMessages: [],
        lastReplyAt: DateTime.now(),
      ));
    } catch (e) {
      await history.addMessage(
        agentId,
        ChatMessage(role: 'assistant', content: 'Error: $e'),
      );
      _set(agentId, sessionFor(agentId).copyWith(
        isRunning: false,
        debugMessages: [],
        lastReplyAt: DateTime.now(),
      ));
    }
  }

  /// Reject a pending tool.
  Future<void> reject(String agentId) async {
    await history.addMessage(
      agentId,
      ChatMessage(role: 'assistant', content: '❌ Aksi dibatalkan oleh pengguna.'),
    );
    _set(agentId, sessionFor(agentId).copyWith(
      isRunning: false,
      debugMessages: [],
      clearPending: true,
      lastReplyAt: DateTime.now(),
    ));
  }
}

final chatRuntimeManagerProvider = ChangeNotifierProvider<ChatRuntimeManager>(
  (ref) {
    return ChatRuntimeManager(
      engine: ref.watch(agentRuntimeEngineProvider),
      history: ref.watch(chatHistoryServiceProvider),
      ref: ref,
    );
  },
);
