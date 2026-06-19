import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/agent_runtime/i18n_fallback.dart';
import '../../../services/agent_runtime/language_detector.dart';
import '../../../services/agent_runtime/narrative_narrator.dart';
import '../../../services/agent_runtime/runtime_engine.dart';
import '../../../services/agent_runtime/runtime_models.dart';
import '../../../services/agent_runtime/task_ledger.dart';
import '../../../services/llm/llm_error_mapper.dart';
import '../../agents/data/agent_repository.dart';
import '../../providers/data/provider_config.dart';
import '../../providers/data/provider_repository.dart';
import '../../settings/data/llm_debug_provider.dart';
import '../../settings/data/notification_sound_provider.dart';
import 'chat_history_service.dart';
import 'chat_messages_notifier.dart';
import 'chat_notification_service.dart';
import 'chat_runtime_log_service.dart';
import 'chat_session_service.dart';
import 'token_usage_service.dart';
import 'unread_service.dart';

const _taskLedgerSentinelPrefix = '[[TASK_LEDGER]]';

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
    this.narrativeTrail = const [],
    this.activeTaskLedger,
    this.liveCheckpoints = const [],
    this.lastPersistedMessages = const [],
  });

  final String agentId;
  final bool isRunning;
  final List<ChatMessage> debugMessages;
  final String? pendingTool;
  final Map<String, dynamic>? pendingToolArgs;
  final DateTime? lastReplyAt;

  /// Replace-only pre-action narrative shown with the thinking indicator
  /// while [isRunning]. Completed outcomes live in streamed chat bubbles.
  final List<String> narrativeTrail;

  /// Convenience: the latest narrative, or null if trail is empty.
  String? get narrativeMessage =>
      narrativeTrail.isEmpty ? null : narrativeTrail.last;

  /// Live multi-goal task ledger for complex chat requests.
  final TaskLedger? activeTaskLedger;

  /// Phase-complete semantic checkpoints for the active run. Rendered above
  /// the ledger; technical events and narrator updates never enter this list.
  final List<ChatMessage> liveCheckpoints;

  /// Messages persisted by the latest completed runtime transition. The UI can
  /// upsert these directly instead of reloading the latest page from SQLite.
  final List<ChatMessage> lastPersistedMessages;

  ChatRuntimeSession copyWith({
    bool? isRunning,
    List<ChatMessage>? debugMessages,
    String? pendingTool,
    Map<String, dynamic>? pendingToolArgs,
    DateTime? lastReplyAt,
    String? narrativeMessage,
    List<String>? narrativeTrail,
    TaskLedger? activeTaskLedger,
    List<ChatMessage>? liveCheckpoints,
    List<ChatMessage>? lastPersistedMessages,
    bool clearPending = false,
    bool clearNarrative = false,
    bool clearTaskLedger = false,
    bool clearLiveCheckpoints = false,
  }) {
    var trail = narrativeTrail ?? this.narrativeTrail;
    if (clearNarrative) {
      trail = const [];
    } else if (narrativeMessage != null) {
      // Pre-action intent is replace-only; completed outcomes are persisted as
      // streamed bubbles, so narrator history would duplicate the timeline.
      trail = [narrativeMessage];
    }
    return ChatRuntimeSession(
      agentId: agentId,
      isRunning: isRunning ?? this.isRunning,
      debugMessages: debugMessages ?? this.debugMessages,
      pendingTool: clearPending ? null : (pendingTool ?? this.pendingTool),
      pendingToolArgs: clearPending
          ? null
          : (pendingToolArgs ?? this.pendingToolArgs),
      lastReplyAt: lastReplyAt ?? this.lastReplyAt,
      narrativeTrail: trail,
      activeTaskLedger: clearTaskLedger
          ? null
          : (activeTaskLedger ?? this.activeTaskLedger),
      liveCheckpoints: clearLiveCheckpoints
          ? const []
          : (liveCheckpoints ?? this.liveCheckpoints),
      lastPersistedMessages:
          lastPersistedMessages ?? this.lastPersistedMessages,
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
  final Map<String, Future<void>> _streamBubbleWrites = {};
  final Map<String, List<ChatMessage>> _streamedMessages = {};
  final Map<String, Set<String>> _persistedStreamEventIds = {};
  final Map<String, Future<void>> _sendQueues = {};

  /// Agents whose current in-flight send was cancelled by the user.
  /// Used to suppress trailing events and empty responses that arrive
  /// after the engine.run() Future finally resolves post-cancellation.
  final Set<String> _cancelledSends = {};

  ChatRuntimeSession sessionFor(String agentId) =>
      _sessions[agentId] ?? ChatRuntimeSession(agentId: agentId);

  /// Clear UI-side runtime state when a slash command starts a fresh context.
  ///
  /// The engine reset wipes pending actions, ledgers, and memory. This method
  /// keeps the long-lived chat manager in sync so stale pending buttons,
  /// narrative bubbles, or task ledgers cannot survive `/clear`, `/reset`, or
  /// `/resume`. If a run is still resolving, mark it as cancelled so its late
  /// result is suppressed by [_runSend].
  Future<void> resetLocalStateForFreshSession(String agentId) async {
    final current = sessionFor(agentId);
    if (current.isRunning) {
      _cancelledSends.add(agentId);
    } else {
      _cancelledSends.remove(agentId);
    }
    await _flushRuntimeLog(agentId);
    _set(agentId, ChatRuntimeSession(agentId: agentId));
  }

  /// True if any agent has an in-flight runtime session.
  /// Used by the home FAB to show a live activity indicator.
  bool get hasAnyRunning => _sessions.values.any((s) => s.isRunning);

  /// ID of the first agent that is currently running, or null.
  String? get runningAgentId => _sessions.entries
      .where((e) => e.value.isRunning)
      .map((e) => e.key)
      .firstOrNull;

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

  void _queueStreamBubble({
    required String agentId,
    required String runId,
    required RuntimeEvent event,
  }) {
    final seen = _persistedStreamEventIds.putIfAbsent(
      agentId,
      () => <String>{},
    );
    if (!seen.add(event.id)) return;
    final previous = _streamBubbleWrites[agentId] ?? Future<void>.value();
    final next = previous
        .catchError((Object error, StackTrace stackTrace) {
          debugPrint('Stream bubble write failed: $error');
        })
        .then((_) => _persistStreamBubble(agentId, runId, event))
        .catchError((Object error, StackTrace stackTrace) {
          debugPrint('Stream bubble write failed: $error');
        });
    _streamBubbleWrites[agentId] = next;
  }

  Future<void> _persistStreamBubble(
    String agentId,
    String runId,
    RuntimeEvent event,
  ) async {
    final data = event.data ?? const <String, dynamic>{};
    final evidenceRefs = (data['evidence_refs'] as List? ?? const [])
        .map((value) => value.toString())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    final message = ChatMessage(
      role: 'assistant',
      content: event.message.trim(),
      kind: ChatMessageKind.fromLabel(data['kind']?.toString()),
      runId: runId,
      phase: data['phase']?.toString(),
      evidenceRefs: evidenceRefs,
      contextPolicy: ChatContextPolicy.fromLabel(
        data['context_policy']?.toString(),
      ),
    );
    if (message.content.isEmpty) return;
    final id = await history.addMessage(agentId, message);
    final persisted = message.copyWith(id: id);
    final runMessages = _streamedMessages.putIfAbsent(agentId, () => []);
    runMessages.add(persisted);
    final current = sessionFor(agentId);
    _set(
      agentId,
      current.copyWith(
        liveCheckpoints: List<ChatMessage>.unmodifiable(runMessages),
      ),
    );
  }

  Future<void> _flushStreamBubbles(String agentId) async {
    final pending = _streamBubbleWrites[agentId];
    if (pending == null) return;
    await pending;
    if (identical(_streamBubbleWrites[agentId], pending)) {
      _streamBubbleWrites.remove(agentId);
    }
  }

  static bool _sameBubbleContent(String left, String right) =>
      left.trim().replaceAll(RegExp(r'\s+'), ' ') ==
      right
          .replaceAll('\n\n[[CONFIRMATION_REQUIRED]]', '')
          .replaceAll('[[CONFIRMATION_REQUIRED]]', '')
          .trim()
          .replaceAll(RegExp(r'\s+'), ' ');

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
    // Wait for the agent list and provider list to finish their initial
    // async loads. On a cold open these notifiers start empty and populate
    // from SQLite asynchronously; without this await, the lookup below
    // would silently see empty lists and bail out as "no provider".
    await ref.read(agentListProvider.notifier).ready;
    await ref.read(providerListProvider.notifier).load();

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
    ChatMessage? persistedUserMessage,
  }) {
    final previous = _sendQueues[agentId] ?? Future<void>.value();
    late final Future<void> queued;
    queued = previous
        .catchError((Object error, StackTrace stackTrace) {
          debugPrint('Queued chat send failed before next turn: $error');
        })
        .then(
          (_) => _runSend(
            agentId: agentId,
            userMessage: userMessage,
            recentMessages: recentMessages,
            attachments: attachments,
            persistedUserMessage: persistedUserMessage,
          ),
        );
    late final Future<void> tracked;
    tracked = queued.whenComplete(() {
      if (identical(_sendQueues[agentId], tracked)) {
        _sendQueues.remove(agentId);
      }
    });
    _sendQueues[agentId] = tracked;
    return tracked;
  }

  Future<void> _runSend({
    required String agentId,
    required String userMessage,
    required List<ChatMessage> recentMessages,
    List<AttachedFile> attachments = const [],
    ChatMessage? persistedUserMessage,
  }) async {
    final provider = await _resolveProvider(agentId);

    // Persist user message with attached file names so the bubble survives
    // history reload. The runtime receives the raw userMessage + attachments
    // separately, so the 📎 suffix is display-only and does not pollute LLM
    // context.
    final displayContent = attachments.isEmpty
        ? userMessage
        : '$userMessage\n\n📎 ${attachments.map((a) => a.name).join(", ")}';
    final imageExtensions = const {
      '.png',
      '.jpg',
      '.jpeg',
      '.webp',
      '.gif',
      '.bmp',
      '.heic',
    };
    final imagePaths = attachments
        .where((a) {
          final dot = a.name.lastIndexOf('.');
          if (dot < 0) return false;
          return imageExtensions.contains(a.name.substring(dot).toLowerCase());
        })
        .map((a) => a.path)
        .toList();
    var userMsg =
        persistedUserMessage ??
        ChatMessage(
          role: 'user',
          content: displayContent,
          imagePaths: imagePaths,
          deliveryStatus: ChatMessageDeliveryStatus.sending,
        );
    if (userMsg.id == null) {
      final id = await history.addMessage(agentId, userMsg);
      userMsg = userMsg.copyWith(id: id);
    } else {
      userMsg = userMsg.copyWith(
        deliveryStatus:
            userMsg.deliveryStatus == ChatMessageDeliveryStatus.pending
            ? ChatMessageDeliveryStatus.sending
            : userMsg.deliveryStatus,
        clearErrorMessage: true,
      );
      await history.updateMessage(userMsg);
    }

    if (provider == null || !provider.isComplete) {
      // Fallback: agent's provider disappeared mid-flight → surface with action.
      final lang = _languageForUserMessage(userMessage);
      final sentUserMsg = userMsg.copyWith(
        deliveryStatus: ChatMessageDeliveryStatus.sent,
        clearErrorMessage: true,
      );
      await history.updateMessage(sentUserMsg);
      final fallbackMsg = ChatMessage(
        role: 'assistant',
        content: I18nFallback.get('provider_missing', lang),
        actions: [
          ResultAction(
            label: I18nFallback.get('manage_providers', lang),
            icon: 'dns_outlined',
            type: 'navigate',
            target: '/providers',
          ),
        ],
      );
      final fallbackId = await history.addMessage(agentId, fallbackMsg);
      final persistedFallback = fallbackMsg.copyWith(id: fallbackId);
      await UnreadService.instance.increment(agentId);
      _set(
        agentId,
        sessionFor(agentId).copyWith(
          isRunning: false,
          debugMessages: [],
          lastReplyAt: DateTime.now(),
          clearNarrative: true,
          clearLiveCheckpoints: true,
          lastPersistedMessages: [sentUserMsg, persistedFallback],
        ),
      );
      return;
    }

    // Reset cancellation flag from any previous send.
    _cancelledSends.remove(agentId);
    _streamedMessages[agentId] = [];
    _persistedStreamEventIds[agentId] = <String>{};

    _set(
      agentId,
      sessionFor(agentId).copyWith(
        isRunning: true,
        debugMessages: [],
        clearPending: true,
        clearLiveCheckpoints: true,
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
      var runtimeRecentMessages = recentMessages;
      try {
        // Only feed persisted messages for the active session. The chat UI may
        // still show an in-memory transcript after /reset, but /reset clears
        // this session's stored rows; /new-session and /resume switch ids.
        final sessionId = ref
            .read(chatSessionServiceProvider)
            .currentSessionId(agentId);
        final latest = await history.loadLatest(agentId, sessionId: sessionId);
        runtimeRecentMessages = latest
            .where(
              (m) =>
                  (userMsg.id == null || m.id != userMsg.id) &&
                  (userMsg.clientId == null || m.clientId != userMsg.clientId),
            )
            .toList();
      } catch (_) {}

      final response = await engine.run(
        AgentRuntimeRequest(
          agentId: agentId,
          agentName: agentName,
          userMessage: userMessage,
          recentMessages: runtimeRecentMessages,
          attachments: attachments,
        ),
        provider: provider,
        onEvent: (event) {
          // Drop trailing events after cancellation. The engine's loop is
          // cooperative and may emit a few more events before bailing out;
          // we don't want them polluting the chat after the cancel message.
          if (_cancelledSends.contains(agentId)) return;

          if (event.type == 'stream_bubble') {
            _queueStreamBubble(
              agentId: agentId,
              runId: 'run-${userMsg.id ?? userMsg.clientId ?? event.id}',
              event: event,
            );
          }

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

          final ledger = _taskLedgerFromEvent(event);
          if (ledger != null) {
            final s = sessionFor(agentId);
            _set(agentId, s.copyWith(activeTaskLedger: ledger));
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
      await _flushStreamBubbles(agentId);

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
      final historicalLedger = sessionFor(agentId).activeTaskLedger;
      final sentUserMsg = userMsg.copyWith(
        deliveryStatus: ChatMessageDeliveryStatus.sent,
        clearErrorMessage: true,
      );
      await history.updateMessage(sentUserMsg);
      final streamedMessages = List<ChatMessage>.from(
        _streamedMessages[agentId] ?? const [],
      );
      final persistedMessages = <ChatMessage>[sentUserMsg, ...streamedMessages];
      if (historicalLedger != null &&
          historicalLedger.goalTree.subgoals.length > 1 &&
          !isConfirm) {
        final ledgerMsg = ChatMessage(
          role: 'assistant',
          content:
              '$_taskLedgerSentinelPrefix${jsonEncode(historicalLedger.toJson())}',
        );
        final ledgerId = await history.addMessage(agentId, ledgerMsg);
        persistedMessages.add(ledgerMsg.copyWith(id: ledgerId));
      }

      final streamedQuestion = response.state == AgentRuntimeState.askingUser
          ? streamedMessages
                .where(
                  (message) =>
                      message.kind == ChatMessageKind.decisionQuestion &&
                      _sameBubbleContent(message.content, replyMsg.content),
                )
                .lastOrNull
          : null;
      final ChatMessage persistedReply;
      if (streamedQuestion != null) {
        persistedReply = streamedQuestion;
      } else {
        final replyId = await history.addMessage(agentId, replyMsg);
        persistedReply = replyMsg.copyWith(id: replyId);
        persistedMessages.add(persistedReply);
      }
      await UnreadService.instance.increment(agentId);

      // If system.rtb was called with a message argument, the content was
      // deferred (not persisted mid-loop) so it lands AFTER the task ledger
      // and the generic "done" reply in the timeline — appearing as the
      // newest message, which is what the user expects.
      final rtbMessageContent = _extractRtbPendingMessage(response);
      if (rtbMessageContent != null) {
        final rtbMsg = ChatMessage(
          role: 'assistant',
          content: rtbMessageContent,
        );
        final rtbId = await history.addMessage(agentId, rtbMsg);
        persistedMessages.add(rtbMsg.copyWith(id: rtbId));
        await UnreadService.instance.increment(agentId);
      }

      // If chat.send was called during the run, its messages were inserted
      // directly into the DB but not into our persistedMessages list. Reload
      // from DB to pick them up so the UI shows the full result.
      final hasChatSend = response.events.any(
        (e) =>
            e.type == 'tool_result' &&
            e.data?['success'] == true &&
            e.data?['tool'] == 'chat.send',
      );
      if (hasChatSend) {
        final sessionId = ref
            .read(chatSessionServiceProvider)
            .currentSessionId(agentId);
        final latestFromDb = await history.loadLatest(
          agentId,
          sessionId: sessionId,
        );
        // Replace persistedMessages with the full DB state so the UI
        // gets everything including chat.send messages.
        persistedMessages
          ..clear()
          ..addAll(latestFromDb);
      }

      _maybeNotify(
        agentId: agentId,
        agentName: agentName,
        reply: persistedReply,
        forceNotify: historicalLedger != null,
      );
      // Persist cumulative token usage stats for this agent.
      ref.read(tokenUsageServiceProvider).saveFromSession(agentId);

      _set(
        agentId,
        sessionFor(agentId).copyWith(
          isRunning: false,
          debugMessages: [],
          pendingTool: response.pendingTool,
          pendingToolArgs: response.pendingToolArgs,
          lastReplyAt: DateTime.now(),
          clearNarrative: true,
          clearTaskLedger: true,
          clearLiveCheckpoints: true,
          lastPersistedMessages: persistedMessages,
        ),
      );
    } catch (e) {
      await _flushStreamBubbles(agentId);
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
      final sentUserMsg = userMsg.copyWith(
        deliveryStatus: ChatMessageDeliveryStatus.sent,
        clearErrorMessage: true,
      );
      await history.updateMessage(sentUserMsg);
      final errorMsg = ChatMessage(
        role: 'assistant',
        content: LlmErrorMapper.friendlyMessage(e, engine.languageCode),
      );
      final errorId = await history.addMessage(agentId, errorMsg);
      final persistedError = errorMsg.copyWith(id: errorId);
      await UnreadService.instance.increment(agentId);
      _maybeNotify(
        agentId: agentId,
        agentName: agentName,
        reply: persistedError,
        forceNotify: sessionFor(agentId).activeTaskLedger != null,
      );
      _set(
        agentId,
        sessionFor(agentId).copyWith(
          isRunning: false,
          debugMessages: [],
          lastReplyAt: DateTime.now(),
          clearNarrative: true,
          clearTaskLedger: true,
          clearLiveCheckpoints: true,
          lastPersistedMessages: [
            sentUserMsg,
            ...?_streamedMessages[agentId],
            persistedError,
          ],
        ),
      );
    }
  }

  /// Strip the `[[CONFIRMATION_REQUIRED]]` marker from the most-recent
  /// persisted confirmation message so the in-chat Accept/Reject card clears.
  ///
  /// The chat bubble renders its action row purely off the stored marker
  /// (meow_bubble.dart), independent of live pending state. When the user
  /// resolves a confirmation via the NOTIFICATION action buttons, the in-chat
  /// path (`handleConfirmation`, which deletes the message) never runs — so
  /// without this the card lingers, visible and tappable, looking unresolved.
  /// Called from both [confirm] and [reject] so every surface stays in sync.
  Future<void> _resolveConfirmationCard(String agentId) async {
    try {
      final sessionId = ref
          .read(chatSessionServiceProvider)
          .currentSessionId(agentId);
      final latest = await history.loadLatest(agentId, sessionId: sessionId);
      for (var i = latest.length - 1; i >= 0; i--) {
        final m = latest[i];
        if (m.role != 'assistant') continue;
        if (!m.content.contains('[[CONFIRMATION_REQUIRED]]')) continue;
        final cleaned = m.content
            .replaceAll('\n\n[[CONFIRMATION_REQUIRED]]', '')
            .replaceAll('[[CONFIRMATION_REQUIRED]]', '')
            .trim();
        if (m.id != null) {
          final cleanedMsg = m.copyWith(content: cleaned);
          // Persist the stripped text...
          await history.updateMessage(cleanedMsg);
          // ...AND upsert into the live in-memory list the chat screen renders
          // from. A DB-only update never reaches the UI (the screen reads the
          // chatMessagesProvider notifier state), which is why a notification
          // accept previously left the card on screen. Upsert matches by id and
          // replaces the marker version, clearing the Accept/Reject row.
          ref
              .read(chatMessagesProvider(agentId).notifier)
              .upsertMessage(cleanedMsg);
        }
        break; // only the latest pending confirmation can be active
      }
    } catch (_) {
      // Best-effort UI cleanup — never block the actual confirm/reject flow.
    }
  }

  Future<void> confirm(String agentId, {bool alwaysApprove = false}) async {
    final s = sessionFor(agentId);
    final tool = s.pendingTool;
    if (tool == null) return;
    // Resolve the lingering confirmation card BEFORE executing so a notification
    // accept clears the in-chat Accept/Reject row too (see helper doc).
    await _resolveConfirmationCard(agentId);

    final provider = await _resolveProvider(agentId);
    if (provider == null || !provider.isComplete) {
      // Fallback: provider disappeared after confirmation was requested.
      final lang = engine.languageCode;
      final fallbackMsg = ChatMessage(
        role: 'assistant',
        content: I18nFallback.get('provider_unavailable', lang),
        actions: [
          ResultAction(
            label: I18nFallback.get('manage_providers', lang),
            icon: 'dns_outlined',
            type: 'navigate',
            target: '/providers',
          ),
        ],
      );
      final fallbackId = await history.addMessage(agentId, fallbackMsg);
      final persistedFallback = fallbackMsg.copyWith(id: fallbackId);
      _set(
        agentId,
        s.copyWith(
          isRunning: false,
          debugMessages: [],
          clearPending: true,
          lastReplyAt: DateTime.now(),
          clearNarrative: true,
          lastPersistedMessages: [persistedFallback],
        ),
      );
      return;
    }

    _streamedMessages[agentId] = [];
    _persistedStreamEventIds[agentId] = <String>{};
    final confirmationRunId =
        'confirm-${DateTime.now().microsecondsSinceEpoch}';

    _set(
      agentId,
      s.copyWith(
        isRunning: true,
        debugMessages: [],
        clearPending: true,
        clearLiveCheckpoints: true,
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
        alwaysApprove: alwaysApprove,
        onEvent: (event) {
          if (event.type == 'stream_bubble') {
            _queueStreamBubble(
              agentId: agentId,
              runId: confirmationRunId,
              event: event,
            );
          }
          final llmNarrative = _narrativeFromEvent(event);
          if (llmNarrative != null) {
            final cur = sessionFor(agentId);
            _set(agentId, cur.copyWith(narrativeMessage: llmNarrative));
          }
          final ledger = _taskLedgerFromEvent(event);
          if (ledger != null) {
            final cur = sessionFor(agentId);
            _set(agentId, cur.copyWith(activeTaskLedger: ledger));
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
      await _flushStreamBubbles(agentId);

      // Wrap with confirmation marker when the runtime is asking for ANOTHER
      // confirmation (e.g. multi-step task: gate #1 done, gate #2 awaiting).
      // Without the marker the UI renders plain text and the user has to type
      // "lanjut" manually, which breaks the multi-task UX.
      final isNextConfirm =
          response.state == AgentRuntimeState.waitingConfirmation;
      final historicalLedger = sessionFor(agentId).activeTaskLedger;
      final persistedMessages = <ChatMessage>[...?_streamedMessages[agentId]];
      if (historicalLedger != null &&
          historicalLedger.goalTree.subgoals.length > 1 &&
          !isNextConfirm) {
        final ledgerMsg = ChatMessage(
          role: 'assistant',
          content:
              '$_taskLedgerSentinelPrefix${jsonEncode(historicalLedger.toJson())}',
        );
        final ledgerId = await history.addMessage(agentId, ledgerMsg);
        persistedMessages.add(ledgerMsg.copyWith(id: ledgerId));
      }

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
      // If system.rtb delivered a message during the RESUMED loop (this turn
      // went through an app.open confirmation, so finalize ran in
      // executeConfirmed — not _runSend), insert that summary as its own bubble.
      // Without this the rtb pending_chat_message is dropped on the confirm path
      // and the user sees only the generic recap. Guarded against duplicating
      // the reply when Edit 1 already promoted the delivered text to finalMessage.
      var rtbInserted = false;
      final rtbMessageContent = _extractRtbPendingMessage(response);
      if (rtbMessageContent != null &&
          rtbMessageContent != response.finalMessage) {
        final rtbMsg = ChatMessage(
          role: 'assistant',
          content: rtbMessageContent,
        );
        await history.addMessage(agentId, rtbMsg);
        await UnreadService.instance.increment(agentId);
        rtbInserted = true;
      }
      _maybeNotify(
        agentId: agentId,
        agentName: agentName,
        reply: ChatMessage(role: 'assistant', content: response.finalMessage),
        forceNotify: historicalLedger != null,
      );
      // Persist cumulative token usage stats for this agent.
      ref.read(tokenUsageServiceProvider).saveFromSession(agentId);
      final hasLedgerMsg =
          historicalLedger != null &&
          historicalLedger.goalTree.subgoals.length > 1 &&
          !isNextConfirm;
      persistedMessages
        ..clear()
        ..addAll(
          await history.loadLatest(
            agentId,
            limit:
                (_streamedMessages[agentId]?.length ?? 0) +
                (hasLedgerMsg ? 2 : 1) +
                (rtbInserted ? 1 : 0),
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
          clearTaskLedger: true,
          clearLiveCheckpoints: true,
          lastPersistedMessages: persistedMessages,
        ),
      );
    } catch (e) {
      await _flushStreamBubbles(agentId);
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
      final errorMsg = ChatMessage(
        role: 'assistant',
        content: LlmErrorMapper.friendlyMessage(e, engine.languageCode),
      );
      final errorId = await history.addMessage(agentId, errorMsg);
      final persistedError = errorMsg.copyWith(id: errorId);
      await UnreadService.instance.increment(agentId);
      _maybeNotify(
        agentId: agentId,
        agentName: agentName,
        reply: persistedError,
        forceNotify: sessionFor(agentId).activeTaskLedger != null,
      );
      _set(
        agentId,
        sessionFor(agentId).copyWith(
          isRunning: false,
          debugMessages: [],
          lastReplyAt: DateTime.now(),
          clearNarrative: true,
          clearTaskLedger: true,
          clearLiveCheckpoints: true,
          lastPersistedMessages: [
            ...?_streamedMessages[agentId],
            persistedError,
          ],
        ),
      );
    }
  }

  /// Reject a pending tool.
  Future<void> reject(String agentId) async {
    // Strip the lingering confirmation card marker (see [confirm] for why) so
    // a reject from the notification also clears the in-chat Accept/Reject row.
    await _resolveConfirmationCard(agentId);
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
    final persistedReject = ChatMessage(role: 'assistant', content: rejectMsg);
    final rejectId = await history.addMessage(agentId, persistedReject);
    final rejectBubble = persistedReject.copyWith(id: rejectId);
    _set(
      agentId,
      sessionFor(agentId).copyWith(
        isRunning: false,
        debugMessages: [],
        clearPending: true,
        lastReplyAt: DateTime.now(),
        clearNarrative: true,
        lastPersistedMessages: [rejectBubble],
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
    await _flushStreamBubbles(agentId);
    await engine.abortActiveTask(agentId);
    final cancelMsg = ChatMessage(
      role: 'assistant',
      content: I18nFallback.get('task_cancelled', engine.languageCode),
    );
    final cancelId = await history.addMessage(agentId, cancelMsg);
    final cancelBubble = cancelMsg.copyWith(id: cancelId);
    _set(
      agentId,
      s.copyWith(
        isRunning: false,
        debugMessages: [],
        clearPending: true,
        lastReplyAt: DateTime.now(),
        clearNarrative: true,
        clearTaskLedger: true,
        clearLiveCheckpoints: true,
        lastPersistedMessages: [...?_streamedMessages[agentId], cancelBubble],
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

  TaskLedger? _taskLedgerFromEvent(RuntimeEvent event) {
    if (event.type != 'task_ledger') return null;
    final raw = event.data?['ledger'];
    if (raw is! Map) return null;
    try {
      return TaskLedger.fromJson(raw.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
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

  /// Extract the deferred chat message content from a successful system.rtb
  /// tool result, if any. Returns null when the run did not include an
  /// rtb-with-message call.
  ///
  /// system.rtb stores the user-facing summary in `data.pending_chat_message`
  /// instead of persisting it mid-loop, so the caller can insert it AFTER
  /// the task ledger — the chronological position users expect.
  String? _extractRtbPendingMessage(AgentRuntimeResponse response) {
    for (final event in response.events) {
      if (event.type != 'tool_result') continue;
      if (event.data?['tool'] != 'system.rtb') continue;
      if (event.data?['success'] != true) continue;
      final inner = event.data?['data'];
      if (inner is! Map) continue;
      final pending = inner['pending_chat_message'];
      if (pending is String && pending.trim().isNotEmpty) {
        return pending.trim();
      }
    }
    return null;
  }

  /// Fire a local notification for a new agent reply, but ONLY when the user
  /// is NOT currently viewing that agent's chat screen.
  /// When [forceNotify] is true (e.g. app agent tasks where the user is in
  /// another app), bypass the isActive check.
  void _maybeNotify({
    required String agentId,
    required String agentName,
    required ChatMessage reply,
    bool forceNotify = false,
  }) {
    if (!forceNotify && UnreadService.instance.isActive(agentId)) return;
    final body = _stripMarkdown(reply.content);
    final preview = body.length > 120 ? '${body.substring(0, 120)}…' : body;
    final soundPref = ref.read(notificationSoundProvider);
    final isConfirmation = reply.content.contains('[[CONFIRMATION_REQUIRED]]');

    if (isConfirmation) {
      ChatNotificationService.instance.showConfirmation(
        agentId: agentId,
        agentName: agentName,
        preview: preview,
        soundFileName: soundPref.fileName,
      );
    } else {
      ChatNotificationService.instance.show(
        agentId: agentId,
        agentName: agentName,
        preview: preview,
        soundFileName: soundPref.fileName,
      );
    }
  }

  /// Strip basic markdown and internal sentinels for notification body preview.
  static String _stripMarkdown(String text) {
    return text
        .replaceAll('\n\n[[CONFIRMATION_REQUIRED]]', '')
        .replaceAll('[[CONFIRMATION_REQUIRED]]', '')
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
