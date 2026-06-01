import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../app/theme.dart';
import '../../../app/widgets/widgets.dart';
import '../../../services/agent_runtime/context_compactor.dart';
import '../../../services/agent_runtime/context_report.dart';
import '../../../services/agent_runtime/runtime_models.dart';
import '../../../services/workspace/workspace_file_service.dart';
import '../../../services/llm/openai_compatible_client.dart';
import '../../agents/data/agent_model.dart';
import '../../agents/data/agent_repository.dart';
import '../../agents/data/workspace_service.dart';
import '../../modules/calendar/calendar_screen.dart';
import '../../modules/workflows/workflow_list_screen.dart';
import '../../providers/data/provider_config.dart';
import '../../providers/data/provider_repository.dart';
import '../../settings/data/app_language_provider.dart';
import '../../settings/data/llm_debug_provider.dart';
import '../../settings/data/llm_provider_config.dart';
import '../data/chat_history_service.dart';
import '../data/chat_runtime_log_service.dart';
import '../data/chat_runtime_manager.dart';
import '../data/unread_service.dart';
import 'chat_shimmer.dart';

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

  /// Message currently being replied to (WhatsApp-style quote). Null when no
  /// active reply context. Cleared after send or when user taps the X.
  ChatMessage? _replyTo;

  /// Attached files for the next send (synced from _ChatInput).
  List<AttachedFile> _attachments = [];
  final _chatInputKey = GlobalKey<_ChatInputState>();

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

    // Mark this agent's chat as in-foreground so the unread counter clears
    // and incoming messages don't bump the badge while user is reading.
    UnreadService.instance.setActive(_activeAgentId);

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
    UnreadService.instance.clearActive(_activeAgentId);
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

  /// Show long-press action sheet for a chat bubble.
  void _showMessageActions(ChatMessage msg) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(
                  ctx,
                ).colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.reply_rounded),
              title: Text(s.reply),
              onTap: () {
                Navigator.pop(ctx);
                _handleReply(msg);
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: Text(s.copyText),
              onTap: () {
                Navigator.pop(ctx);
                _handleCopy(msg);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _handleCopy(ChatMessage msg) {
    final text = _cleanContent(msg.content);
    Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(s.copiedToClipboard),
          duration: const Duration(seconds: 1),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _handleReply(ChatMessage msg) {
    final clean = _cleanContent(msg.content);
    if (clean.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(s.cannotReplyEmpty),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    setState(() => _replyTo = msg);
    // Auto-focus the input.
    FocusScope.of(context).requestFocus(FocusNode());
  }

  void _cancelReply() {
    setState(() => _replyTo = null);
  }

  /// Strip all sentinels (confirmation, reply-quote opening + closing) and
  /// trim whitespace. Used everywhere we need the "clean" user-visible text.
  static String _cleanContent(String raw) {
    return raw
        .replaceAll(
          RegExp(
            r'\[\[REPLY_QUOTE:[^\]]+\]\].*?\[\[/REPLY_QUOTE\]\]\n?',
            dotAll: true,
          ),
          '',
        )
        .replaceAll('\n\n[[CONFIRMATION_REQUIRED]]', '')
        .replaceAll('[[CONFIRMATION_REQUIRED]]', '')
        .trim();
  }

  /// Wrap user text with a quote sentinel so the LLM and the UI both see
  /// what's being referenced. Sentinels are stripped from display by [_Bubble]
  /// which renders the quote as a styled inline chip above the user's text.
  String _buildReplyPayload(ChatMessage quoted, String userText) {
    final quotedText = _cleanContent(quoted.content);
    // Truncate very long quotes so we don't blow up context.
    final truncated = quotedText.length > 280
        ? '${quotedText.substring(0, 280)}…'
        : quotedText;
    final role = quoted.role == 'user' ? 'You' : 'Agent';
    return '[[REPLY_QUOTE:$role]]$truncated[[/REPLY_QUOTE]]\n$userText';
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
    if (provider == null || !provider.isComplete) {
      final agents = ref.read(agentListProvider);
      final agent = _activeAgentId == 'default'
          ? (agents.isNotEmpty ? agents.first : null)
          : agents.where((a) => a.id == _activeAgentId).firstOrNull;
      final agentName = agent?.name ?? _activeAgentId;
      final userMsg = ChatMessage(role: 'user', content: text);
      final botMsg = ChatMessage(
        role: 'assistant',
        content: '⚠️ ${s.providerMissingBody(agentName)}',
        actions: [
          ResultAction(
            label: s.manageProvidersAction,
            icon: 'dns_outlined',
            type: 'navigate',
            target: AppRoutes.providerList,
          ),
        ],
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

    _input.clear();
    final replyContext = _replyTo;
    if (replyContext != null) {
      setState(() => _replyTo = null);
    }

    // Build the user-visible message with an optional reply quote.
    // The quote is included in both the displayed bubble and the LLM payload
    // so the agent has the full context of what was referenced.
    final messageText = replyContext == null
        ? text
        : _buildReplyPayload(replyContext, text);

    // Append attached file names so the chat bubble shows what was sent.
    final attachmentNames =
        _chatInputKey.currentState?._attachmentsSnapshot ?? _attachments;
    final displayText = _attachments.isEmpty
        ? messageText
        : '$messageText\n\n📎 ${attachmentNames.map((a) => a.name).join(", ")}';

    // Optimistically show the user message immediately — it always lands
    // in history regardless of context exhaustion.
    final userMsg = ChatMessage(role: 'user', content: displayText);
    setState(() => _messages.add(userMsg));
    _scrollToEnd();

    // Check context BEFORE calling the runtime. If the threshold was hit
    // and auto-compact is off, surface a warning but DO NOT send the user
    // message to the agent — there is no point because it will fail. The
    // user message is already visible in the chat.
    final blocked = await _autoCompactIfNeeded();
    if (blocked) return;

    // Manager persists user msg + final reply, listener reloads history.
    final mgr = _ensureManager();
    final recent = _messages.where((m) => m.id != null).toList();
    mgr.send(
      agentId: _activeAgentId,
      userMessage: messageText,
      recentMessages: recent,
      attachments: _attachments,
    );
    _attachments = [];
    _chatInputKey.currentState?.clearAttachments();
    return;
  }

  /// Reload history from disk after manager persists a reply.
  /// Full replacement of the 10 newest messages keeps order correct and
  /// avoids duplicate-detection bugs from incremental append.
  Future<void> _reloadHistory(String agentId) async {
    final service = ref.read(chatHistoryServiceProvider);
    final history = await service.loadLatest(agentId);

    final hasPending = _manager?.sessionFor(agentId).pendingTool != null;
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
      final isLiveConfirmation = hasPending && i == lastAssistantIdx;
      if (!isLiveConfirmation &&
          m.content.contains('[[CONFIRMATION_REQUIRED]]')) {
        cleaned.add(
          ChatMessage(
            id: m.id,
            role: m.role,
            content: m.content
                .replaceAll('\n\n[[CONFIRMATION_REQUIRED]]', '')
                .trim(),
            actions: m.actions,
          ),
        );
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

  Future<void> _handleResultAction(
    ResultAction action, [
    ChatMessage? sourceMessage,
  ]) async {
    switch (action.type) {
      case 'select_model':
        await _handleSelectModelAction(action, sourceMessage);
        break;
      case 'navigate':
        // Special-case screens not in the router → push directly.
        if (action.target == '/modules/calendar') {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const CalendarScreen()),
          );
        } else if (action.target == '/modules/workflows') {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const WorkflowListScreen()),
          );
        } else {
          if (!mounted) return;
          context.push(action.target);
        }
        break;
      case 'open_folder':
        // target = agentName.
        final ws = ref.read(workspaceServiceProvider);
        await ws.openInFileManager(action.target);
        break;
      case 'open_url':
        // Reserved for future use.
        break;
    }
  }

  Future<void> _handleSelectModelAction(
    ResultAction action,
    ChatMessage? sourceMessage,
  ) async {
    final model = action.target.trim();
    if (model.isEmpty) return;
    final agents = ref.read(agentListProvider);
    final providers = ref.read(providerListProvider).value ?? [];
    final agent = _activeAgentId == 'default'
        ? (agents.isNotEmpty ? agents.first : null)
        : agents.where((a) => a.id == _activeAgentId).firstOrNull;
    if (agent == null) return;
    final provider = providers
        .where((p) => p.id == agent.providerId)
        .firstOrNull;
    if (provider == null || !provider.models.contains(model)) return;

    await ref
        .read(agentListProvider.notifier)
        .save(agent.copyWith(model: model));
    final fixed = ChatMessage(
      id: sourceMessage?.id,
      role: 'assistant',
      timestamp: sourceMessage?.timestamp,
      content: s.modelUpdated(provider.nickname, model),
    );
    if (!mounted) return;
    setState(() {
      final idx = sourceMessage == null
          ? -1
          : _messages.indexWhere(
              (m) => identical(m, sourceMessage) || m.id == sourceMessage.id,
            );
      if (idx >= 0) {
        _messages[idx] = fixed;
      }
    });
    if (fixed.id != null) {
      await ref.read(chatHistoryServiceProvider).updateMessage(fixed);
    }
  }

  /// Delete a single message from SQLite by its row id.
  Future<void> _deletePersistedMessage(int id) async {
    final service = ref.read(chatHistoryServiceProvider);
    await service.deleteMessage(id);
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
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
    _scrollToEnd();

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
        response = _buildCommandHelp(ref.read(llmDebugModeProvider));
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
              ? '\n• Model: ${provider.effectiveModel(agentModel)}'
              : '\n• Model: (provider default)';
          response =
              '🤖 Model Info:\n'
              '• Provider: ${provider.nickname}$modelInfo\n'
              '• Endpoint: ${provider.baseUrl}';
        } else {
          response = s.noProviderConnected;
        }
      case '/set-model':
        await _showModelsCommandBubble();
        return;
      case '/compact':
        await _performCompaction();
        return;
      case '/status':
        response = _buildStatusInfo();
      case '/context':
        response = await _buildContextReport();
      case '/cron':
        response = s.cronNoJobs;
      case '/log':
        response = await _buildRuntimeLogReport();
      case '/clearlog':
        response = await _clearRuntimeLog();
      default:
        response = s.unknownCommand(cmd);
    }

    final botMsg = ChatMessage(role: 'assistant', content: response);
    setState(() => _messages.add(botMsg));
    if (shouldPersist) await _persistMessage(botMsg);
    _scrollToEnd();
  }

  Future<void> _showModelsCommandBubble() async {
    final agents = ref.read(agentListProvider);
    final providers = ref.read(providerListProvider).value ?? [];
    final agent = _activeAgentId == 'default'
        ? (agents.isNotEmpty ? agents.first : null)
        : agents.where((a) => a.id == _activeAgentId).firstOrNull;
    final provider = agent == null
        ? null
        : providers.where((p) => p.id == agent.providerId).firstOrNull;

    final ChatMessage botMsg;
    if (agent == null || provider == null || provider.models.isEmpty) {
      botMsg = ChatMessage(
        role: 'assistant',
        content: s.noProviderOrModel,
      );
    } else {
      final selected = provider.effectiveModel(agent.model);
      botMsg = ChatMessage(
        role: 'assistant',
        content: s.chooseModelPrompt(selected),
        actions: [
          for (final model in provider.models)
            ResultAction(
              label: model == selected ? '$model ✓' : model,
              icon: provider.visionModels.contains(model)
                  ? 'visibility_rounded'
                  : 'memory_rounded',
              type: 'select_model',
              target: model,
              params: {'providerId': provider.id},
            ),
        ],
      );
    }

    setState(() => _messages.add(botMsg));
    final persisted = await _persistMessage(botMsg);
    if (!mounted) return;
    setState(() {
      final idx = _messages.indexWhere((m) => identical(m, botMsg));
      if (idx >= 0) _messages[idx] = persisted;
    });
    _scrollToEnd();
  }

String _buildCommandHelp(bool debugMode) {
    final buffer = StringBuffer()
      ..writeln(s.helpAvailableCommands)
      ..writeln('- /clear - ${s.helpSlashClear}')
      ..writeln('- /help - ${s.helpSlashHelp}')
      ..writeln('- /status - ${s.helpSlashStatus}')
      ..writeln('- /context - ${s.helpSlashContext}')
      ..writeln('- /reset - ${s.helpSlashReset}')
      ..writeln('- /model - ${s.helpSlashModel}')
      ..writeln('- /set-model - ${s.helpSlashSetModel}')
      ..writeln('- /compact - ${s.helpSlashCompact}')
      ..write('- /cron - ${s.helpSlashCron}');
    if (debugMode) {
      buffer
        ..writeln()
        ..writeln('- /log - ${s.helpSlashLog}')
        ..write('- /clearlog - ${s.helpSlashClearlog}');
    }
    return buffer.toString();
  }

  Future<String> _buildRuntimeLogReport() async {
    if (!ref.read(llmDebugModeProvider)) {
      return s.debugOffForLog;
    }

    final events = await ref
        .read(chatRuntimeLogServiceProvider)
        .loadLast(_activeAgentId);
    if (events.isEmpty) {
      return s.noRuntimeLog;
    }

    String? userMessage;
    final stepEvents = <ChatRuntimeLogEvent>[];
    for (final event in events) {
      if (event.isUserRequest) {
        userMessage = event.data?['message']?.toString();
      } else {
        stepEvents.add(event);
      }
    }

    final buffer = StringBuffer(s.runtimeLogHeader);
    if (userMessage != null && userMessage.trim().isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Command: ${_truncateLogText(userMessage, 220)}');
    }

    if (stepEvents.isEmpty) {
      buffer
        ..writeln()
        ..write(s.noRuntimeSteps);
      return buffer.toString();
    }

    for (var i = 0; i < stepEvents.length; i++) {
      final event = stepEvents[i];
      buffer
        ..writeln()
        ..write('${i + 1}. ${_formatRuntimeLogLine(event)}');
      final details = _formatRuntimeLogDetails(event);
      if (details.isNotEmpty) {
        buffer
          ..writeln()
          ..write('   $details');
      }
    }

    return buffer.toString();
  }

  Future<String> _clearRuntimeLog() async {
    if (!ref.read(llmDebugModeProvider)) {
      return s.debugOffForClearlog;
    }

    await ref.read(chatRuntimeLogServiceProvider).clear(_activeAgentId);
    return s.runtimeLogCleared;
  }

  String _formatRuntimeLogLine(ChatRuntimeLogEvent event) {
    final label = switch (event.type) {
      'state_change' => event.data?['state']?.toString() ?? 'state',
      'llm_decision' => 'llm',
      'tool_call' => 'tool call',
      'tool_result' => 'tool result',
      'narrative' => 'narrative',
      'error' => 'error',
      'confirmation' => 'confirmation',
      'cancelled' => 'cancelled',
      _ => event.type,
    };
    return '[$label] ${_truncateLogText(event.message, 260)}';
  }

  String _formatRuntimeLogDetails(ChatRuntimeLogEvent event) {
    final data = event.data;
    if (data == null || data.isEmpty) return '';

    switch (event.type) {
      case 'state_change':
        return '';
      case 'tool_call':
        return _compactLogJson({
          'tool': data['name'],
          'args': data['args'],
          'risk': data['risk'],
        });
      case 'tool_result':
        final details = <String, dynamic>{
          'tool': data['tool'],
          'success': data['success'],
        };
        if (data['error'] != null) {
          details['error'] = data['error'];
        }
        if (data['data'] != null) {
          details['data'] = data['data'];
        }
        return _compactLogJson(details);
      case 'error':
        return _truncateLogText(data['error']?.toString() ?? '', 700);
      default:
        return _compactLogJson(data);
    }
  }

  String _compactLogJson(Object? value, {int maxChars = 700}) {
    if (value == null) return '';
    try {
      return _truncateLogText(jsonEncode(value), maxChars);
    } catch (_) {
      return _truncateLogText(value.toString(), maxChars);
    }
  }

  String _truncateLogText(String text, int maxChars) {
    final compact = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.length <= maxChars) return compact;
    return '${compact.substring(0, maxChars)}...';
  }

  Future<String> _buildContextReport() async {
    final agents = ref.read(agentListProvider);
    final agent = _activeAgentId == 'default'
        ? (agents.isNotEmpty ? agents.first : null)
        : agents.where((a) => a.id == _activeAgentId).firstOrNull;
    if (agent == null) {
      return s.noActiveAgent;
    }

    final languagePref = ref.read(appLanguageProvider);
    final languageCode = resolveLanguageCode(languagePref);
    return ContextReport.build(
      agentName: agent.name,
      languageCode: languageCode,
      messages: _messages,
      maxContextLength: agent.maxContextLength,
      userMessageHint: _input.text,
    );
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

    final pct = usage.percentage.toStringAsFixed(1);
    final compactNote = usage.needsCompact
        ? s.autoCompactThresholdNote
        : s.autoCompactOkNote;

    final usageLine = usage.source == 'measured'
        ? s.usageMeasured(pct, maxCtx, usage.chatTokens)
        : s.usageEstimated(usage.chatTokens, pct, maxCtx);

    final agentName = agent?.name ?? 'default';
    final providerName = provider?.nickname ?? '—';
    final providerModel = provider?.model ?? '—';

    final buf = StringBuffer()
      ..writeln(s.statusAgentTitle(agentName))
      ..writeln()
      ..writeln(s.statusConnected(providerName, providerModel))
      ..writeln()
      ..writeln(s.statusDetails)
      ..writeln()
      ..writeln('- ${s.statusApp}')
      ..writeln('- ${s.statusActiveAgent(agentName)}')
      ..writeln('- ${s.statusProvider(providerName)}')
      ..writeln('- ${s.statusModel(providerModel)}')
      ..writeln('- ${s.statusMessages(_messages.length)}')
      ..writeln()
      ..writeln(usageLine)
      ..writeln()
      ..writeln(compactNote);

    return buf.toString().trim();
  }

  /// Perform manual /compact.
  Future<void> _performCompaction() async {
    final provider = _resolveProvider();
    if (provider == null) {
      final msg = ChatMessage(
        role: 'assistant',
        content: s.cannotCompact,
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
        content: s.contextAlreadyCompact(
          _messages.length,
          ContextCompactor.estimateChatTokens(_messages),
          maxCtx,
        ),
      );
      setState(() => _messages.add(msg));
      _persistMessage(msg);
      _scrollToEnd();
      return;
    }

    // Show compacting indicator.
    final loadingMsg = ChatMessage(
      role: 'assistant',
      content: s.compacting,
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
        await ref
            .read(chatHistoryServiceProvider)
            .addMessage(_activeAgentId, msg);
      }

      // Remove loading indicator and reload.
      setState(() {
        _messages.remove(loadingMsg);
        _messagesByAgent[_activeAgentId] = compacted;
      });

      // Write summary snapshot to workspace.
      final summaryText = compacted.first.content;
      final agentName = agent?.name ?? '';
      if (agentName.isNotEmpty) {
        WorkspaceFileService.writeSummarySnapshot(agentName, summaryText);
      }

      final doneMsg = ChatMessage(
        role: 'assistant',
        content: s.contextCompacted(
          compacted.length,
          ContextCompactor.estimateChatTokens(compacted),
        ),
      );
      setState(() => _messages.add(doneMsg));
      _persistMessage(doneMsg);
      _scrollToEnd();
    } catch (e) {
      setState(() => _messages.remove(loadingMsg));
      final errMsg = ChatMessage(
        role: 'assistant',
        content: s.compactFailed(e.toString()),
      );
      setState(() => _messages.add(errMsg));
      _persistMessage(errMsg);
      _scrollToEnd();
    }
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
      // Silent fail for auto-compact — don't block the user's message.
    }
    return false;
  }

  void _switchAgent(String agentId) {
    if (agentId == _activeAgentId) return;
    UnreadService.instance.clearActive(_activeAgentId);
    UnreadService.instance.setActive(agentId);
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
      final isLiveConfirmation = hasPending && i == lastAssistantIdx;
      if (!isLiveConfirmation &&
          m.content.contains('[[CONFIRMATION_REQUIRED]]')) {
        cleaned.add(
          ChatMessage(
            id: m.id,
            role: m.role,
            content: m.content
                .replaceAll('\n\n[[CONFIRMATION_REQUIRED]]', '')
                .trim(),
            actions: m.actions,
          ),
        );
      } else {
        cleaned.add(m);
      }
    }

    if (mounted) {
      _initialLoading = false;
      setState(() {
        // Merge: prepend loaded history before any messages added during load.
        final live = _messagesByAgent[agentId] ?? [];
        _messagesByAgent[agentId] = [...cleaned, ...live];
      });
      if (cleaned.length < kMessagePageSize) {
        _fullyLoaded.add(agentId);
      }
      // Multi-frame settle: ListView.builder needs several frames to finalize
      // layout with variable-height markdown bubbles. We jumpTo the current
      // maxExtent each frame until it stabilizes, then do one smooth animateTo.
      _settleScrollToEnd();
    }
  }

  /// Repeatedly jump to the bottom over multiple frames until the layout
  /// stabilizes (markdown bubbles have variable heights), then perform one
  /// smooth animated scroll for final polish.
  void _settleScrollToEnd({int attempt = 0}) {
    const maxAttempts = 10;
    if (attempt >= maxAttempts) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients || !mounted) return;
      final extent = _scroll.position.maxScrollExtent;
      final current = _scroll.position.pixels;
      final atBottom = (extent - current).abs() < 1.0;
      // Jump toward the bottom on every frame. Once we've been at the
      // bottom for two consecutive frames (layout settled), finish with
      // a smooth animateTo for polish.
      if (atBottom && attempt > 2) {
        _scroll.animateTo(
          extent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
        return;
      }
      _scroll.jumpTo(extent);
      _settleScrollToEnd(attempt: attempt + 1);
    });
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
      limit: 30,
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
    final modelSupportsVision = modelName != null
        ? provider?.visionModels.contains(modelName) ?? false
        : false;
    final providerCode = provider?.displayCode ?? '';
    final displayModelName = modelName != null && modelName.isNotEmpty
        ? '$providerCode${providerCode.isNotEmpty ? ' • ' : ''}$modelName'
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
          title: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(agentName),
              if (modelName != null && modelName.isNotEmpty) ...[
                const SizedBox(height: 3),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      displayModelName!,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w400,
                        color: modelIsOverride ? cs.primary : cs.onSurfaceVariant,
                      ),
                    ),
                    if (modelSupportsVision) ...[
                      const SizedBox(width: 4),
                      Icon(Icons.visibility_rounded, size: 12, color: cs.primary),
                    ],
                  ],
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
                            ? const ChatShimmer()
                            : _messages.isEmpty && !_sending
                            ? _ChatEmptyState(s: s)
                            : ListView.builder(
                                controller: _scroll,
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  12,
                                  16,
                                  12,
                                ),
                                // +1 loading, +N debug, +1 narrative (when present), +1 thinking.
                                itemCount:
                                    (_loadingOlder ? 1 : 0) +
                                    _messages.length +
                                    (_manager
                                            ?.sessionFor(_activeAgentId)
                                            .debugMessages
                                            .length ??
                                        0) +
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
                                  final debugBubbles =
                                      _manager
                                          ?.sessionFor(_activeAgentId)
                                          .debugMessages ??
                                      const <ChatMessage>[];
                                  final msgIndex = i - (_loadingOlder ? 1 : 0);
                                  // Order: messages → debug bubbles → thinking.
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
                                    final bubble = RepaintBoundary(
                                      child: _Bubble(
                                        msg: current,
                                        isId: isId,
                                        onConfirmAction: (action) =>
                                            _handleConfirmation(
                                              action,
                                              msgIndex,
                                            ),
                                        onActionTap: _handleResultAction,
                                        onLongPress: () =>
                                            _showMessageActions(current),
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
                                  final debugIdx = msgIndex - _messages.length;
                                  if (debugIdx < debugBubbles.length) {
                                    return RepaintBoundary(
                                      child: _Bubble(
                                        msg: debugBubbles[debugIdx],
                                        isId: isId,
                                      ),
                                    );
                                  }
                                  // Narrative bubble — above the thinking dots,
                                  // shown only while sending AND a narrative is set.
                                  final narrative = _manager
                                      ?.sessionFor(_activeAgentId)
                                      .narrativeMessage;
                                  final hasNarrative =
                                      _sending &&
                                      (narrative?.isNotEmpty == true);
                                  final narrativeIdx =
                                      debugIdx - debugBubbles.length;
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
                        onSend: _send,
                        onStop: _stop,
                        replyTo: _replyTo,
                        onCancelReply: _cancelReply,
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

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.msg,
    this.onConfirmAction,
    this.onActionTap,
    this.onLongPress,
    this.isId = false,
  });
  final ChatMessage msg;
  final void Function(String action)? onConfirmAction;
  final void Function(ResultAction action, ChatMessage sourceMessage)?
  onActionTap;
  final VoidCallback? onLongPress;
  final bool isId;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings(isId ? 'id' : 'en');
    final cs = context.cs;
    final extras = context.extras;
    final isUser = msg.role == 'user';
    final isConfirmation = msg.content.contains('[[CONFIRMATION_REQUIRED]]');

    // Extract reply-quote sentinel if present.
    String? quoteRole;
    String? quoteText;
    var rawContent = msg.content;
    final quoteMatch = RegExp(
      r'\[\[REPLY_QUOTE:([^\]]+)\]\](.*?)\[\[/REPLY_QUOTE\]\]\n?',
      dotAll: true,
    ).firstMatch(rawContent);
    if (quoteMatch != null) {
      quoteRole = quoteMatch.group(1);
      quoteText = quoteMatch.group(2)?.trim();
      rawContent = rawContent.replaceFirst(quoteMatch.group(0)!, '');
    }
    final displayContent = rawContent
        .replaceAll('\n\n[[CONFIRMATION_REQUIRED]]', '')
        .replaceAll('[[CONFIRMATION_REQUIRED]]', '')
        .trim();

    // Skip rendering ghost bubbles that have nothing visible to show.
    // These can exist in the DB from before the cancel-guard fix, where
    // engine.run() resolved with an empty finalMessage post-cancellation.
    final hasNothingToShow =
        displayContent.isEmpty &&
        (quoteText == null || quoteText.isEmpty) &&
        msg.actions.isEmpty &&
        !isConfirmation;
    if (hasNothingToShow) {
      return const SizedBox.shrink();
    }

    final bubble = ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.78,
      ),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
        child: IntrinsicWidth(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Reply quote chip (WhatsApp-style).
              if (quoteText != null && quoteText.isNotEmpty) ...[
                Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: isUser
                        ? Colors.white.withValues(alpha: 0.18)
                        : cs.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border(
                      left: BorderSide(
                        color: isUser ? Colors.white70 : cs.primary,
                        width: 3,
                      ),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        quoteRole ?? '',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: isUser ? Colors.white : cs.primary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        quoteText,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: isUser ? Colors.white70 : cs.onSurfaceVariant,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
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
                      backgroundColor: cs.primary.withValues(alpha: 0.08),
                      fontSize: 13,
                    ),
                    listBullet: TextStyle(color: cs.onSurface, fontSize: 14),
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
                      label: s.accept,
                      icon: Icons.check_rounded,
                      color: cs.primary,
                      onTap: () => onConfirmAction!('accept'),
                    ),
                    _ConfirmButton(
                      label: s.always,
                      icon: Icons.done_all_rounded,
                      color: Colors.green,
                      onTap: () => onConfirmAction!('always_accept'),
                    ),
                    _ConfirmButton(
                      label: s.reject,
                      icon: Icons.close_rounded,
                      color: Colors.redAccent,
                      onTap: () => onConfirmAction!('reject'),
                    ),
                  ],
                ),
              ],
              // Contextual result actions (e.g., "Open Calendar").
              if (!isUser && msg.actions.isNotEmpty && onActionTap != null) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: msg.actions
                      .map(
                        (a) => _ResultActionButton(
                          action: a,
                          onTap: () => onActionTap!(a, msg),
                        ),
                      )
                      .toList(),
                ),
              ],
              // Timestamp (WhatsApp-style, bottom-aligned). Respects the system
              // 24H/12H clock preference.
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  _formatBubbleTime(context, msg.timestamp),
                  style: TextStyle(
                    fontSize: 10,
                    color: isUser
                        ? Colors.white.withValues(alpha: 0.7)
                        : cs.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: onLongPress != null
          ? GestureDetector(onLongPress: onLongPress, child: bubble)
          : bubble,
    );
  }

  /// Format a message timestamp following the device's 24H/12H clock setting.
  static String _formatBubbleTime(BuildContext context, DateTime dt) {
    final use24 = MediaQuery.of(context).alwaysUse24HourFormat;
    final tod = TimeOfDay.fromDateTime(dt.toLocal());
    return MaterialLocalizations.of(
      context,
    ).formatTimeOfDay(tod, alwaysUse24HourFormat: use24);
  }
}

/// A floating, centered date separator (WhatsApp/Telegram style) shown above
/// the first message of each day. Renders "Today" / "Yesterday" for recent
/// days and a localized date otherwise.
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
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'Mei',
      'Jun',
      'Jul',
      'Agu',
      'Sep',
      'Okt',
      'Nov',
      'Des',
    ];
    const monthsEn = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final months = isId ? monthsId : monthsEn;
    final mon = months[date.month - 1];
    // Include year only when it's not the current year.
    if (date.year == now.year) return '${date.day} $mon';
    return '${date.day} $mon ${date.year}';
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

class _ResultActionButton extends ConsumerWidget {
  const _ResultActionButton({required this.action, required this.onTap});
  final ResultAction action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = context.cs;
    final label = action.label;

    return Material(
      color: cs.primary.withValues(alpha: 0.12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: cs.primary.withValues(alpha: 0.3)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_iconFor(action.icon), size: 14, color: cs.primary),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: cs.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _iconFor(String name) {
    switch (name) {
      case 'calendar_month_rounded':
        return Icons.calendar_month_rounded;
      case 'note_outlined':
        return Icons.note_outlined;
      case 'folder_open_rounded':
        return Icons.folder_open_rounded;
      case 'open_in_new_rounded':
        return Icons.open_in_new_rounded;
      case 'schedule_rounded':
        return Icons.schedule_rounded;
      case 'visibility_rounded':
        return Icons.visibility_rounded;
      case 'memory_rounded':
        return Icons.memory_rounded;
      default:
        return Icons.arrow_forward_rounded;
    }
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
    if (t.contains('confirm') || t.contains('konfirmasi')) return '⏸️';
    if (t.contains('check') || t.contains('cek') || t.contains('hasil')) {
      return '🔍';
    }
    if (t.contains('plan') || t.contains('rencana') || t.contains('langkah')) {
      return '🧭';
    }
    if (t.contains('write') ||
        t.contains('compos') ||
        t.contains('jawaban') ||
        t.contains('reply')) {
      return '✍️';
    }
    if (t.contains('try') ||
        t.contains('coba') ||
        t.contains('different') ||
        t.contains('lain')) {
      return '🔁';
    }
    if (t.contains('execut') ||
        t.contains('mengerjakan') ||
        t.contains('working') ||
        t.contains('progress')) {
      return '⚙️';
    }
    if (t.contains('ask') || t.contains('quest') || t.contains('pertanyaan')) {
      return '💬';
    }
    return '✨';
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
                    // corners stay intact — non-uniform Border widths break
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
                children: List.generate(_attachments.length, (i) {
                  final a = _attachments[i];
                  return Padding(
                    padding: EdgeInsets.only(top: i == 0 ? 0 : 6),
                    child: Container(
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
