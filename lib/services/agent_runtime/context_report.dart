import '../../features/chat/data/chat_history_service.dart';
import '../../features/settings/data/app_language_provider.dart';
import '../llm/openai_compatible_client.dart';
import '../workspace/workspace_file_service.dart';
import 'prompt_constants.dart';
import 'tool_catalog.dart';
import 'tool_router.dart';

/// Builds a human-readable, chat-friendly summary of the agent's runtime
/// context for the `/context` command.
///
/// Uses descriptive prose with bullet points instead of wide markdown tables
/// — those tables overflow the chat bubble width on phones.
class ContextReport {
  ContextReport._();

  static Future<String> build({
    required String agentName,
    required String languageCode,
    required List<ChatMessage> messages,
    required int maxContextLength,
    String userMessageHint = '',
  }) async {
    final isId = languageCode == 'id';

    final recentMessages = messages.length > 20
        ? messages.sublist(messages.length - 20)
        : messages;
    final lastUserMessage = userMessageHint.trim().isNotEmpty
        ? userMessageHint.trim()
        : messages
                  .where((m) => m.role == 'user')
                  .map((m) => m.content)
                  .lastOrNull ??
              '';

    final language = languageLabelFromCode(languageCode);
    final systemRules = PromptConstants.systemRules(language);
    final allTools = ToolRouter().buildAllToolDescriptions();
    final toolSelection = ToolCatalog.select(userMessage: lastUserMessage);
    final selectedTools = ToolRouter().buildToolDescriptions(
      toolSelection.toolNames,
    );

    final soul = await WorkspaceFileService.readFile(agentName, 'SOUL.md');
    final memory = await WorkspaceFileService.readFile(agentName, 'MEMORY.md');
    final skills = await WorkspaceFileService.readFile(agentName, 'SKILLS.md');
    final heartbeat = await WorkspaceFileService.readFile(
      agentName,
      'HEARTBEAT.md',
    );

    // Token estimates per section.
    final rulesTokens = OpenAiCompatibleClient.estimateTokens(systemRules);
    final soulTokens = OpenAiCompatibleClient.estimateTokens(soul);
    final memoryTokens = OpenAiCompatibleClient.estimateTokens(memory);
    final skillsTokens = OpenAiCompatibleClient.estimateTokens(skills);
    final heartbeatTokens = OpenAiCompatibleClient.estimateTokens(heartbeat);
    final messagesText = recentMessages
        .map((m) => '${m.role}: ${m.content}')
        .join('\n');
    final messagesTokens = OpenAiCompatibleClient.estimateTokens(messagesText);
    final selectedToolsText = selectedTools.join('\n');
    final allToolsText = allTools.join('\n');
    final selectedToolsTokens = OpenAiCompatibleClient.estimateTokens(
      selectedToolsText,
    );
    final allToolsTokens = OpenAiCompatibleClient.estimateTokens(allToolsText);

    final activeContext =
        rulesTokens +
        soulTokens +
        memoryTokens +
        skillsTokens +
        heartbeatTokens +
        messagesTokens +
        selectedToolsTokens;
    final fullToolContext = activeContext - selectedToolsTokens + allToolsTokens;

    final pct = maxContextLength > 0
        ? ((activeContext / maxContextLength) * 100).clamp(0, 999).round()
        : 0;

    String fmt(int tokens) => '~$tokens';

    final buf = StringBuffer();

    if (isId) {
      buf
        ..writeln('🧠 Konteks Agen — $agentName')
        ..writeln()
        ..writeln(
          'Saat ini agen menggunakan ${fmt(activeContext)} dari $maxContextLength token ($pct% dari kapasitas).',
        )
        ..writeln()
        ..writeln('Rincian token aktif:')
        ..writeln()
        ..writeln('- Aturan sistem: ${fmt(rulesTokens)}')
        ..writeln('- SOUL.md: ${fmt(soulTokens)}')
        ..writeln('- MEMORY.md: ${fmt(memoryTokens)}')
        ..writeln('- SKILLS.md: ${fmt(skillsTokens)}')
        ..writeln('- HEARTBEAT.md: ${fmt(heartbeatTokens)}')
        ..writeln(
          '- ${recentMessages.length} pesan terakhir: ${fmt(messagesTokens)}',
        )
        ..writeln(
          '- Tools terpilih (${selectedTools.length}/${allTools.length}): ${fmt(selectedToolsTokens)}',
        )
        ..writeln()
        ..writeln(
          'Filter tools: ${toolSelection.reason}. Confidence ${toolSelection.confidence.toStringAsFixed(2)}.',
        )
        ..writeln()
        ..writeln(
          'Tanpa filter (semua tools dikirim), perkiraan ${fmt(fullToolContext)} token — '
          'penghematan ~${(fullToolContext - activeContext).clamp(0, 1 << 31)} token tiap turn.',
        );
    } else {
      buf
        ..writeln('🧠 Agent Context — $agentName')
        ..writeln()
        ..writeln(
          'The agent is currently using ${fmt(activeContext)} of $maxContextLength tokens ($pct% of capacity).',
        )
        ..writeln()
        ..writeln('Active token breakdown:')
        ..writeln()
        ..writeln('- System rules: ${fmt(rulesTokens)}')
        ..writeln('- SOUL.md: ${fmt(soulTokens)}')
        ..writeln('- MEMORY.md: ${fmt(memoryTokens)}')
        ..writeln('- SKILLS.md: ${fmt(skillsTokens)}')
        ..writeln('- HEARTBEAT.md: ${fmt(heartbeatTokens)}')
        ..writeln(
          '- Last ${recentMessages.length} messages: ${fmt(messagesTokens)}',
        )
        ..writeln(
          '- Selected tools (${selectedTools.length}/${allTools.length}): ${fmt(selectedToolsTokens)}',
        )
        ..writeln()
        ..writeln(
          'Tool filter: ${toolSelection.reason}. Confidence ${toolSelection.confidence.toStringAsFixed(2)}.',
        )
        ..writeln()
        ..writeln(
          'Without filtering (all tools sent), it would be roughly ${fmt(fullToolContext)} tokens — '
          'saving ~${(fullToolContext - activeContext).clamp(0, 1 << 31)} tokens per turn.',
        );
    }

    final recentUsage = OpenAiCompatibleClient.usageRecords.reversed
        .take(5)
        .toList();
    if (recentUsage.isNotEmpty) {
      buf
        ..writeln()
        ..writeln(isId ? 'Panggilan LLM terakhir:' : 'Recent LLM calls:')
        ..writeln();
      for (final usage in recentUsage) {
        final out = usage.outputTokens == null
            ? '?'
            : '~${usage.outputTokens}';
        buf.writeln(
          '- ${usage.phase}: in ~${usage.inputTokens} → out $out '
          '(${usage.messageCount} msgs · ${usage.model})',
        );
      }
    }

    return buf.toString().trim();
  }
}
