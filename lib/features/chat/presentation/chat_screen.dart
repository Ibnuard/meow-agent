import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../app/widgets/widgets.dart';
import '../../../services/agent_runtime/context_compactor.dart';
import '../../../services/agent_runtime/runtime_models.dart';
import '../../../services/workspace/storage_permission_service.dart';
import '../../../services/llm/openai_compatible_client.dart';
import '../../agents/data/agent_model.dart';
import '../../agents/data/agent_repository.dart';
import '../../providers/data/provider_config.dart';
import '../../providers/data/provider_repository.dart';
import '../../settings/data/app_language_provider.dart';
import '../../settings/data/llm_debug_provider.dart';
import '../../settings/data/llm_provider_config.dart';
import '../data/chat_history_service.dart';
import '../data/chat_runtime_manager.dart';
import '../data/unread_service.dart';
import 'chat_shimmer.dart';
import 'widgets/task_ledger_bubble.dart';
import 'widgets/meow_bubble.dart';
import 'mixins/chat_message_actions.dart';
import 'mixins/chat_debug_sheet.dart';
import 'mixins/chat_history_manager.dart';
import 'mixins/chat_send_handler.dart';
import 'mixins/chat_command_handler.dart';
import 'mixins/chat_report_builder.dart';
import 'mixins/chat_compactor.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.agentId, this.initialText});

  final String agentId;
  final String? initialText;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen>
    with WidgetsBindingObserver, ChatMessageActionsMixin, ChatDebugSheetMixin, ChatHistoryManagerMixin, ChatSendHandlerMixin, ChatCommandHandlerMixin, ChatReportBuilderMixin, ChatCompactorMixin {
  @override
  AppStrings get s {
    final langPref = ref.read(appLanguageProvider);
    return AppStrings(resolveLanguageCode(langPref));
  }

  final _input = TextEditingController();
  final _scroll = ScrollController();
  // Per-agent message history Ã¢â‚¬â€ paginated from local storage.
  final Map<String, List<ChatMessage>> _messagesByAgent = {};
  final Set<String> _fullyLoaded = {}; // Agents with no more older messages.
  bool _loadingOlder = false;
  bool _initialLoading = true;
  late String _activeAgentId;

  // Storage permission state.
  bool _permissionGranted = true; // Assume true until checked.
  bool _permissionChecking = true;

  // Tracks the last manager reply timestamp so we know when to reload.
  DateTime? _lastSeenReplyAt;
  ChatRuntimeManager? _manager;

  /// Message currently being replied to (WhatsApp-style quote). Null when no
  /// active reply context. Cleared after send or when user taps the X.
  ChatMessage? _replyTo;

  // Mixin interface delegates.
  @override
  List<ChatMessage> get messagesList => _messages;
  @override
  ChatMessage? get replyToContext => _replyTo;
  @override
  set replyToContext(ChatMessage? value) => _replyTo = value;
  @override
  Future<ChatMessage> persistMessage(ChatMessage message) => _persistMessage(message);
  @override
  void scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  // ChatDebugSheetMixin interface delegates.
  @override
  String get activeAgentId => _activeAgentId;
  @override
  ChatRuntimeManager ensureManager() => _ensureManager();

  // ChatHistoryManagerMixin interface delegates.
  @override
  Map<String, List<ChatMessage>> get messagesByAgent => _messagesByAgent;
  @override
  Set<String> get fullyLoaded => _fullyLoaded;
  @override
  ChatRuntimeManager? get manager => _manager;
  @override
  bool get initialLoading => _initialLoading;
  @override
  set initialLoading(bool value) => _initialLoading = value;
  @override
  bool get loadingOlder => _loadingOlder;
  @override
  set loadingOlder(bool value) => _loadingOlder = value;
  @override
  bool get hasMore => _hasMore;
  ScrollController get scrollController => _scroll;

  // ChatSendHandlerMixin interface delegates.
  @override
  List<AttachedFile> get attachments => _attachments;
  @override
  set attachments(List<AttachedFile> value) => _attachments = value;
  @override
  GlobalKey<_ChatInputState> get chatInputKey => _chatInputKey;
  @override
  TextEditingController get inputController => _input;
  @override
  bool get sending => _sending;
  @override
  ProviderConfig? resolveProvider() => _resolveProvider();
  @override
  Future<bool> autoCompactIfNeeded() => _autoCompactIfNeeded();
  @override
  Future<void> handleCommand(String text) => _handleCommand(text);
  @override
  String buildReplyPayload(ChatMessage quoted, String userText) => buildReplyPayload(quoted, userText);

  // ChatCommandHandlerMixin interface delegates.
  @override
  bool get debugMode => ref.read(llmDebugModeProvider);

  /// Attached files for the next send (synced from _ChatInput).
  List<AttachedFile> _attachments = [];
  final _chatInputKey = GlobalKey<_ChatInputState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final agents = ref.read(agentListProvider);
    if (widget.agentId == 'default' && agents.isNotEmpty) {
      _activeAgentId = agents.first.id;
    } else {
      _activeAgentId = widget.agentId;
    }
    if (widget.initialText != null && widget.initialText!.isNotEmpty) {
      _input.text = widget.initialText!;
    }

    _scroll.addListener(_onScroll);

    // Mark this agent's chat as in-foreground so the unread counter clears
    // and incoming messages don't bump the badge while user is reading.
    UnreadService.instance.setActive(_activeAgentId);

    // Check storage permission before loading history.
    _checkStoragePermission();

    // Subscribe once after first frame so ref is available.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _manager = ref.read(chatRuntimeManagerProvider);
      _manager!.addListener(_onManagerChanged);
    });
  }

  Future<void> _checkStoragePermission() async {
    final granted = await StoragePermissionService.instance.isGranted();
    if (!mounted) return;
    setState(() {
      _permissionGranted = granted;
      _permissionChecking = false;
    });
    if (granted) {
      loadHistory(_activeAgentId);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkStoragePermission();
    }
  }

  Future<void> _requestStoragePermission() async {
    final granted = await StoragePermissionService.instance.request();
    if (!mounted) return;
    setState(() => _permissionGranted = granted);
    if (granted) {
      loadHistory(_activeAgentId);
    }
  }

  Widget _buildPermissionError(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.folder_off_outlined,
              size: 48,
              color: cs.error.withValues(alpha: 0.7),
            ),
            const SizedBox(height: 16),
            Text(
              s.storagePermissionTitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              s.storagePermissionBody,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _requestStoragePermission,
              icon: const Icon(Icons.security_rounded, size: 18),
              label: Text(s.storagePermissionGrant),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: () => StoragePermissionService.instance.openSettings(),
              child: Text(s.storagePermissionOpenSettings),
            ),
          ],
        ),
      ),
    );
  }

  void _onManagerChanged() {
    if (!mounted) return;
    final session = _manager!.sessionFor(_activeAgentId);
    // When a new reply lands, reload history to pick up persisted messages.
    if (session.lastReplyAt != null &&
        session.lastReplyAt != _lastSeenReplyAt) {
      _lastSeenReplyAt = session.lastReplyAt;
      reloadHistory(_activeAgentId);
    } else {
      // Rebuild for debug/running state changes.
      setState(() {});
    }
    // Always nudge to the bottom so new bubbles (debug, thinking, replies)
    // remain visible without manual scrolling.
    scrollToEnd();
  }

  List<ChatMessage> get _messages =>
      _messagesByAgent.putIfAbsent(_activeAgentId, () => []);

  bool get _hasMore => !_fullyLoaded.contains(_activeAgentId);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    UnreadService.instance.clearActive(_activeAgentId);
    _manager?.removeListener(_onManagerChanged);
    _scroll.removeListener(_onScroll);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Detect scroll to top Ã¢â€ â€™ load older messages.
  void _onScroll() {
    if (!_hasMore || _loadingOlder) return;
    if (_scroll.position.pixels <= 80) {
      loadOlderMessages();
    }
  }

  ProviderConfig? _resolveProvider() {
    final agents = ref.read(agentListProvider);
    final providers = ref.read(providerListProvider).value ?? [];

    // Find the agent.
    AgentModel? agent;
    if (_activeAgentId == 'default') {
      agent = agents.isNotEmpty ? agents.first : null;
    } else {
      agent = agents.where((a) => a.id == _activeAgentId).firstOrNull;
    }
    if (agent == null) return null;

    // Find the provider and apply the model selected on the agent.
    final provider = providers
        .where((p) => p.id == agent!.providerId)
        .firstOrNull;
    if (provider == null) return null;
    return provider.copyWith(model: provider.effectiveModel(agent.model));
  }

  /// Whether the runtime is currently working on this agent's request.
  bool get _sending {
    final mgr = _manager;
    if (mgr == null) return false;
    return mgr.sessionFor(_activeAgentId).isRunning;
  }

  /// Lazily resolve and subscribe to the persistent runtime manager.
  ChatRuntimeManager _ensureManager() {
    if (_manager == null) {
      final mgr = ref.read(chatRuntimeManagerProvider);
      _manager = mgr;
      mgr.addListener(_onManagerChanged);
      return mgr;
    }
    return _manager!;
  }

  void _stop() {
    final mgr = _manager;
    if (mgr == null) return;
    mgr.cancelActive(_activeAgentId);
  }

  /// Developer-only: show a runtime debug stream as a bottom sheet, triggered
  /// by long-pressing the agent name in the AppBar. Subscribes to the chat
  /// runtime manager so new events appear live without re-opening the sheet.
  /// Replaces the old behavior of injecting debug bubbles into the chat list.
  @override
  void showDebugBottomSheet() {
    final mgr = _ensureManager();
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          expand: false,
          builder: (sheetCtx, scrollCtrl) {
            return AnimatedBuilder(
              animation: mgr,
              builder: (innerCtx, _) {
                final session = mgr.sessionFor(_activeAgentId);
                final events = session.debugMessages;
                final narrative = session.narrativeMessage;
                final isRunning = session.isRunning;
                return Column(
                  children: [
                    Container(
                      margin: const EdgeInsets.only(top: 8),
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: cs.onSurfaceVariant.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 14, 16, 8),
                      child: Row(
                        children: [
                          Icon(Icons.bug_report_outlined,
                              size: 18, color: cs.primary),
                          const SizedBox(width: 8),
                          Text(
                            s.runtimeDebugTitle,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: cs.onSurface,
                            ),
                          ),
                          const Spacer(),
                          if (isRunning)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: cs.primary.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                s.runningLabel,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: cs.primary,
                                ),
                              ),
                            ),
                          IconButton(
                            tooltip: s.closeTooltip,
                            icon: const Icon(Icons.close_rounded, size: 20),
                            onPressed: () => Navigator.pop(ctx),
                          ),
                        ],
                      ),
                    ),
                    if (narrative != null && narrative.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: cs.primary.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: cs.primary.withValues(alpha: 0.2),
                            ),
                          ),
                          child: Text(
                            narrative,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: cs.onSurface,
                              fontStyle: FontStyle.italic,
                              height: 1.35,
                            ),
                          ),
                        ),
                      ),
                    const Divider(height: 1),
                    Expanded(
                      child: events.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text(
                                  isRunning
                                      ? 'Waiting for runtime events\u2026'
                                      : 'No runtime events for this run.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            )
                          : ListView.separated(
                              controller: scrollCtrl,
                              padding: const EdgeInsets.fromLTRB(
                                  16, 12, 16, 24),
                              itemCount: events.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 6),
                              itemBuilder: (lctx, i) {
                                final e = events[i];
                                return Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 9),
                                  decoration: BoxDecoration(
                                    color: cs.surfaceContainerHighest
                                        .withValues(alpha: 0.5),
                                    borderRadius:
                                        BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    e.content,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: cs.onSurface,
                                      height: 1.35,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  Future<void> _handleCommand(String text) async {
    final cmd = text.split(' ').first.toLowerCase();
    _input.clear();

    // Show the slash command itself in the chat history so the user can see
    // what they ran (and scroll back to it later). For /clear we deliberately
    // skip persistence because the next step wipes the agent's history.
    final userMsg = ChatMessage(role: 'user', content: text);
    setState(() => _messages.add(userMsg));
    if (cmd != '/clear') {
      _persistMessage(userMsg);
    }
    scrollToEnd();

    String response;
    bool shouldPersist = true;

    switch (cmd) {
      case '/clear':
        await ref.read(chatHistoryServiceProvider).clear(_activeAgentId);
        _messagesByAgent.remove(_activeAgentId);
        _fullyLoaded.remove(_activeAgentId);
        OpenAiCompatibleClient.clearUsageRecords();
        setState(() {});
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(s.chatHistoryCleared),
              duration: const Duration(seconds: 2),
            ),
          );
        }
        return;
      case '/help':
        response = buildCommandHelp(ref.read(llmDebugModeProvider));
      case '/reset':
        // Soft reset: clear context measurement so the next message is a fresh
        // slate, but keep the visible chat history intact.
        OpenAiCompatibleClient.clearUsageRecords();
        response = s.contextReset;
      case '/model':
        final agents = ref.read(agentListProvider);
        final providers = ref.read(providerListProvider).value ?? [];
        final agent = _activeAgentId == 'default'
            ? (agents.isNotEmpty ? agents.first : null)
            : agents.where((a) => a.id == _activeAgentId).firstOrNull;
        final provider = agent != null
            ? providers.where((p) => p.id == agent.providerId).firstOrNull
            : null;
        if (provider != null) {
          final agentModel = agent?.model ?? '';
          final modelInfo = agentModel.isNotEmpty
              ? '\nÃ¢â‚¬Â¢ Model: ${provider.effectiveModel(agentModel)}'
              : '\nÃ¢â‚¬Â¢ Model: (provider default)';
          response =
              'Ã°Å¸Â¤â€“ Model Info:\n'
              'Ã¢â‚¬Â¢ Provider: ${provider.nickname}$modelInfo\n'
              'Ã¢â‚¬Â¢ Endpoint: ${provider.baseUrl}';
        } else {
          response = s.noProviderConnected;
        }
      case '/set-model':
        await showModelsCommandBubble();
        return;
      case '/compact':
        await performCompaction();
        return;
      case '/status':
        response = buildStatusInfo();
      case '/context':
        response = await buildContextReport();
      case '/cron':
        response = s.cronNoJobs;
      case '/log':
        response = await buildRuntimeLogReport();
      case '/clearlog':
        response = await clearRuntimeLog();
      default:
        response = s.unknownCommand(cmd);
    }

    final botMsg = ChatMessage(role: 'assistant', content: response);
    setState(() => _messages.add(botMsg));
    if (shouldPersist) await _persistMessage(botMsg);
    scrollToEnd();
  }

  /// Auto-compact if context exceeds 80% threshold.
  ///
  /// Returns `true` when the send was BLOCKED (auto-compact off + context full),
  /// and the caller should not proceed with the user's request.
  Future<bool> _autoCompactIfNeeded() async {
    final agents = ref.read(agentListProvider);
    final agent = _activeAgentId == 'default'
        ? (agents.isNotEmpty ? agents.first : null)
        : agents.where((a) => a.id == _activeAgentId).firstOrNull;
    final maxCtx = agent?.maxContextLength ?? 8191;

    if (!ContextCompactor.needsCompaction(
      messages: _messages,
      maxContextLength: maxCtx,
    )) {
      return false;
    }

    if (agent?.autoCompact == false) {
      final msg = ChatMessage(
        role: 'assistant',
        content: s.contextExhausted(agent!.maxContextLength),
      );
      setState(() => _messages.add(msg));
      _persistMessage(msg);
      return true;
    }

    final provider = _resolveProvider();
    if (provider == null) return false;

    try {
      final llmConfig = LlmProviderConfig(
        baseUrl: provider.baseUrl,
        apiKey: provider.apiKey,
        model: provider.model,
      );
      final compactor = ContextCompactor();
      final compacted = await compactor.compact(
        messages: _messages,
        config: llmConfig,
        keepRecent: 8,
      );

      // Persist compacted history.
      await ref.read(chatHistoryServiceProvider).clear(_activeAgentId);
      for (final msg in compacted) {
        await ref
            .read(chatHistoryServiceProvider)
            .addMessage(_activeAgentId, msg);
      }

      setState(() {
        _messagesByAgent[_activeAgentId] = compacted;
      });

      // Notify user.
      final infoMsg = ChatMessage(
        role: 'assistant',
        content: s.autoCompacted(compacted.length),
      );
      setState(() => _messages.add(infoMsg));
      _persistMessage(infoMsg);
      return false;
    } catch (_) {
      // Silent fail for auto-compact Ã¢â‚¬â€ don't block the user's message.
    }
    return false;
  }

  void _switchAgent(String agentId) {
    if (agentId == _activeAgentId) return;
    UnreadService.instance.clearActive(_activeAgentId);
    UnreadService.instance.setActive(agentId);
    loadHistory(_activeAgentId);
    setState(() => _activeAgentId = agentId);
  }

  Future<ChatMessage> _persistMessage(ChatMessage message) async {
    final id = await ref
        .read(chatHistoryServiceProvider)
        .addMessage(_activeAgentId, message);
    return ChatMessage(
      id: id,
      role: message.role,
      content: message.content,
      timestamp: message.timestamp,
      actions: message.actions,
    );
  }

  /// True when [a] and [b] fall on the same calendar day (local time).
  static bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final agents = ref.watch(agentListProvider);
    final providers = ref.watch(providerListProvider).value ?? [];
    final debugMode = ref.watch(llmDebugModeProvider);
    final isId = resolveLanguageCode(ref.watch(appLanguageProvider)) == 'id';

    final agent = _activeAgentId == 'default'
        ? (agents.isNotEmpty ? agents.first : null)
        : agents.where((a) => a.id == _activeAgentId).firstOrNull;
    final agentName = agent?.name ?? 'Chat';
    final provider = agent != null
        ? providers.where((p) => p.id == agent.providerId).firstOrNull
        : null;
    final modelName = agent?.model.isNotEmpty == true
        ? provider?.effectiveModel(agent!.model)
        : null;
    final modelIsOverride = modelName != null;

    final providerCode = provider?.displayCode ?? '';
    final displayModelName = modelName != null && modelName.isNotEmpty
        ? '$providerCode${providerCode.isNotEmpty ? ' \u{2022} ' : ''}$modelName'
        : null;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (context.canPop()) {
          context.pop();
        } else {
          context.go('/');
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: GestureDetector(
            // Long-press on the agent name (header title) opens the runtime
            // debug bottom sheet, but only when LLM debug mode is enabled.
            // This replaces the previous behavior of mixing debug bubbles
            // into the chat list, which polluted the conversation view.
            onLongPress: debugMode ? showDebugBottomSheet : null,
            behavior: HitTestBehavior.opaque,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(agentName),
                if (modelName != null && modelName.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    displayModelName!,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w400,
                      color: modelIsOverride ? cs.primary : cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () {
              if (context.canPop()) {
                context.pop();
              } else {
                context.go('/');
              }
            },
          ),
          actions: [
            Builder(
              builder: (ctx) => IconButton(
                tooltip: s.switchAgent,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                constraints: const BoxConstraints(),
                icon: agent != null
                    ? MeowAgentIcon(
                        agent: agent,
                        size: 30,
                        iconSize: 16,
                        radius: 10,
                      )
                    : const Icon(Icons.switch_account_rounded),
                onPressed: () => Scaffold.of(ctx).openEndDrawer(),
              ),
            ),
            const SizedBox(width: 4),
          ],
        ),
        endDrawer: _AgentDrawer(
          agents: agents,
          currentAgentId: _activeAgentId,
          onSwitch: _switchAgent,
          s: s,
        ),
        body: GestureDetector(
          onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
          behavior: HitTestBehavior.translucent,
          child: SafeArea(
            child: _permissionChecking
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : !_permissionGranted
                ? _buildPermissionError(cs)
                : agent == null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.smart_toy_outlined,
                          size: 44,
                          color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          s.noAgentConfigured,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: cs.onSurface,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          s.createAgentToChat,
                          style: TextStyle(
                            fontSize: 13,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 20),
                        TextButton.icon(
                          onPressed: () => context.push('/agents/new'),
                          icon: const Icon(Icons.add_rounded),
                          label: Text(s.addAgent),
                        ),
                      ],
                    ),
                  )
                : Column(
                    children: [
                      Expanded(
                        child: _initialLoading
                            ? const ChatShimmer()
                            : _messages.isEmpty && !_sending
                            ? _ChatEmptyState(s: s)
                            : ListView.builder(
                                controller: _scroll,
                                // Larger cacheExtent reduces rebuilds when
                                // scrolling through variable-height markdown
                                // bubbles. addAutomaticKeepAlives is disabled
                                // because bubbles are stateless. We provide
                                // RepaintBoundary manually around each bubble
                                // below, so disable the automatic one too.
                                cacheExtent: 2500,
                                addAutomaticKeepAlives: true,
                                addRepaintBoundaries: false,
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  12,
                                  16,
                                  12,
                                ),
                                // +1 loading, +1 narrative (when present), +1 thinking.
                                // Debug bubbles are now shown in a separate bottom sheet.
                                itemCount:
                                    (_loadingOlder ? 1 : 0) +
                                    (_messages.length) +
                                    ((_sending &&
                                            (_manager
                                                    ?.sessionFor(_activeAgentId)
                                                    .activeTaskLedger !=
                                                null))
                                        ? 1
                                        : 0) +
                                    ((_sending &&
                                            (_manager
                                                    ?.sessionFor(_activeAgentId)
                                                    .narrativeMessage
                                                    ?.isNotEmpty ==
                                                true))
                                        ? 1
                                        : 0) +
                                    (_sending ? 1 : 0),
                                itemBuilder: (context, i) {
                                  // Loading indicator at top.
                                  if (_loadingOlder && i == 0) {
                                    return const Padding(
                                      padding: EdgeInsets.symmetric(
                                        vertical: 8,
                                      ),
                                      child: Center(
                                        child: SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        ),
                                      ),
                                    );
                                  }
                                  final msgIndex = i - (_loadingOlder ? 1 : 0);
                                  // Order: messages Ã¢â€ â€™ narrative Ã¢â€ â€™ thinking.
                                  if (msgIndex < _messages.length) {
                                    final current = _messages[msgIndex];
                                    // Show a floating date separator when the
                                    // day changes from the previous message
                                    // (or for the very first message).
                                    final prev = msgIndex > 0
                                        ? _messages[msgIndex - 1]
                                        : null;
                                    final showDate =
                                        prev == null ||
                                        !_isSameDay(
                                          prev.timestamp.toLocal(),
                                          current.timestamp.toLocal(),
                                        );
                                    final ledger = taskLedgerFromSentinel(
                                      current.content,
                                    );
                                    final bubble = RepaintBoundary(
                                      key: ValueKey(
                                        'msg-${current.id ?? identityHashCode(current)}',
                                      ),
                                      child: ledger != null
                                          ? TaskLedgerBubble(
                                              ledger: ledger,
                                              timestamp: current.timestamp,
                                            )
                                          : MeowBubble(
                                              msg: current,
                                              isId: isId,
                                              onConfirmAction: (action) =>
                                                  handleConfirmation(
                                                    action,
                                                    msgIndex,
                                                  ),
                                              onActionTap: handleResultAction,
                                              onLongPress: () =>
                                                  showMessageActions(current),
                                            ),
                                    );
                                    if (!showDate) return bubble;
                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        _DateSeparator(
                                          date: current.timestamp.toLocal(),
                                          isId: isId,
                                        ),
                                        bubble,
                                      ],
                                    );
                                  }
                                  final tailIdx = msgIndex - _messages.length;
                                  final session = _manager?.sessionFor(
                                    _activeAgentId,
                                  );
                                  final liveLedger = session?.activeTaskLedger;
                                  if (_sending &&
                                      liveLedger != null &&
                                      tailIdx == 0) {
                                    return TaskLedgerBubble(
                                      ledger: liveLedger,
                                      live: true,
                                    );
                                  }

                                  // Narrative bubble Ã¢â‚¬â€ above the thinking dots,
                                  // shown only while sending AND a narrative is set.
                                  final narrativeIdx =
                                      tailIdx - ((_sending && liveLedger != null) ? 1 : 0);
                                  final narrative = session?.narrativeMessage;
                                  final hasNarrative =
                                      _sending &&
                                      (narrative?.isNotEmpty == true);
                                  if (hasNarrative && narrativeIdx == 0) {
                                    return _NarrativeBubble(text: narrative!);
                                  }
                                  // Thinking bubble at very bottom.
                                  return const _ThinkingBubble();
                                },
                              ),
                      ),
                      _ChatInput(
                        key: _chatInputKey,
                        controller: _input,
                        sending: _sending,
                        debugMode: debugMode,
                        onSend: send,
                        onStop: _stop,
                        replyTo: _replyTo,
                        onCancelReply: cancelReply,
                        onAttachmentsChanged: (files) {
                          setState(() => _attachments = files);
                        },
                        s: s,
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _DateSeparator extends StatelessWidget {
  const _DateSeparator({required this.date, required this.isId});

  final DateTime date;
  final bool isId;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: extras.card.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: extras.subtleBorder),
        ),
        child: Text(
          _label(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: cs.onSurfaceVariant,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }

  String _label() {
    final s = AppStrings(isId ? 'id' : 'en');
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(date.year, date.month, date.day);
    final diff = today.difference(that).inDays;
    if (diff == 0) return s.today;
    if (diff == 1) return s.yesterday;

    const monthsId = [
      'Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun',
      'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des',
    ];
    const monthsEn = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final months = isId ? monthsId : monthsEn;
    final mon = months[date.month - 1];
    if (date.year == now.year) return '${date.day} $mon';
    return '${date.day} $mon ${date.year}';
  }
}

class _NarrativeBubble extends StatelessWidget {
  const _NarrativeBubble({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final extras = context.extras;
    final cs = context.cs;
    return Align(
      alignment: Alignment.centerLeft,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.08),
              end: Offset.zero,
            ).animate(anim),
            child: child,
          ),
        ),
        child: Container(
          key: ValueKey<String>(text),
          margin: const EdgeInsets.only(top: 4, bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: extras.card.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: extras.subtleBorder.withValues(alpha: 0.6),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(_emojiFor(text), style: const TextStyle(fontSize: 13)),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontStyle: FontStyle.italic,
                    color: cs.onSurfaceVariant,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Pick an ambient emoji that loosely matches the phase tone.
  /// Pure cosmetic; no semantic dependency.
  static String _emojiFor(String text) {
    final t = text.toLowerCase();
    if (t.contains('confirm') || t.contains('konfirmasi')) {
      return '\u{23F8}\u{FE0F}';
    }
    if (t.contains('check') || t.contains('cek') || t.contains('hasil')) {
      return '\u{1F50D}';
    }
    if (t.contains('plan') || t.contains('rencana') || t.contains('langkah')) {
      return '\u{1F9ED}';
    }
    if (t.contains('write') ||
        t.contains('compos') ||
        t.contains('jawaban') ||
        t.contains('reply')) {
      return '\u{270D}\u{FE0F}';
    }
    if (t.contains('try') ||
        t.contains('coba') ||
        t.contains('different') ||
        t.contains('lain')) {
      return '\u{1F504}';
    }
    if (t.contains('execut') ||
        t.contains('mengerjakan') ||
        t.contains('working') ||
        t.contains('progress')) {
      return '\u{2699}\u{FE0F}';
    }
    if (t.contains('ask') || t.contains('quest') || t.contains('pertanyaan')) {
      return '\u{1F4AC}';
    }
    return '\u{2728}';
  }
}

class _ThinkingBubble extends StatefulWidget {
  const _ThinkingBubble();

  @override
  State<_ThinkingBubble> createState() => _ThinkingBubbleState();
}

class _ThinkingBubbleState extends State<_ThinkingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final extras = context.extras;

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: extras.card,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(4),
            bottomRight: Radius.circular(16),
          ),
          border: Border.all(color: extras.subtleBorder),
        ),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final t = _controller.value;
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildDot(context, t, 0.0),
                const SizedBox(width: 4),
                _buildDot(context, t, 0.2),
                const SizedBox(width: 4),
                _buildDot(context, t, 0.4),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildDot(BuildContext context, double t, double delay) {
    final cs = context.cs;
    final phase = ((t + delay) % 1.0);
    final opacity = 0.3 + 0.7 * (phase < 0.5 ? phase * 2 : (1 - phase) * 2);
    return Opacity(
      opacity: opacity,
      child: Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(
          color: cs.onSurfaceVariant,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

class _ChatEmptyState extends StatelessWidget {
  const _ChatEmptyState({required this.s});
  final AppStrings s;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline_rounded,
              size: 44,
              color: cs.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 12),
            Text(
              s.sayHiToAgent,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              s.askAnythingToStart,
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatInput extends StatefulWidget {
  const _ChatInput({
    super.key,
    required this.controller,
    required this.sending,
    required this.debugMode,
    required this.onSend,
    required this.onStop,
    required this.s,
    this.replyTo,
    this.onCancelReply,
    required this.onAttachmentsChanged,
  });

  final TextEditingController controller;
  final bool sending;
  final bool debugMode;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final AppStrings s;
  final ChatMessage? replyTo;
  final VoidCallback? onCancelReply;
  final void Function(List<AttachedFile>) onAttachmentsChanged;

  @override
  State<_ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<_ChatInput> {
  List<_SlashCommand> get _baseCommands => [
    _SlashCommand('/clear', widget.s.helpSlashClear),
    _SlashCommand('/help', widget.s.helpSlashHelp),
    _SlashCommand('/status', widget.s.helpSlashStatus),
    _SlashCommand('/context', widget.s.helpSlashContext),
    _SlashCommand('/reset', widget.s.helpSlashReset),
    _SlashCommand('/model', widget.s.helpSlashModel),
    _SlashCommand('/set-model', widget.s.helpSlashSetModel),
    _SlashCommand('/compact', widget.s.helpSlashCompact),
    _SlashCommand('/cron', widget.s.helpSlashCron),
  ];
  List<_SlashCommand> get _debugCommands => [
    _SlashCommand('/log', widget.s.helpSlashLog),
    _SlashCommand('/clearlog', widget.s.helpSlashClearlog),
  ];

  List<_SlashCommand> get _commands => widget.debugMode
      ? [..._baseCommands, ..._debugCommands]
      : _baseCommands;

  List<_SlashCommand> _filtered = [];
  bool _showSuggestions = false;
  final List<_AttachedFile> _attachments = [];
  static const _maxFiles = 2;
  static const _maxFileBytes = 5 * 1024 * 1024; // 5 MB

  /// Returns a snapshot of attached files for the parent to pass to the runtime.
  /// Uses sizes stored at pick time (never lengthSync, which would crash on
  /// Android content URIs from file_picker).
  List<AttachedFile> get _attachmentsSnapshot => [
    for (final a in _attachments)
      AttachedFile(path: a.file.path, name: a.name, sizeBytes: a.sizeBytes),
  ];

  void _notifyAttachments() =>
      widget.onAttachmentsChanged(_attachmentsSnapshot);

  /// Clear all attachments (called by parent after send).
  void clearAttachments() {
    if (_attachments.isEmpty) return;
    setState(() => _attachments.clear());
    _notifyAttachments();
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    super.dispose();
  }

  Future<void> _pickFile() async {
    final remaining = _maxFiles - _attachments.length;
    if (remaining <= 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(widget.s.maxFilesExceeded(_maxFiles)),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: remaining > 1,
      withData: false,
    );
    if (result == null || result.files.isEmpty) return;

    final newFiles = <_AttachedFile>[];
    for (final pf in result.files) {
      if (pf.path == null) continue;
      final sizeBytes = pf.size;
      if (sizeBytes > _maxFileBytes) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(widget.s.fileTooLarge(pf.name)),
              duration: const Duration(seconds: 2),
            ),
          );
        }
        continue;
      }
      // Prevent duplicates by name.
      if (_attachments.any((a) => a.name == pf.name)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(widget.s.fileAlreadyAttached(pf.name)),
              duration: const Duration(seconds: 2),
            ),
          );
        }
        continue;
      }
      newFiles.add(
        _AttachedFile(file: File(pf.path!), name: pf.name, sizeBytes: pf.size),
      );
    }
    if (newFiles.isEmpty) return;

    // Cap at max.
    final toAdd = newFiles.take(remaining).toList();
    setState(() => _attachments.addAll(toAdd));
    _notifyAttachments();
  }

  void _removeFile(int index) {
    setState(() => _attachments.removeAt(index));
    _notifyAttachments();
  }
  bool _isImageExtension(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    final ext = name.substring(dot).toLowerCase();
    return const {'.png', '.jpg', '.jpeg', '.webp', '.gif', '.bmp', '.heic'}
        .contains(ext);
  }

  void _showImagePreview(BuildContext context, File file) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(16),
        child: GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.file(
              file,
              fit: BoxFit.contain,
              errorBuilder: (_, e, s) => Container(
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  Icons.broken_image_rounded,
                  size: 48,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _onTextChanged() {
    final text = widget.controller.text;
    if (text.startsWith('/')) {
      final query = text.toLowerCase();
      final matches = _commands
          .where((c) => c.command.startsWith(query))
          .toList();
      setState(() {
        _filtered = matches;
        _showSuggestions = matches.isNotEmpty;
      });
    } else {
      if (_showSuggestions) {
        setState(() => _showSuggestions = false);
      }
    }
  }

  void _selectCommand(String command) {
    widget.controller.text = command;
    widget.controller.selection = TextSelection.fromPosition(
      TextPosition(offset: command.length),
    );
    setState(() => _showSuggestions = false);
  }

  void _showAllCommands() {
    widget.controller.text = '/';
    widget.controller.selection = TextSelection.fromPosition(
      const TextPosition(offset: 1),
    );
    setState(() {
      _filtered = _commands;
      _showSuggestions = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_showSuggestions)
          Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.5,
            ),
            decoration: BoxDecoration(
              color: extras.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: extras.subtleBorder),
            ),
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: _filtered.map((cmd) {
                return InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => _selectCommand(cmd.command),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        Text(
                          cmd.command,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: cs.primary,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            cmd.description,
                            style: TextStyle(
                              fontSize: 12,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        // Reply preview chip (WhatsApp-style).
        if (widget.replyTo != null)
          Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            decoration: BoxDecoration(
              color: extras.card,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: extras.subtleBorder),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Left accent strip (drawn as a sibling so the rounded
                    // corners stay intact Ã¢â‚¬â€ non-uniform Border widths break
                    // when combined with borderRadius).
                    Container(width: 3, color: cs.primary),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.reply_rounded,
                              size: 16,
                              color: cs.primary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
Text(
                                      widget.replyTo!.role == 'user'
                                          ? widget.s.you
                                          : widget.s.agentLabel,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: cs.primary,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    widget.replyTo!.content
                                        .replaceAll(
                                          RegExp(
                                            r'\[\[REPLY_QUOTE:[^\]]+\]\].*?\[\[/REPLY_QUOTE\]\]\n?',
                                            dotAll: true,
                                          ),
                                          '',
                                        )
                                        .replaceAll(
                                          '\n\n[[CONFIRMATION_REQUIRED]]',
                                          '',
                                        )
                                        .replaceAll(
                                          '[[CONFIRMATION_REQUIRED]]',
                                          '',
                                        )
                                        .trim(),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: cs.onSurface.withValues(
                                        alpha: 0.85,
                                      ),
                                      height: 1.3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            InkWell(
                              onTap: widget.onCancelReply,
                              borderRadius: BorderRadius.circular(20),
                              child: Padding(
                                padding: const EdgeInsets.all(4),
                                child: Icon(
                                  Icons.close_rounded,
                                  size: 18,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        // File preview chips (up to 2, 5 MB each).
        if (_attachments.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: List.generate(_attachments.length, (i) {
                  final a = _attachments[i];
                  final isImage = _isImageExtension(a.name);
                  if (isImage) {
                    // Image thumbnail preview.
                    return Stack(
                      children: [
                        GestureDetector(
                          onTap: () => _showImagePreview(context, a.file),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Image.file(
                              a.file,
                              width: 56,
                              height: 56,
                              fit: BoxFit.cover,
                              errorBuilder: (_, e, s) => Container(
                                width: 56,
                                height: 56,
                                decoration: BoxDecoration(
                                  color: extras.card,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(
                                  Icons.broken_image_rounded,
                                  size: 20,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          top: 2,
                          right: 2,
                          child: GestureDetector(
                            onTap: () => _removeFile(i),
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: const BoxDecoration(
                                color: Colors.black54,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.close_rounded,
                                size: 14,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  }
                  // Non-image file chip (existing style).
                  return Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: extras.card,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: extras.subtleBorder),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.attach_file_rounded,
                          size: 16,
                          color: cs.primary,
                        ),
                        const SizedBox(width: 6),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 200),
                          child: Text(
                            a.name,
                            style: TextStyle(
                              fontSize: 12,
                              color: cs.onSurface,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 4),
                        GestureDetector(
                          onTap: () => _removeFile(i),
                          child: Icon(
                            Icons.close_rounded,
                            size: 16,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  );
                }),
              ),
            ),
          ),

        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => widget.onSend(),
                  decoration: InputDecoration(
                    hintText: widget.s.typeMessage,
                    suffixIcon: _attachments.length < _maxFiles
                        ? IconButton(
                            icon: Icon(
                              Icons.attach_file_rounded,
                              size: 20,
                              color: cs.onSurfaceVariant,
                            ),
                            onPressed: _pickFile,
                          )
                        : null,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Material(
                color: extras.card,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: _showAllCommands,
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: Center(
                      child: Text(
                        '/',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Material(
                color: widget.sending ? Colors.red.shade400 : cs.primary,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: widget.sending ? widget.onStop : widget.onSend,
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: widget.sending
                        ? const Icon(
                            Icons.stop_rounded,
                            color: Colors.white,
                            size: 24,
                          )
                        : Icon(Icons.send_rounded, color: cs.onPrimary),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SlashCommand {
  const _SlashCommand(this.command, this.description);
  final String command;
  final String description;
}

/// Right-side drawer showing all agents for seamless switching.
class _AgentDrawer extends ConsumerWidget {
  const _AgentDrawer({
    required this.agents,
    required this.currentAgentId,
    required this.onSwitch,
    required this.s,
  });

  final List<AgentModel> agents;
  final String currentAgentId;
  final ValueChanged<String> onSwitch;
  final AppStrings s;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = context.cs;
    final extras = context.extras;
    final unread = ref.watch(unreadServiceProvider);

    return Drawer(
      backgroundColor: cs.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Text(
                s.agentListTitle,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                  letterSpacing: -0.3,
                ),
              ),
            ),
            Divider(height: 1, color: extras.subtleBorder),
            const SizedBox(height: 8),
            Expanded(
              child: agents.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.smart_toy_outlined,
                            size: 36,
                            color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            s.noAgentsYet,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            s.createAgentToChat,
                            style: TextStyle(
                              fontSize: 12,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 16),
                          TextButton.icon(
                            onPressed: () {
                              Navigator.pop(context);
                              context.push('/agents/new');
                            },
                            icon: const Icon(Icons.add_rounded, size: 18),
                            label: Text(s.addAgent),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      itemCount: agents.length,
                      itemBuilder: (context, i) {
                        final agent = agents[i];
                        final isActive =
                            agent.id == currentAgentId ||
                            (currentAgentId == 'default' && i == 0);

                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Material(
                            color: isActive
                                ? cs.primary.withValues(alpha: 0.1)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(14),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: () {
                                Navigator.pop(context); // Close drawer.
                                onSwitch(agent.id);
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 12,
                                ),
                                child: Row(
                                  children: [
                                    Stack(
                                      clipBehavior: Clip.none,
                                      children: [
                                        MeowAgentIcon(
                                          agent: agent,
                                          size: 36,
                                          radius: 10,
                                          iconSize: 18,
                                        ),
                                        if (isActive)
                                          Positioned(
                                            right: -2,
                                            bottom: -2,
                                            child: Container(
                                              width: 14,
                                              height: 14,
                                              decoration: BoxDecoration(
                                                color: cs.primary,
                                                shape: BoxShape.circle,
                                                border: Border.all(
                                                  color: cs.surface,
                                                  width: 2,
                                                ),
                                              ),
                                              child: Icon(
                                                Icons.check_rounded,
                                                size: 8,
                                                color: cs.onPrimary,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        agent.name,
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: isActive
                                              ? FontWeight.w600
                                              : FontWeight.w500,
                                          color: isActive
                                              ? cs.primary
                                              : cs.onSurface,
                                        ),
                                      ),
                                    ),
                                    if (!isActive &&
                                        unread.countFor(agent.id) > 0)
                                      _DrawerUnreadChip(
                                        count: unread.countFor(agent.id),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact red chip showing unread count for an agent in the drawer list.
class _DrawerUnreadChip extends StatelessWidget {
  const _DrawerUnreadChip({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final label = count > 99 ? '99+' : '$count';
    return Container(
      constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFEF4444),
        borderRadius: BorderRadius.circular(11),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFEF4444).withValues(alpha: 0.4),
            blurRadius: 6,
          ),
        ],
      ),
      child: Center(
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            height: 1.0,
          ),
        ),
      ),
    );
  }
}

/// Internal wrapper for a picked file.
class _AttachedFile {
  const _AttachedFile({
    required this.file,
    required this.name,
    this.sizeBytes = 0,
  });
  final File file;
  final String name;
  final int sizeBytes;
}
