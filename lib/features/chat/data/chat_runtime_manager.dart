import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/agent_runtime/i18n_fallback.dart';
import '../../../services/agent_runtime/language_detector.dart';
import '../../../services/agent_runtime/narrative_narrator.dart';
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
    this.narrativeMessage,
  });

  final String agentId;
  final bool isRunning;
  final List<ChatMessage> debugMessages;
  final String? pendingTool;
  final Map<String, dynamic>? pendingToolArgs;
  final DateTime? lastReplyAt;

  /// Always-visible POV-AI narrative bubble shown above the thinking
  /// indicator while [isRunning]. Updates as the runtime progresses through
  /// phases; cleared (set to null) once the run terminates.
  final String? narrativeMessage;

  ChatRuntimeSession copyWith({
    bool? isRunning,
    List<ChatMessage>? debugMessages,
    String? pendingTool,
    Map<String, dynamic>? pendingToolArgs,
    DateTime? lastReplyAt,
    String? narrativeMessage,
    bool clearPending = false,
    bool clearNarrative = false,
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
      narrativeMessage:
          clearNarrative ? null : (narrativeMessage ?? this.narrativeMessage),
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
      narrativeMessage: NarrativeNarrator.narrate(
        'understanding',
        _languageForUserMessage(userMessage),
      ),
    ));

    final debugMode = ref.read(llmDebugModeProvider);

    final agents = ref.read(agentListProvider);
    final agent = agents.where((a) => a.id == agentId).firstOrNull
        ?? (agents.isNotEmpty ? agents.first : null);
    final agentName = agent?.name ?? '';

    try {
      final response = await engine.run(
        AgentRuntimeRequest(
          agentId: agentId,
          agentName: agentName,
          userMessage: userMessage,
          recentMessages: recentMessages,
        ),
        provider: provider,
        onEvent: (event) {
          // LLM-driven narrative bubble: ONLY update when an explicit
          // narrative event arrives. State_change events no longer override
          // — the last LLM narrative stays sticky across phases that don't
          // emit one (executingTool, waitingConfirmation), so the bubble
          // remains contextual rather than reverting to generic static text.
          final llmNarrative = _narrativeFromEvent(event);
          if (llmNarrative != null) {
            final s = sessionFor(agentId);
            _set(agentId, s.copyWith(narrativeMessage: llmNarrative));
          }

          if (debugMode) {
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
        },
      );

      final isConfirm =
          response.state == AgentRuntimeState.waitingConfirmation;
      final replyMsg = ChatMessage(
        role: 'assistant',
        content: isConfirm
            ? '🔐 ${response.finalMessage}\n\n[[CONFIRMATION_REQUIRED]]'
            : response.finalMessage,
        actions: response.actions,
      );
      await history.addMessage(agentId, replyMsg);

      _set(agentId, sessionFor(agentId).copyWith(
        isRunning: false,
        debugMessages: [],
        pendingTool: response.pendingTool,
        pendingToolArgs: response.pendingToolArgs,
        lastReplyAt: DateTime.now(),
        clearNarrative: true,
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
        clearNarrative: true,
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
      narrativeMessage: NarrativeNarrator.narrate(
        'executing',
        engine.languageCode,
      ),
    ));

    final debugMode = ref.read(llmDebugModeProvider);

    final agents = ref.read(agentListProvider);
    final agent = agents.where((a) => a.id == agentId).firstOrNull
        ?? (agents.isNotEmpty ? agents.first : null);
    final agentName = agent?.name ?? '';

    try {
      final response = await engine.executeConfirmed(
        AgentRuntimeRequest(
          agentId: agentId,
          agentName: agentName,
          userMessage: '',
          recentMessages: const [],
        ),
        provider: provider,
        toolName: tool,
        toolArgs: s.pendingToolArgs ?? {},
        onEvent: (event) {
          final llmNarrative = _narrativeFromEvent(event);
          if (llmNarrative != null) {
            final cur = sessionFor(agentId);
            _set(agentId, cur.copyWith(narrativeMessage: llmNarrative));
          }
          if (debugMode) {
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
        },
      );

      // Wrap with confirmation marker when the runtime is asking for ANOTHER
      // confirmation (e.g. multi-step task: gate #1 done, gate #2 awaiting).
      // Without the marker the UI renders plain text and the user has to type
      // "lanjut" manually, which breaks the multi-task UX.
      final isNextConfirm =
          response.state == AgentRuntimeState.waitingConfirmation;
      await history.addMessage(
        agentId,
        ChatMessage(
          role: 'assistant',
          content: isNextConfirm
              ? '🔐 ${response.finalMessage}\n\n[[CONFIRMATION_REQUIRED]]'
              : response.finalMessage,
          actions: response.actions,
        ),
      );

      _set(agentId, sessionFor(agentId).copyWith(
        isRunning: false,
        debugMessages: [],
        // Store the next pending action so the Confirm tap finds the tool.
        pendingTool: response.pendingTool,
        pendingToolArgs: response.pendingToolArgs,
        lastReplyAt: DateTime.now(),
        clearNarrative: true,
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
        clearNarrative: true,
      ));
    }
  }

  /// Reject a pending tool.
  Future<void> reject(String agentId) async {
    // Reuse the language captured when the pending action was created so
    // the rejection message stays consistent with the prompt the user saw.
    final pending = engine.getPendingAction(agentId);
    final lang = pending?.languageCode ?? 'en';
    final rejectMsg = I18nFallback.get('cancel', lang);
    await history.addMessage(
      agentId,
      ChatMessage(role: 'assistant', content: rejectMsg),
    );
    _set(agentId, sessionFor(agentId).copyWith(
      isRunning: false,
      debugMessages: [],
      clearPending: true,
      lastReplyAt: DateTime.now(),
      clearNarrative: true,
    ));
  }

  /// Extract LLM-supplied narrative payload from a [RuntimeEvent].
  /// Returns null when the event is not a narrative event.
  String? _narrativeFromEvent(RuntimeEvent event) {
    if (event.type != 'narrative') return null;
    final msg = event.message.trim();
    return msg.isEmpty ? null : msg;
  }

  /// Detect the user's language for narrative localization.
  /// Falls back to the engine-level languageCode if detection is uncertain.
  String _languageForUserMessage(String message) {
    if (message.trim().isEmpty) return engine.languageCode;
    final detector = LanguageDetector();
    final detected = detector.detect(
      userMessage: message,
      fallbackCode: engine.languageCode,
    );
    return detected.confidence >= 0.5 ? detected.code : engine.languageCode;
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
