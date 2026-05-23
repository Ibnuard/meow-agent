import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../services/llm/openai_compatible_client.dart';
import '../../agents/data/agent_model.dart';
import '../../agents/data/agent_repository.dart';
import '../../providers/data/provider_config.dart';
import '../../providers/data/provider_repository.dart';
import '../../settings/data/llm_provider_config.dart';
import '../data/chat_history_service.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.agentId});

  final String agentId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  // Per-agent message history — loaded from local storage.
  final Map<String, List<ChatMessage>> _messagesByAgent = {};
  bool _sending = false;
  late String _activeAgentId;

  @override
  void initState() {
    super.initState();
    // Resolve 'default' to actual agent ID so history is per-agent.
    final agents = ref.read(agentListProvider);
    if (widget.agentId == 'default' && agents.isNotEmpty) {
      _activeAgentId = agents.first.id;
    } else {
      _activeAgentId = widget.agentId;
    }
    _loadHistory(_activeAgentId);
  }

  List<ChatMessage> get _messages =>
      _messagesByAgent.putIfAbsent(_activeAgentId, () => []);

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
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

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;

    // Handle slash commands locally.
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
    final userMsg = ChatMessage(role: 'user', content: text);
    setState(() {
      _messages.add(userMsg);
      _sending = true;
    });
    _input.clear();
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
      setState(() {
        _messages.add(replyMsg);
        _sending = false;
      });
      _persistMessage(replyMsg);
      _scrollToEnd();
    } catch (e) {
      if (!mounted) return;
      final errorMsg = ChatMessage(role: 'assistant', content: 'Error: $e');
      setState(() {
        _messages.add(errorMsg);
        _sending = false;
      });
      _persistMessage(errorMsg);
      _scrollToEnd();
    }
  }

  List<Map<String, String>> _buildHistory() {
    final agents = ref.read(agentListProvider);
    final agent = _activeAgentId == 'default'
        ? (agents.isNotEmpty ? agents.first : null)
        : agents.where((a) => a.id == _activeAgentId).firstOrNull;
    final name = agent?.name ?? 'Assistant';
    final isFirstChat = _messages.where((m) => m.role == 'user').length <= 1;

    final systemPrompt = StringBuffer()
      ..writeln('You are $name, an Android-native AI assistant.')
      ..writeln('Be concise and helpful.')
      ..writeln('Use Indonesian by default unless requested otherwise.')
      ..writeln()
      ..writeln('Behavior rules:')
      ..writeln('- Keep responses concise and practical.')
      ..writeln('- Avoid exaggerated futuristic language.')
      ..writeln('- Ask before sensitive actions.');

    if (isFirstChat) {
      systemPrompt
        ..writeln()
        ..writeln('FIRST INTRODUCTION RULE:')
        ..writeln(
            'This is the user\'s first message. Before handling their request, '
            'politely ask what name or nickname they\'d like to be called. '
            'Keep it natural and brief. Example: '
            '"Sebelum lanjut, boleh tahu nama panggilan kamu? '
            'Biar aku bisa lebih personal bantu kamu."');
    }

    return [
      {'role': 'system', 'content': systemPrompt.toString().trim()},
      ..._messages.map((m) => {'role': m.role, 'content': m.content}),
    ];
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
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
        response = '✓ Context compacted. Older messages will be summarized '
            'to save token space on next request.';
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

  void _switchAgent(String agentId) {
    if (agentId == _activeAgentId) return;
    _loadHistory(agentId);
    setState(() => _activeAgentId = agentId);
  }

  Future<void> _loadHistory(String agentId) async {
    if (_messagesByAgent.containsKey(agentId)) return;
    final history =
        await ref.read(chatHistoryServiceProvider).load(agentId);
    if (mounted) {
      setState(() => _messagesByAgent[agentId] = history);
      _scrollToEnd();
    }
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
              tooltip: 'Switch Agent',
              onPressed: () => Scaffold.of(ctx).openEndDrawer(),
            ),
          ),
        ],
      ),
      endDrawer: _AgentDrawer(
        agents: agents,
        currentAgentId: _activeAgentId,
        onSwitch: _switchAgent,
      ),
      body: SafeArea(
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
                      'No agent configured',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Create an agent to start chatting.',
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 20),
                    TextButton.icon(
                      onPressed: () => context.push('/agents/new'),
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Add Agent'),
                    ),
                  ],
                ),
              )
            : Column(
                children: [
                  Expanded(
                    child: _messages.isEmpty && !_sending
                        ? const _ChatEmptyState()
                        : ListView.builder(
                            controller: _scroll,
                            padding:
                                const EdgeInsets.fromLTRB(16, 12, 16, 12),
                            itemCount:
                                _messages.length + (_sending ? 1 : 0),
                            itemBuilder: (context, i) {
                              if (i == _messages.length && _sending) {
                                return const _ThinkingBubble();
                              }
                              return _Bubble(msg: _messages[i]);
                            },
                          ),
                  ),
            _ChatInput(
              controller: _input,
              sending: _sending,
              onSend: _send,
            ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.msg});
  final ChatMessage msg;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final isUser = msg.role == 'user';
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
        child: Text(
          msg.content.trim(),
          style: TextStyle(
            color: isUser ? cs.onPrimary : cs.onSurface,
            fontSize: 14,
            height: 1.4,
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
  const _ChatEmptyState();

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
              'Say hi to your agent',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Ask anything to get started.',
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
  });

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

  @override
  State<_ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<_ChatInput> {
  static const _commands = [
    _SlashCommand('/clear', 'Clear chat history & context'),
    _SlashCommand('/help', 'Show available commands'),
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
                    hintText: 'Type a message',
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
  });

  final List<AgentModel> agents;
  final String currentAgentId;
  final ValueChanged<String> onSwitch;

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
                'Agents',
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
                            'Create one to start chatting.',
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
                            label: const Text('Add Agent'),
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

