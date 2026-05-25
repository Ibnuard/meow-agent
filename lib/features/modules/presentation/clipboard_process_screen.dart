import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../services/llm/openai_compatible_client.dart';
import '../../agents/data/agent_repository.dart';
import '../../providers/data/provider_repository.dart';
import '../../settings/data/app_language_provider.dart';
import '../../settings/data/llm_provider_config.dart';

/// Actions available for processing shared/clipboard text.
enum ClipboardAction {
  sendToChat('Send to Chat', 'Open in chat with selected agent', Icons.chat_bubble_outline_rounded),
  translate('Translate', 'Translate to English', Icons.translate_rounded),
  summarize('Summarize', 'Summarize the text', Icons.compress_rounded),
  rewrite('Rewrite', 'Rewrite more clearly', Icons.edit_note_rounded),
  explain('Explain', 'Explain in simple terms', Icons.lightbulb_outline_rounded),
  grammar('Fix Grammar', 'Fix grammar & spelling', Icons.spellcheck_rounded),
  reply('Draft Reply', 'Draft a reply to this', Icons.reply_rounded);

  const ClipboardAction(this.label, this.description, this.icon);
  final String label;
  final String description;
  final IconData icon;
}

/// Screen for processing shared/clipboard text with AI.
class ClipboardProcessScreen extends ConsumerStatefulWidget {
  const ClipboardProcessScreen({super.key, required this.inputText});

  final String inputText;

  @override
  ConsumerState<ClipboardProcessScreen> createState() =>
      _ClipboardProcessScreenState();
}

class _ClipboardProcessScreenState
    extends ConsumerState<ClipboardProcessScreen> {
  String? _result;
  bool _processing = false;
  ClipboardAction? _selectedAction;
  String? _selectedAgentId;
  final _customPrompt = TextEditingController();

  AppStrings get s {
    final langPref = ref.read(appLanguageProvider);
    return AppStrings(resolveLanguageCode(langPref));
  }

  @override
  void initState() {
    super.initState();
    final agents = ref.read(agentListProvider);
    if (agents.isNotEmpty) {
      _selectedAgentId = agents.first.id;
    }
  }

  @override
  void dispose() {
    _customPrompt.dispose();
    super.dispose();
  }

  Future<void> _processCustom() async {
    final prompt = _customPrompt.text.trim();
    if (prompt.isEmpty) return;
    FocusManager.instance.primaryFocus?.unfocus();

    setState(() {
      _selectedAction = null;
      _processing = true;
      _result = null;
    });

    final agents = ref.read(agentListProvider);
    final providers =
        await ref.read(providerRepositoryProvider).loadAll();

    if (agents.isEmpty || _selectedAgentId == null) {
      setState(() {
        _result = '⚠️ No agent configured.';
        _processing = false;
      });
      return;
    }

    final agent =
        agents.where((a) => a.id == _selectedAgentId).firstOrNull;
    final provider =
        providers.where((p) => p.id == agent?.providerId).firstOrNull;
    if (agent == null || provider == null || !provider.isComplete) {
      setState(() {
        _result = '⚠️ Provider not configured for selected agent.';
        _processing = false;
      });
      return;
    }

    try {
      final llmConfig = LlmProviderConfig(
        baseUrl: provider.baseUrl,
        apiKey: provider.apiKey,
        model: provider.model,
      );
      final reply = await OpenAiCompatibleClient().chat(
        config: llmConfig,
        messages: [
          {
            'role': 'system',
            'content':
                'Apply the following user instruction to the provided text. '
                    'Output only the result, nothing else.',
          },
          {
            'role': 'user',
            'content':
                'Instruction: $prompt\n\nText:\n${widget.inputText}',
          },
        ],
      );
      if (mounted) {
        setState(() {
          _result = reply;
          _processing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _result = 'Error: $e';
          _processing = false;
        });
      }
    }
  }

  Future<void> _process(ClipboardAction action) async {
    // Intercept "Send to Chat" — navigate without LLM processing.
    if (action == ClipboardAction.sendToChat) {
      if (_selectedAgentId == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No agent selected.')),
        );
        return;
      }
      final encoded = Uri.encodeComponent(widget.inputText);
      context.go('/agents/$_selectedAgentId/chat?initialText=$encoded');
      return;
    }

    setState(() {
      _selectedAction = action;
      _processing = true;
      _result = null;
    });

    final agents = ref.read(agentListProvider);
    // Load providers directly from repository to avoid async state issues.
    final providers =
        await ref.read(providerRepositoryProvider).loadAll();

    if (agents.isEmpty || _selectedAgentId == null) {
      setState(() {
        _result = '⚠️ No agent configured. '
            'Please set up an agent with a provider first.';
        _processing = false;
      });
      return;
    }

    final agent =
        agents.where((a) => a.id == _selectedAgentId).firstOrNull;
    if (agent == null) {
      setState(() {
        _result = '⚠️ Selected agent not found.';
        _processing = false;
      });
      return;
    }

    final provider =
        providers.where((p) => p.id == agent.providerId).firstOrNull;

    if (provider == null || !provider.isComplete) {
      final providerIds = providers.map((p) => '${p.nickname}(${p.id.substring(0, 6)})').join(', ');
      setState(() {
        _result = '⚠️ Provider not configured for "${agent.name}".\n\n'
            'Agent provider ID: ${agent.providerId.isEmpty ? "(empty)" : agent.providerId.substring(0, 6)}\n'
            'Available providers: ${providerIds.isEmpty ? "none" : providerIds}\n'
            'Provider found: ${provider != null}\n'
            'Provider complete: ${provider?.isComplete ?? false}';
        _processing = false;
      });
      return;
    }

    final systemPrompt = _buildPrompt(action);

    try {
      final llmConfig = LlmProviderConfig(
        baseUrl: provider.baseUrl,
        apiKey: provider.apiKey,
        model: provider.model,
      );
      final reply = await OpenAiCompatibleClient().chat(
        config: llmConfig,
        messages: [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': widget.inputText},
        ],
      );
      if (mounted) {
        setState(() {
          _result = reply;
          _processing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _result = 'Error: $e';
          _processing = false;
        });
      }
    }
  }

  String _buildPrompt(ClipboardAction action) {
    switch (action) {
      case ClipboardAction.sendToChat:
        return ''; // Intercepted before reaching here.
      case ClipboardAction.translate:
        return 'Translate the following text to English. '
            'If already in English, translate to Indonesian. '
            'Only output the translation, nothing else.';
      case ClipboardAction.summarize:
        return 'Summarize the following text concisely. '
            'Keep the key points. Output only the summary.';
      case ClipboardAction.rewrite:
        return 'Rewrite the following text to be clearer and more concise. '
            'Maintain the original meaning. Output only the rewritten text.';
      case ClipboardAction.explain:
        return 'Explain the following text in simple, easy-to-understand terms. '
            'Use Indonesian language.';
      case ClipboardAction.grammar:
        return 'Fix any grammar, spelling, and punctuation errors in the text. '
            'Output only the corrected text.';
      case ClipboardAction.reply:
        return 'Draft a professional and friendly reply to the following message. '
            'Use the same language as the input. Output only the reply.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    final agents = ref.watch(agentListProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Clipboard AI'),  // Brand name — keep original
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/');
            }
          },
        ),
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: SafeArea(
          child: Column(
            children: [
            // Agent selector.
            if (agents.isNotEmpty)
              Container(
                margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                decoration: BoxDecoration(
                  color: extras.card,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: extras.subtleBorder),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedAgentId,
                    isExpanded: true,
                    icon: Icon(Icons.expand_more_rounded,
                        color: cs.onSurfaceVariant, size: 20),
                    dropdownColor: extras.card,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                    items: agents.map((a) {
                      final providers =
                          ref.read(providerListProvider).value ?? [];
                      final prov = providers
                          .where((p) => p.id == a.providerId)
                          .firstOrNull;
                      return DropdownMenuItem(
                        value: a.id,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.smart_toy_outlined,
                                    size: 16, color: cs.primary),
                                const SizedBox(width: 8),
                                Text(a.name),
                              ],
                            ),
                            if (prov != null)
                              Padding(
                                padding: const EdgeInsets.only(left: 24),
                                child: Text(
                                  '${prov.nickname} · ${prov.model}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: cs.onSurfaceVariant,
                                    fontWeight: FontWeight.w400,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    }).toList(),
                    onChanged: _processing
                        ? null
                        : (v) => setState(() => _selectedAgentId = v),
                  ),
                ),
              ),

            // Input preview.
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              padding: const EdgeInsets.all(14),
              constraints: const BoxConstraints(maxHeight: 120),
              decoration: BoxDecoration(
                color: extras.card,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: extras.subtleBorder),
              ),
              child: SingleChildScrollView(
                child: Text(
                  widget.inputText,
                  style: TextStyle(
                    fontSize: 13,
                    color: cs.onSurface,
                    height: 1.4,
                  ),
                ),
              ),
            ),

            // Custom prompt textbox.
            Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              decoration: BoxDecoration(
                color: extras.card,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: extras.subtleBorder),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _customPrompt,
                      enabled: !_processing,
                      minLines: 1,
                      maxLines: 3,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _processCustom(),
                      style: TextStyle(fontSize: 13, color: cs.onSurface),
                      decoration: InputDecoration(
                        hintText: 'Custom instruction (e.g., translate to Japanese)',
                        hintStyle: TextStyle(
                          fontSize: 13,
                          color: cs.onSurfaceVariant,
                        ),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: IconButton(
                      icon: Icon(
                        Icons.send_rounded,
                        size: 18,
                        color: cs.primary,
                      ),
                      onPressed: _processing ? null : _processCustom,
                      tooltip: 'Send custom prompt',
                    ),
                  ),
                ],
              ),
            ),

            // Action chips.
            SizedBox(
              height: 44,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: ClipboardAction.values.length,
                separatorBuilder: (_, i) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final action = ClipboardAction.values[i];
                  final isSelected = _selectedAction == action;
                  final iconColor = isSelected ? cs.onPrimary : cs.primary;
                  final labelColor = isSelected ? cs.onPrimary : cs.onSurface;
                  return Material(
                    color: isSelected ? cs.primary : extras.card,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                      side: BorderSide(
                        color: isSelected ? cs.primary : extras.subtleBorder,
                      ),
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap:
                          _processing ? null : () => _process(action),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(action.icon, size: 16, color: iconColor),
                            const SizedBox(width: 6),
                            Text(
                              action.label,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: labelColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),

            const SizedBox(height: 16),

            // Result area.
            Expanded(
              child: _processing
                  ? const _ThinkingIndicator()
                  : _result != null
                      ? Container(
                          width: double.infinity,
                          margin: const EdgeInsets.symmetric(horizontal: 16),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: extras.card,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: extras.subtleBorder),
                          ),
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      Icons.auto_awesome_rounded,
                                      size: 16,
                                      color: cs.primary,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      'Result',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: cs.primary,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                MarkdownBody(
                                  data: _result!,
                                  selectable: true,
                                  shrinkWrap: true,
                                  styleSheet: MarkdownStyleSheet(
                                    p: TextStyle(
                                      color: cs.onSurface,
                                      fontSize: 14,
                                      height: 1.5,
                                    ),
                                    strong: TextStyle(
                                      color: cs.onSurface,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      : Center(
                          child: Text(
                            s.chooseActionAbove,
                            style: TextStyle(
                              fontSize: 13,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
            ),

            // Copy result button.
            if (_result != null && !_processing)
              Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      // Copy to clipboard.
                      final data =
                          ClipboardData(text: _result!);
                      Clipboard.setData(data);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Copied to clipboard.'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    label: Text(s.copyResult),
                  ),
                ),
              ),
          ],
        ),
        ),
      ),
    );
  }
}

/// Animated thinking indicator with bouncing dots, matching chat UI style.
class _ThinkingIndicator extends StatefulWidget {
  const _ThinkingIndicator();

  @override
  State<_ThinkingIndicator> createState() => _ThinkingIndicatorState();
}

class _ThinkingIndicatorState extends State<_ThinkingIndicator>
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
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
        decoration: BoxDecoration(
          color: extras.card,
          borderRadius: BorderRadius.circular(20),
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
                const SizedBox(width: 6),
                _buildDot(context, t, 0.2),
                const SizedBox(width: 6),
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
    final opacity =
        0.3 + 0.7 * (phase < 0.5 ? phase * 2 : (1 - phase) * 2);
    return Opacity(
      opacity: opacity,
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: cs.primary,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
