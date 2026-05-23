import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../services/llm/openai_compatible_client.dart';
import '../../agents/data/agent_repository.dart';
import '../../providers/data/provider_repository.dart';
import '../../settings/data/llm_provider_config.dart';

/// Actions available for processing shared/clipboard text.
enum ClipboardAction {
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

  @override
  void initState() {
    super.initState();
    final agents = ref.read(agentListProvider);
    if (agents.isNotEmpty) {
      _selectedAgentId = agents.first.id;
    }
  }

  Future<void> _process(ClipboardAction action) async {
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
        title: const Text('Clipboard AI'),
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
      body: SafeArea(
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
                  return ActionChip(
                    avatar: Icon(
                      action.icon,
                      size: 16,
                      color: isSelected ? cs.onPrimary : cs.primary,
                    ),
                    label: Text(action.label),
                    labelStyle: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isSelected ? cs.onPrimary : cs.onSurface,
                    ),
                    backgroundColor:
                        isSelected ? cs.primary : extras.card,
                    side: BorderSide(
                      color: isSelected
                          ? cs.primary
                          : extras.subtleBorder,
                    ),
                    onPressed: _processing ? null : () => _process(action),
                  );
                },
              ),
            ),

            const SizedBox(height: 16),

            // Result area.
            Expanded(
              child: _processing
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(height: 12),
                          Text(
                            'Processing...',
                            style: TextStyle(fontSize: 13),
                          ),
                        ],
                      ),
                    )
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
                            'Choose an action above to process the text.',
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
                    label: const Text('Copy Result'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
