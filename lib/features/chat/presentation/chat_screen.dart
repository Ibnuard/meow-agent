import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../services/agent_runtime/context_compactor.dart';
import '../../../services/agent_runtime/prompt_constants.dart';
import '../../../services/agent_runtime/runtime_models.dart';
import '../../../services/llm/openai_compatible_client.dart';
import '../../agents/data/agent_model.dart';
import '../../agents/data/agent_repository.dart';
import '../../providers/data/provider_config.dart';
import '../../providers/data/provider_repository.dart';
import '../../settings/data/app_language_provider.dart';
import '../../settings/data/llm_provider_config.dart';
import '../data/chat_history_service.dart';
import '../data/chat_runtime_manager.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.agentId, this.initialText});

  final String agentId;
  final String? initialText;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  AppStrings get s {
    final langPref = ref.read(appLanguageProvider);
    return AppStrings(resolveLanguageCode(langPref));
  }
  final _input = TextEditingController();
  final _scroll = ScrollController();
  // Per-agent message history — paginated from local storage.
  final Map<String, List<ChatMessage>> _messagesByAgent = {};
  final Set<String> _fullyLoaded = {}; // Agents with no more older messages.
  bool _loadingOlder = false;
  bool _initialLoading = true;
  late String _activeAgentId;

  // Tracks the last manager reply timestamp so we know when to reload.
  DateTime? _lastSeenReplyAt;
  ChatRuntimeManager? _manager;

  @override
  void initState() {
    super.initState();
    final agents = ref.read(agentListProvider);
    if (widget.agentId == 'default' && agents.isNotEmpty) {
      _activeAgentId = agents.first.id;
    } else {
      _activeAgentId = widget.agentId;
    }
    if (widget.initialText != null && widget.initialText!.isNotEmpty) {
      _input.text = widget.initialText!;
    }
    _loadHistory(_activeAgentId);
    _scroll.addListener(_onScroll);

    // Subscribe once after first frame so ref is available.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _manager = ref.read(chatRuntimeManagerProvider);
      _manager!.addListener(_onManagerChanged);
    });
  }

  void _onManagerChanged() {
    if (!mounted) return;
    final session = _manager!.sessionFor(_activeAgentId);
    // When a new reply lands, reload history to pick up persisted messages.
    if (session.lastReplyAt != null &&
        session.lastReplyAt != _lastSeenReplyAt) {
      _lastSeenReplyAt = session.lastReplyAt;
      _reloadHistory(_activeAgentId);
    } else {
      // Rebuild for debug/running state changes.
      setState(() {});
    }
    // Always nudge to the bottom so new bubbles (debug, thinking, replies)
    // remain visible without manual scrolling.
    _scrollToEnd();
  }

  List<ChatMessage> get _messages =>
      _messagesByAgent.putIfAbsent(_activeAgentId, () => []);

  bool get _hasMore => !_fullyLoaded.contains(_activeAgentId);

  @override
  void dispose() {
    _manager?.removeListener(_onManagerChanged);
    _scroll.removeListener(_onScroll);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Detect scroll to top → load older messages.
  void _onScroll() {
    if (!_hasMore || _loadingOlder) return;
    if (_scroll.position.pixels <= 80) {
      _loadOlderMessages();
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

    // Find the provider.
    return providers.where((p) => p.id == agent!.providerId).firstOrNull;
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

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    FocusManager.instance.primaryFocus?.unfocus();

    // Slash commands handled locally.
    if (text.startsWith('/')) {
      _handleCommand(text);
      return;
    }

    final provider = _resolveProvider();
    if (provider == null) {
      final userMsg = ChatMessage(role: 'user', content: text);
      final botMsg = ChatMessage(
        role: 'assistant',
        content:
            'No provider connected. Please check your agent settings — '
            'the linked provider may have been removed.',
      );
      setState(() {
        _messages.add(userMsg);
        _messages.add(botMsg);
      });
      _input.clear();
      _persistMessage(userMsg);
      _persistMessage(botMsg);
      _scrollToEnd();
      return;
    }
    if (!provider.isComplete) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Provider configuration is incomplete.')),
      );
      return;
    }

    _input.clear();

    if (enableAgentRuntimeV1) {
      // Auto-compact if context threshold reached.
      await _autoCompactIfNeeded();
      // Manager persists user msg + final reply, listener reloads history.
      final mgr = _ensureManager();
      // Optimistically show the user message immediately.
      final userMsg = ChatMessage(role: 'user', content: text);
      setState(() => _messages.add(userMsg));
      _scrollToEnd();
      // Send recent persisted messages (those with id) as context.
      final recent = _messages.where((m) => m.id != null).toList();
      // Fire-and-forget — manager keeps running even if screen disposes.
      mgr.send(
        agentId: _activeAgentId,
        userMessage: text,
        recentMessages: recent,
      );
      return;
    }

    // Legacy direct LLM path.
    final userMsg = ChatMessage(role: 'user', content: text);
    setState(() => _messages.add(userMsg));
    _persistMessage(userMsg);
    _scrollToEnd();

    try {
      final llmConfig = LlmProviderConfig(
        baseUrl: provider.baseUrl,
        apiKey: provider.apiKey,
        model: provider.model,
      );
      final reply = await OpenAiCompatibleClient().chat(
        config: llmConfig,
        messages: _buildHistory(),
      );
      if (!mounted) return;
      final replyMsg = ChatMessage(role: 'assistant', content: reply);
      setState(() => _messages.add(replyMsg));
      _persistMessage(replyMsg);
      _scrollToEnd();
    } catch (e) {
      if (!mounted) return;
      final errorMsg = ChatMessage(role: 'assistant', content: 'Error: $e');
      setState(() => _messages.add(errorMsg));
      _persistMessage(errorMsg);
      _scrollToEnd();
    }
  }

  /// Reload history from disk after manager persists a reply.
  /// Preserves the marker on the most recent assistant message when there's
  /// an active pending tool so the action buttons keep rendering.
  Future<void> _reloadHistory(String agentId) async {
    final service = ref.read(chatHistoryServiceProvider);
    final history = await service.loadLatest(agentId);

    final hasPending =
        _manager?.sessionFor(agentId).pendingTool != null;
    // Find the index of the last assistant message (where the live
    // confirmation marker, if any, lives).
    int lastAssistantIdx = -1;
    for (var i = history.length - 1; i >= 0; i--) {
      if (history[i].role == 'assistant') {
        lastAssistantIdx = i;
        break;
      }
    }

    final cleaned = <ChatMessage>[];
    for (var i = 0; i < history.length; i++) {
      final m = history[i];
      final isLiveConfirmation =
          hasPending && i == lastAssistantIdx;
      if (!isLiveConfirmation &&
          m.content.contains('[[CONFIRMATION_REQUIRED]]')) {
        cleaned.add(ChatMessage(
          id: m.id,
          role: m.role,
          content: m.content
              .replaceAll('\n\n[[CONFIRMATION_REQUIRED]]', '')
              .trim(),
        ));
      } else {
        cleaned.add(m);
      }
    }

    if (!mounted) return;
    setState(() {
      _messagesByAgent[agentId] = cleaned;
    });
    _scrollToEnd();
  }

  void _handleConfirmation(String action, int msgIndex) {
    if (msgIndex < 0 || msgIndex >= _messages.length) return;

    // Destroy the confirmation bubble entirely after action.
    // Also delete it from persistent history so it doesn't reappear.
    final msg = _messages[msgIndex];
    setState(() => _messages.removeAt(msgIndex));
    if (msg.id != null) {
      _deletePersistedMessage(msg.id!);
    }

    final mgr = _ensureManager();

    switch (action) {
      case 'accept':
      case 'always_accept':
        mgr.confirm(_activeAgentId);
        break;
      case 'reject':
        mgr.reject(_activeAgentId);
        break;
    }
  }

  /// Delete a single message from SQLite by its row id.
  Future<void> _deletePersistedMessage(int id) async {
    final service = ref.read(chatHistoryServiceProvider);
    await service.deleteMessage(id);
  }

  List<Map<String, String>> _buildHistory() {
    final agents = ref.read(agentListProvider);
    final agent = _activeAgentId == 'default'
        ? (agents.isNotEmpty ? agents.first : null)
        : agents.where((a) => a.id == _activeAgentId).firstOrNull;
    final name = agent?.name ?? 'Assistant';
    final isFirstChat = _messages.where((m) => m.role == 'user').length <= 1;

    final systemPrompt = StringBuffer()
      ..write(PromptConstants.chatSystemPrompt(name));

    if (isFirstChat) {
      systemPrompt
        ..writeln()
        ..writeln()
        ..write(PromptConstants.firstIntroductionRule);
    }

    // Only send the last 20 messages as context to save tokens.
    final contextMessages = _messages.length > 20
        ? _messages.sublist(_messages.length - 20)
        : _messages;

    return [
      {'role': 'system', 'content': systemPrompt.toString().trim()},
      ...contextMessages.map((m) => {'role': m.role, 'content': m.content}),
    ];
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
      // Secondary scroll after markdown widgets finish layout.
      Future.delayed(const Duration(milliseconds: 100), () {
        if (_scroll.hasClients) {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
          );
        }
      });
    });
  }

  Future<void> _handleCommand(String text) async {
    final cmd = text.split(' ').first.toLowerCase();
    _input.clear();

    String response;
    bool shouldPersist = true;

    switch (cmd) {
      case '/clear':
        await ref.read(chatHistoryServiceProvider).clear(_activeAgentId);
        _messagesByAgent.remove(_activeAgentId);
        _fullyLoaded.remove(_activeAgentId);
        setState(() {});
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Chat history and context cleared.'),
              duration: Duration(seconds: 2),
            ),
          );
        }
        return;
      case '/help':
        response = 'Available commands:\n'
            '• /clear — Clear chat history & context\n'
            '• /help — Show this list\n'
            '• /status — Show agent & context info\n'
            '• /reset — Reset context only\n'
            '• /model — Show current model info\n'
            '• /compact — Compact context window\n'
            '• /cron — Show scheduled tasks';
      case '/reset':
        // Reset context only — keep chat visible but AI forgets prior context.
        response = '✓ Context reset. AI will treat next message as fresh.';
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
          response = '🤖 Model Info:\n'
              '• Provider: ${provider.nickname}\n'
              '• Model: ${provider.model}\n'
              '• Endpoint: ${provider.baseUrl}';
        } else {
          response = '⚠️ No provider connected to this agent.';
        }
      case '/compact':
        await _performCompaction();
        return;
      case '/status':
        response = _buildStatusInfo();
      case '/cron':
        response = '📋 Scheduled Tasks (HEARTBEAT.md):\n'
            'No active cron jobs configured.\n'
            'Edit HEARTBEAT.md in your agent workspace to add scheduled tasks.';
      default:
        response = 'Unknown command: $cmd\nType /help for available commands.';
    }

    final botMsg = ChatMessage(role: 'assistant', content: response);
    setState(() => _messages.add(botMsg));
    if (shouldPersist) _persistMessage(botMsg);
    _scrollToEnd();
  }

  /// Build /status info string.
  String _buildStatusInfo() {
    final agents = ref.read(agentListProvider);
    final providers = ref.read(providerListProvider).value ?? [];
    final agent = _activeAgentId == 'default'
        ? (agents.isNotEmpty ? agents.first : null)
        : agents.where((a) => a.id == _activeAgentId).firstOrNull;
    final provider = agent != null
        ? providers.where((p) => p.id == agent.providerId).firstOrNull
        : null;

    final maxCtx = agent?.maxContextLength ?? 8191;
    final usage = ContextCompactor.getUsageInfo(
      messages: _messages,
      maxContextLength: maxCtx,
    );

    final buf = StringBuffer()
      ..writeln('### 📊 Status\n')
      ..writeln('| | |')
      ..writeln('|---|---|')
      ..writeln('| **App** | Meow Agent v1.0.0 |')
      ..writeln('| **Agent** | ${agent?.name ?? "default"} |')
      ..writeln('| **Provider** | ${provider?.nickname ?? "—"} |')
      ..writeln('| **Model** | ${provider?.model ?? "—"} |')
      ..writeln()
      ..writeln('### 📐 Context\n')
      ..writeln('| | |')
      ..writeln('|---|---|')
      ..writeln('| **Messages** | ${_messages.length} |')
      ..writeln('| **Est. tokens** | ~${usage.estimated} |')
      ..writeln('| **Max context** | $maxCtx |')
      ..writeln('| **Usage** | ${usage.percentage.toStringAsFixed(1)}% |')
      ..writeln('| **Auto-compact** | ${usage.needsCompact ? "⚠️ threshold reached" : "✓ OK"} |');

    return buf.toString().trim();
  }

  /// Perform manual /compact.
  Future<void> _performCompaction() async {
    final provider = _resolveProvider();
    if (provider == null) {
      final msg = ChatMessage(
        role: 'assistant',
        content: '⚠️ Cannot compact: no provider connected.',
      );
      setState(() => _messages.add(msg));
      _persistMessage(msg);
      _scrollToEnd();
      return;
    }

    final agents = ref.read(agentListProvider);
    final agent = _activeAgentId == 'default'
        ? (agents.isNotEmpty ? agents.first : null)
        : agents.where((a) => a.id == _activeAgentId).firstOrNull;
    final maxCtx = agent?.maxContextLength ?? 8191;

    if (_messages.length <= 8) {
      final msg = ChatMessage(
        role: 'assistant',
        content: '✓ Context sudah ringkas (${_messages.length} pesan, '
            '~${ContextCompactor.estimateChatTokens(_messages)} tokens / $maxCtx max).',
      );
      setState(() => _messages.add(msg));
      _persistMessage(msg);
      _scrollToEnd();
      return;
    }

    // Show compacting indicator.
    final loadingMsg = ChatMessage(
      role: 'assistant',
      content: '⏳ Compacting context...',
    );
    setState(() => _messages.add(loadingMsg));
    _scrollToEnd();

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
        keepRecent: 6,
      );

      // Clear old history and replace with compacted.
      await ref.read(chatHistoryServiceProvider).clear(_activeAgentId);
      for (final msg in compacted) {
        await ref.read(chatHistoryServiceProvider).addMessage(_activeAgentId, msg);
      }

      // Remove loading indicator and reload.
      setState(() {
        _messages.remove(loadingMsg);
        _messagesByAgent[_activeAgentId] = compacted;
      });

      final doneMsg = ChatMessage(
        role: 'assistant',
        content: '✓ Context compacted: ${compacted.length} pesan '
            '(~${ContextCompactor.estimateChatTokens(compacted)} tokens).',
      );
      setState(() => _messages.add(doneMsg));
      _persistMessage(doneMsg);
      _scrollToEnd();
    } catch (e) {
      setState(() => _messages.remove(loadingMsg));
      final errMsg = ChatMessage(
        role: 'assistant',
        content: '⚠️ Compact failed: $e',
      );
      setState(() => _messages.add(errMsg));
      _persistMessage(errMsg);
      _scrollToEnd();
    }
  }

  /// Auto-compact if context exceeds 80% threshold.
  Future<void> _autoCompactIfNeeded() async {
    final agents = ref.read(agentListProvider);
    final agent = _activeAgentId == 'default'
        ? (agents.isNotEmpty ? agents.first : null)
        : agents.where((a) => a.id == _activeAgentId).firstOrNull;
    final maxCtx = agent?.maxContextLength ?? 8191;

    if (!ContextCompactor.needsCompaction(
      messages: _messages,
      maxContextLength: maxCtx,
    )) {
      return;
    }

    final provider = _resolveProvider();
    if (provider == null) return;

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
        await ref.read(chatHistoryServiceProvider).addMessage(_activeAgentId, msg);
      }

      setState(() {
        _messagesByAgent[_activeAgentId] = compacted;
      });

      // Notify user.
      final infoMsg = ChatMessage(
        role: 'assistant',
        content: '🔄 Context auto-compacted (threshold 80% reached). '
            '${compacted.length} pesan tersisa.',
      );
      setState(() => _messages.add(infoMsg));
      _persistMessage(infoMsg);
    } catch (_) {
      // Silent fail for auto-compact — don't block the user's message.
    }
  }

  void _switchAgent(String agentId) {
    if (agentId == _activeAgentId) return;
    _loadHistory(agentId);
    setState(() => _activeAgentId = agentId);
  }

  /// Load the latest page of messages for an agent.
  /// Preserves the [[CONFIRMATION_REQUIRED]] marker on the most recent
  /// assistant message when the manager has an active pending tool, so
  /// the action buttons reappear when re-entering a chat mid-confirmation.
  Future<void> _loadHistory(String agentId) async {
    if (_messagesByAgent.containsKey(agentId)) {
      if (_initialLoading) setState(() => _initialLoading = false);
      return;
    }
    // Mark the slot immediately so concurrent _send() calls don't trigger
    // a second putIfAbsent from the _messages getter while we're loading.
    _messagesByAgent[agentId] = [];

    final service = ref.read(chatHistoryServiceProvider);
    final history = await service.loadLatest(agentId);

    // Resolve manager (may be null if not subscribed yet); pending state
    // determines whether to keep the live confirmation marker.
    final ChatRuntimeManager mgr =
        _manager ?? ref.read(chatRuntimeManagerProvider);
    final hasPending = mgr.sessionFor(agentId).pendingTool != null;
    int lastAssistantIdx = -1;
    for (var i = history.length - 1; i >= 0; i--) {
      if (history[i].role == 'assistant') {
        lastAssistantIdx = i;
        break;
      }
    }

    final cleaned = <ChatMessage>[];
    for (var i = 0; i < history.length; i++) {
      final m = history[i];
      final isLiveConfirmation =
          hasPending && i == lastAssistantIdx;
      if (!isLiveConfirmation &&
          m.content.contains('[[CONFIRMATION_REQUIRED]]')) {
        cleaned.add(ChatMessage(
          id: m.id,
          role: m.role,
          content: m.content
              .replaceAll('\n\n[[CONFIRMATION_REQUIRED]]', '')
              .trim(),
        ));
      } else {
        cleaned.add(m);
      }
    }

    if (mounted) {
      setState(() {
        // Merge: prepend loaded history before any messages added during load.
        final live = _messagesByAgent[agentId] ?? [];
        _messagesByAgent[agentId] = [...cleaned, ...live];
        _initialLoading = false;
      });
      if (cleaned.length < kMessagePageSize) {
        _fullyLoaded.add(agentId);
      }
      _scrollToEnd();
    }
  }

  /// Load older messages when scrolling to the top.
  Future<void> _loadOlderMessages() async {
    if (_loadingOlder || !_hasMore) return;
    final messages = _messages;
    if (messages.isEmpty) return;

    final oldestId = messages.first.id;
    if (oldestId == null) {
      _fullyLoaded.add(_activeAgentId);
      return;
    }

    _loadingOlder = true;
    setState(() {}); // Show loading indicator.

    final service = ref.read(chatHistoryServiceProvider);
    final older = await service.loadOlder(
      _activeAgentId,
      beforeId: oldestId,
    );

    if (!mounted) return;

    setState(() {
      if (older.isEmpty) {
        _fullyLoaded.add(_activeAgentId);
      } else {
        messages.insertAll(0, older);
        if (older.length < kMessagePageSize) {
          _fullyLoaded.add(_activeAgentId);
        }
      }
      _loadingOlder = false;
    });
  }

  Future<void> _persistMessage(ChatMessage message) async {
    await ref
        .read(chatHistoryServiceProvider)
        .addMessage(_activeAgentId, message);
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final agents = ref.watch(agentListProvider);
    final providers = ref.watch(providerListProvider).value ?? [];

    final agent = _activeAgentId == 'default'
        ? (agents.isNotEmpty ? agents.first : null)
        : agents.where((a) => a.id == _activeAgentId).firstOrNull;
    final agentName = agent?.name ?? 'Chat';
    final provider = agent != null
        ? providers.where((p) => p.id == agent.providerId).firstOrNull
        : null;
    final modelName = provider?.model;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(agentName),
            if (modelName != null) ...[
              const SizedBox(height: 3),
              Text(
                modelName,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w400,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ],
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
              icon: const Icon(Icons.people_outline_rounded),
              tooltip: s.switchAgent,
              onPressed: () => Scaffold.of(ctx).openEndDrawer(),
            ),
          ),
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
          child: agent == null
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
                        ? const Center(
                            child: SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            ),
                          )
                        : _messages.isEmpty && !_sending
                            ? _ChatEmptyState(s: s)
                            : ListView.builder(
                            controller: _scroll,
                            padding:
                                const EdgeInsets.fromLTRB(16, 12, 16, 12),
                            // +1 loading indicator at top, +N debug bubbles, +1 thinking.
                            itemCount: (_loadingOlder ? 1 : 0) +
                                _messages.length +
                                (_manager
                                        ?.sessionFor(_activeAgentId)
                                        .debugMessages
                                        .length ??
                                    0) +
                                (_sending ? 1 : 0),
                            itemBuilder: (context, i) {
                              // Loading indicator at top.
                              if (_loadingOlder && i == 0) {
                                return const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 8),
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
                              final debugBubbles = _manager
                                      ?.sessionFor(_activeAgentId)
                                      .debugMessages ??
                                  const <ChatMessage>[];
                              final msgIndex =
                                  i - (_loadingOlder ? 1 : 0);
                              // Order: messages → debug bubbles → thinking.
                              if (msgIndex < _messages.length) {
                                return RepaintBoundary(
                                  child: _Bubble(
                                    msg: _messages[msgIndex],
                                    onConfirmAction: (action) =>
                                        _handleConfirmation(action, msgIndex),
                                  ),
                                );
                              }
                              final debugIdx = msgIndex - _messages.length;
                              if (debugIdx < debugBubbles.length) {
                                return RepaintBoundary(
                                  child: _Bubble(msg: debugBubbles[debugIdx]),
                                );
                              }
                              // Thinking bubble at very bottom.
                              return const _ThinkingBubble();
                            },
                          ),
                  ),
            _ChatInput(
              controller: _input,
              sending: _sending,
              onSend: _send,
              s: s,
            ),
          ],
        ),
      ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.msg, this.onConfirmAction});
  final ChatMessage msg;
  final void Function(String action)? onConfirmAction;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final isUser = msg.role == 'user';
    final isConfirmation = msg.content.contains('[[CONFIRMATION_REQUIRED]]');
    final displayContent =
        msg.content.replaceAll('\n\n[[CONFIRMATION_REQUIRED]]', '').trim();

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        decoration: BoxDecoration(
          color: isUser ? cs.primary : extras.card,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
          border: isUser ? null : Border.all(color: extras.subtleBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isUser)
              Text(
                displayContent,
                style: TextStyle(
                  color: cs.onPrimary,
                  fontSize: 14,
                  height: 1.4,
                ),
              )
            else
              MarkdownBody(
                data: displayContent,
                selectable: true,
                shrinkWrap: true,
                styleSheet: MarkdownStyleSheet(
                  p: TextStyle(
                    color: cs.onSurface,
                    fontSize: 14,
                    height: 1.4,
                  ),
                  strong: TextStyle(
                    color: cs.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                  em: TextStyle(
                    color: cs.onSurface,
                    fontStyle: FontStyle.italic,
                  ),
                  code: TextStyle(
                    color: cs.primary,
                    backgroundColor:
                        cs.primary.withValues(alpha: 0.08),
                    fontSize: 13,
                  ),
                  listBullet: TextStyle(
                    color: cs.onSurface,
                    fontSize: 14,
                  ),
                ),
              ),
            // Confirmation action buttons.
            if (isConfirmation && onConfirmAction != null) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _ConfirmButton(
                    label: 'Accept',
                    icon: Icons.check_rounded,
                    color: cs.primary,
                    onTap: () => onConfirmAction!('accept'),
                  ),
                  _ConfirmButton(
                    label: 'Always',
                    icon: Icons.done_all_rounded,
                    color: Colors.green,
                    onTap: () => onConfirmAction!('always_accept'),
                  ),
                  _ConfirmButton(
                    label: 'Reject',
                    icon: Icons.close_rounded,
                    color: Colors.redAccent,
                    onTap: () => onConfirmAction!('reject'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ConfirmButton extends StatelessWidget {
  const _ConfirmButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withValues(alpha: 0.12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: color.withValues(alpha: 0.3)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
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
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatInput extends StatefulWidget {
  const _ChatInput({
    required this.controller,
    required this.sending,
    required this.onSend,
    required this.s,
  });

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;
  final AppStrings s;

  @override
  State<_ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<_ChatInput> {
  static const _commands = [
    _SlashCommand('/clear', 'Clear chat history & context'),
    _SlashCommand('/help', 'Show available commands'),
    _SlashCommand('/status', 'Show agent & context info'),
    _SlashCommand('/reset', 'Reset context only'),
    _SlashCommand('/model', 'Show current model info'),
    _SlashCommand('/compact', 'Compact context window'),
    _SlashCommand('/cron', 'Show scheduled tasks'),
  ];

  List<_SlashCommand> _filtered = [];
  bool _showSuggestions = false;
  File? _attachedFile;
  String? _attachedFileName;

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
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withData: false,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    if (file.path == null) return;

    // 1MB limit.
    final sizeBytes = file.size;
    if (sizeBytes > 1024 * 1024) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('File too large. Max size is 1 MB.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    setState(() {
      _attachedFile = File(file.path!);
      _attachedFileName = file.name;
    });
  }

  void _removeFile() {
    setState(() {
      _attachedFile = null;
      _attachedFileName = null;
    });
  }

  void _onTextChanged() {
    final text = widget.controller.text;
    if (text.startsWith('/')) {
      final query = text.toLowerCase();
      final matches =
          _commands.where((c) => c.command.startsWith(query)).toList();
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
            decoration: BoxDecoration(
              color: extras.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: extras.subtleBorder),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: _filtered.map((cmd) {
                return InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => _selectCommand(cmd.command),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
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
        // File preview chip.
        if (_attachedFile != null)
          Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: extras.card,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: extras.subtleBorder),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.attach_file_rounded,
                  size: 18,
                  color: cs.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _attachedFileName ?? 'File',
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                GestureDetector(
                  onTap: _removeFile,
                  child: Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
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
                    suffixIcon: IconButton(
                      icon: Icon(
                        Icons.attach_file_rounded,
                        size: 20,
                        color: cs.onSurfaceVariant,
                      ),
                      onPressed: _pickFile,
                    ),
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
                color: cs.primary,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: widget.sending ? null : widget.onSend,
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: widget.sending
                        ? Padding(
                            padding: const EdgeInsets.all(14),
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: cs.onPrimary,
                            ),
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
class _AgentDrawer extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;

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
                            'No agents yet',
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
                          horizontal: 12, vertical: 4),
                      itemCount: agents.length,
                      itemBuilder: (context, i) {
                        final agent = agents[i];
                        final isActive = agent.id == currentAgentId ||
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
                                    horizontal: 14, vertical: 12),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 36,
                                      height: 36,
                                      decoration: BoxDecoration(
                                        color: isActive
                                            ? cs.primary
                                                .withValues(alpha: 0.15)
                                            : cs.onSurfaceVariant
                                                .withValues(alpha: 0.08),
                                        borderRadius:
                                            BorderRadius.circular(10),
                                      ),
                                      alignment: Alignment.center,
                                      child: Icon(
                                        Icons.smart_toy_rounded,
                                        size: 18,
                                        color: isActive
                                            ? cs.primary
                                            : cs.onSurfaceVariant,
                                      ),
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
                                    if (isActive)
                                      Icon(
                                        Icons.check_rounded,
                                        size: 18,
                                        color: cs.primary,
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

