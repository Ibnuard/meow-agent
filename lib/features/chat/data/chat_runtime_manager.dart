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
import 'chat_notification_service.dart';
import 'chat_runtime_log_service.dart';
import 'unread_service.dart';

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
      narrativeMessage: clearNarrative
          ? null
          : (narrativeMessage ?? this.narrativeMessage),
    );
  }
}

/// Owns active per-agent runtime sessions. Outlives the chat screen.
class ChatRuntimeManager extends ChangeNotifier {
  ChatRuntimeManager({
    required this.engine,
    required this.history,
    required this.runtimeLog,
    required this.ref,
  });

  final AgentRuntimeEngine engine;
  final ChatHistoryService history;
  final ChatRuntimeLogService runtimeLog;
  final Ref ref;

  final Map<String, ChatRuntimeSession> _sessions = {};
  final Map<String, Future<void>> _runtimeLogWrites = {};

  /// Agents whose current in-flight send was cancelled by the user.
  /// Used to suppress trailing events and empty responses that arrive
  /// after the engine.run() Future finally resolves post-cancellation.
  final Set<String> _cancelledSends = {};

  ChatRuntimeSession sessionFor(String agentId) =>
      _sessions[agentId] ?? ChatRuntimeSession(agentId: agentId);

  /// True if any agent has an in-flight runtime session.
  /// Used by the home FAB to show a live activity indicator.
  bool get hasAnyRunning => _sessions.values.any((s) => s.isRunning);

  void _set(String agentId, ChatRuntimeSession s) {
    _sessions[agentId] = s;
    notifyListeners();
  }

  void _queueRuntimeLog(String agentId, Future<void> Function() write) {
    final previous = _runtimeLogWrites[agentId] ?? Future<void>.value();
    final next = previous
        .catchError((Object error, StackTrace stackTrace) {
          debugPrint('Runtime log write failed: $error');
        })
        .then((_) => write())
        .catchError((Object error, StackTrace stackTrace) {
          debugPrint('Runtime log write failed: $error');
        });
    _runtimeLogWrites[agentId] = next;
  }

  Future<void> _flushRuntimeLog(String agentId) async {
    final pending = _runtimeLogWrites[agentId];
    if (pending == null) return;
    await pending;
    if (identical(_runtimeLogWrites[agentId], pending)) {
      _runtimeLogWrites.remove(agentId);
    }
  }

  Future<void> _startRuntimeLog({
    required String agentId,
    required String userMessage,
  }) async {
    await _flushRuntimeLog(agentId);
    try {
      await runtimeLog.startRun(agentId: agentId, userMessage: userMessage);
    } catch (e) {
      debugPrint('Runtime log start failed: $e');
    }
  }

  Future<ProviderConfig?> _resolveProvider(String agentId) async {
    final agents = ref.read(agentListProvider);
    final providers = ref.read(providerListProvider).value ?? [];
    final agent =
        agents.where((a) => a.id == agentId).firstOrNull ??
        (agents.isNotEmpty ? agents.first : null);
    if (agent == null) return null;
    final provider = providers
        .where((p) => p.id == agent.providerId)
        .firstOrNull;
    if (provider == null) return null;
    return provider.copyWith(model: provider.effectiveModel(agent.model));
  }

  Future<void> send({
    required String agentId,
    required String userMessage,
    required List<ChatMessage> recentMessages,
    List<AttachedFile> attachments = const [],
  }) async {
    final provider = await _resolveProvider(agentId);

    // Persist user message with attached file names so the bubble survives
    // history reload. The runtime receives the raw userMessage + attachments
    // separately, so the 📎 suffix is display-only and does not pollute LLM
    // context.
    final displayContent = attachments.isEmpty
        ? userMessage
        : '$userMessage\n\n📎 ${attachments.map((a) => a.name).join(", ")}';
    final imageExtensions = const {'.png','.jpg','.jpeg','.webp','.gif','.bmp','.heic'};
    final imagePaths = attachments
        .where((a) {
          final dot = a.name.lastIndexOf('.');
          if (dot < 0) return false;
          return imageExtensions.contains(a.name.substring(dot).toLowerCase());
        })
        .map((a) => a.path)
        .toList();
    final userMsg = ChatMessage(role: 'user', content: displayContent, imagePaths: imagePaths);
    await history.addMessage(agentId, userMsg);

    if (provider == null || !provider.isComplete) {
      // Fallback: agent's provider disappeared mid-flight → surface with action.
      final agents = ref.read(agentListProvider);
      final agent = agents.where((a) => a.id == agentId).firstOrNull;
      final agentName = agent?.name ?? agentId;
      final lang = _languageForUserMessage(userMessage);
      final isId = lang == 'id';
      final fallbackMsg = ChatMessage(
        role: 'assistant',
        content: isId
            ? '⚠️ Agen "$agentName" memerlukan provider dan model. '
                'Provider mungkin telah dihapus. Silakan atur ulang di halaman Provider.'
            : '⚠️ Agent "$agentName" needs a valid provider and model. '
                'The provider may have been removed. Please reconfigure in the Provider page.',
        actions: [
          ResultAction(
            label: isId ? 'Atur Provider' : 'Manage Providers',
            icon: 'dns_outlined',
            type: 'navigate',
            target: '/providers',
          ),
        ],
      );
      await history.addMessage(agentId, fallbackMsg);
      await UnreadService.instance.increment(agentId);
      _set(
        agentId,
        sessionFor(agentId).copyWith(
          isRunning: false,
          debugMessages: [],
          lastReplyAt: DateTime.now(),
          clearNarrative: true,
        ),
      );
      return;
    }

    // Reset cancellation flag from any previous send.
    _cancelledSends.remove(agentId);

    _set(
      agentId,
      sessionFor(agentId).copyWith(
        isRunning: true,
        debugMessages: [],
        clearPending: true,
        narrativeMessage: NarrativeNarrator.narrate(
          'understanding',
          _languageForUserMessage(userMessage),
        ),
      ),
    );

    final debugMode = ref.read(llmDebugModeProvider);
    if (debugMode) {
      await _startRuntimeLog(agentId: agentId, userMessage: userMessage);
    }

    final agents = ref.read(agentListProvider);
    final agent =
        agents.where((a) => a.id == agentId).firstOrNull ??
        (agents.isNotEmpty ? agents.first : null);
    final agentName = agent?.name ?? '';

    try {
      final response = await engine.run(
        AgentRuntimeRequest(
          agentId: agentId,
          agentName: agentName,
          userMessage: userMessage,
          recentMessages: recentMessages,
          attachments: attachments,
        ),
        provider: provider,
        onEvent: (event) {
          // Drop trailing events after cancellation. The engine's loop is
          // cooperative and may emit a few more events before bailing out;
          // we don't want them polluting the chat after the cancel message.
          if (_cancelledSends.contains(agentId)) return;

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
            _queueRuntimeLog(
              agentId,
              () => runtimeLog.appendEvent(agentId: agentId, event: event),
            );
            final s = sessionFor(agentId);
            _set(
              agentId,
              s.copyWith(
                debugMessages: [
                  ...s.debugMessages,
                  ChatMessage(
                    role: 'assistant',
                    content: '⚙️ ${event.message}',
                  ),
                ],
              ),
            );
          }
        },
      );

      if (debugMode) {
        await _flushRuntimeLog(agentId);
      }

      // If cancelled during the run, the cancel message has already been
      // posted by cancelActive() and isRunning has been cleared. Don't
      // overwrite that with the empty/aborted response from engine.run().
      if (_cancelledSends.contains(agentId)) {
        if (debugMode) {
          await _flushRuntimeLog(agentId);
        }
        _cancelledSends.remove(agentId);
        return;
      }

      final isConfirm = response.state == AgentRuntimeState.waitingConfirmation;
      final replyMsg = ChatMessage(
        role: 'assistant',
        content: isConfirm
            ? '🔐 ${response.finalMessage}\n\n[[CONFIRMATION_REQUIRED]]'
            : response.finalMessage,
        actions: response.actions,
      );
      await history.addMessage(agentId, replyMsg);
      await UnreadService.instance.increment(agentId);
      _maybeNotify(agentId: agentId, agentName: agentName, reply: replyMsg);

      _set(
        agentId,
        sessionFor(agentId).copyWith(
          isRunning: false,
          debugMessages: [],
          pendingTool: response.pendingTool,
          pendingToolArgs: response.pendingToolArgs,
          lastReplyAt: DateTime.now(),
          clearNarrative: true,
        ),
      );
    } catch (e) {
      // Don't post an error if the user explicitly cancelled.
      if (_cancelledSends.contains(agentId)) {
        if (debugMode) {
          await _flushRuntimeLog(agentId);
        }
        _cancelledSends.remove(agentId);
        return;
      }
      if (debugMode) {
        _queueRuntimeLog(
          agentId,
          () => runtimeLog.appendRawEvent(
            agentId: agentId,
            type: 'error',
            message: 'Chat runtime failed',
            data: {'error': e.toString()},
          ),
        );
        await _flushRuntimeLog(agentId);
      }
      await history.addMessage(
        agentId,
        ChatMessage(role: 'assistant', content: 'Error: $e'),
      );
      await UnreadService.instance.increment(agentId);
      _set(
        agentId,
        sessionFor(agentId).copyWith(
          isRunning: false,
          debugMessages: [],
          lastReplyAt: DateTime.now(),
          clearNarrative: true,
        ),
      );
    }
  }

  Future<void> confirm(String agentId) async {
    final s = sessionFor(agentId);
    final tool = s.pendingTool;
    if (tool == null) return;

    final provider = await _resolveProvider(agentId);
    if (provider == null || !provider.isComplete) {
      // Fallback: provider disappeared after confirmation was requested.
      final lang = engine.languageCode;
      final isId = lang == 'id';
      final fallbackMsg = ChatMessage(
        role: 'assistant',
        content: isId
            ? '⚠️ Provider tidak tersedia — aksi dibatalkan. Silakan atur ulang di halaman Provider.'
            : '⚠️ Provider unavailable — action cancelled. Please reconfigure in the Provider page.',
        actions: [
          ResultAction(
            label: isId ? 'Atur Provider' : 'Manage Providers',
            icon: 'dns_outlined',
            type: 'navigate',
            target: '/providers',
          ),
        ],
      );
      await history.addMessage(agentId, fallbackMsg);
      _set(
        agentId,
        s.copyWith(
          isRunning: false,
          debugMessages: [],
          clearPending: true,
          lastReplyAt: DateTime.now(),
          clearNarrative: true,
        ),
      );
      return;
    }

    _set(
      agentId,
      s.copyWith(
        isRunning: true,
        debugMessages: [],
        clearPending: true,
        narrativeMessage: NarrativeNarrator.narrate(
          'executing',
          engine.languageCode,
        ),
      ),
    );

    final debugMode = ref.read(llmDebugModeProvider);
    if (debugMode) {
      _queueRuntimeLog(
        agentId,
        () => runtimeLog.appendRawEvent(
          agentId: agentId,
          type: 'confirmation',
          message: 'User confirmed pending tool: $tool',
          data: {'tool': tool, 'args': s.pendingToolArgs ?? {}},
        ),
      );
    }

    final agents = ref.read(agentListProvider);
    final agent =
        agents.where((a) => a.id == agentId).firstOrNull ??
        (agents.isNotEmpty ? agents.first : null);
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
            _queueRuntimeLog(
              agentId,
              () => runtimeLog.appendEvent(agentId: agentId, event: event),
            );
            final cur = sessionFor(agentId);
            _set(
              agentId,
              cur.copyWith(
                debugMessages: [
                  ...cur.debugMessages,
                  ChatMessage(
                    role: 'assistant',
                    content: '⚙️ ${event.message}',
                  ),
                ],
              ),
            );
          }
        },
      );

      if (debugMode) {
        await _flushRuntimeLog(agentId);
      }

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
      await UnreadService.instance.increment(agentId);
      _maybeNotify(
        agentId: agentId,
        agentName: agentName,
        reply: ChatMessage(
          role: 'assistant',
          content: response.finalMessage,
        ),
      );

      _set(
        agentId,
        sessionFor(agentId).copyWith(
          isRunning: false,
          debugMessages: [],
          // Store the next pending action so the Confirm tap finds the tool.
          pendingTool: response.pendingTool,
          pendingToolArgs: response.pendingToolArgs,
          lastReplyAt: DateTime.now(),
          clearNarrative: true,
        ),
      );
    } catch (e) {
      if (debugMode) {
        _queueRuntimeLog(
          agentId,
          () => runtimeLog.appendRawEvent(
            agentId: agentId,
            type: 'error',
            message: 'Confirmed runtime failed',
            data: {'error': e.toString()},
          ),
        );
        await _flushRuntimeLog(agentId);
      }
      await history.addMessage(
        agentId,
        ChatMessage(role: 'assistant', content: 'Error: $e'),
      );
      await UnreadService.instance.increment(agentId);
      _set(
        agentId,
        sessionFor(agentId).copyWith(
          isRunning: false,
          debugMessages: [],
          lastReplyAt: DateTime.now(),
          clearNarrative: true,
        ),
      );
    }
  }

  /// Reject a pending tool.
  Future<void> reject(String agentId) async {
    // Reuse the language captured when the pending action was created so
    // the rejection message stays consistent with the prompt the user saw.
    final pending = engine.getPendingAction(agentId);
    final lang = pending?.languageCode ?? 'en';
    final debugMode = ref.read(llmDebugModeProvider);
    if (debugMode) {
      _queueRuntimeLog(
        agentId,
        () => runtimeLog.appendRawEvent(
          agentId: agentId,
          type: 'confirmation',
          message: 'User rejected pending tool',
          data: {if (pending != null) 'tool': pending.toolName},
        ),
      );
      await _flushRuntimeLog(agentId);
    }
    await engine.abortActiveTask(agentId);
    final rejectMsg = I18nFallback.get('cancel', lang);
    await history.addMessage(
      agentId,
      ChatMessage(role: 'assistant', content: rejectMsg),
    );
    _set(
      agentId,
      sessionFor(agentId).copyWith(
        isRunning: false,
        debugMessages: [],
        clearPending: true,
        lastReplyAt: DateTime.now(),
        clearNarrative: true,
      ),
    );
  }

  /// Cancel an in-flight runtime task (user pressed stop button).
  Future<void> cancelActive(String agentId) async {
    final s = sessionFor(agentId);
    if (!s.isRunning) return;
    _cancelledSends.add(agentId);
    final debugMode = ref.read(llmDebugModeProvider);
    if (debugMode) {
      _queueRuntimeLog(
        agentId,
        () => runtimeLog.appendRawEvent(
          agentId: agentId,
          type: 'cancelled',
          message: 'User cancelled the active runtime task',
        ),
      );
      await _flushRuntimeLog(agentId);
    }
    await engine.abortActiveTask(agentId);
    await history.addMessage(
      agentId,
      ChatMessage(role: 'assistant', content: '⏹️ Proses dibatalkan.'),
    );
    _set(
      agentId,
      s.copyWith(
        isRunning: false,
        debugMessages: [],
        clearPending: true,
        lastReplyAt: DateTime.now(),
        clearNarrative: true,
      ),
    );
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

  /// Fire a local notification for a new agent reply, but ONLY when the user
  /// is NOT currently viewing that agent's chat screen.
  void _maybeNotify({
    required String agentId,
    required String agentName,
    required ChatMessage reply,
  }) {
    if (UnreadService.instance.isActive(agentId)) return;
    final body = _stripMarkdown(reply.content);
    final preview = body.length > 120 ? '${body.substring(0, 120)}…' : body;
    ChatNotificationService.instance.show(
      agentId: agentId,
      agentName: agentName,
      preview: preview,
    );
  }

  /// Strip basic markdown for notification body preview.
  static String _stripMarkdown(String text) {
    return text
        .replaceAll(RegExp(r'#+\s*'), '')
        .replaceAll(RegExp(r'[*_~`]'), '')
        .replaceAll('\n', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}

final chatRuntimeManagerProvider = ChangeNotifierProvider<ChatRuntimeManager>((
  ref,
) {
  return ChatRuntimeManager(
    engine: ref.watch(agentRuntimeEngineProvider),
    history: ref.watch(chatHistoryServiceProvider),
    runtimeLog: ref.watch(chatRuntimeLogServiceProvider),
    ref: ref,
  );
});
