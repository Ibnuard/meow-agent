import '../../features/chat/data/chat_history_service.dart';
import '../../features/settings/data/app_language_provider.dart';
import '../llm/openai_compatible_client.dart';
import '../workspace/workspace_file_service.dart';
import 'context_compactor.dart';
import 'language_registry.dart';
import 'prompt_constants.dart';
import 'tool_catalog.dart';
import 'tool_router.dart';

/// Builds a human-readable summary of the agent's runtime context for the
/// `/context` command.
///
/// Designed to be approachable — no internal file names (SOUL.md etc.), no
/// LLM call traces, no tool filter jargon. Just: how full is the agent's
/// short-term memory, what does it know about you, and how much room is left.
class ContextReport {
  ContextReport._();

  static Future<String> build({
    required String agentName,
    required String languageCode,
    required List<ChatMessage> messages,
    required int maxContextLength,
    String userMessageHint = '',
  }) async {
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

    // Aggregate token estimates by purpose, not by source file.
    final identityTokens =
        OpenAiCompatibleClient.estimateTokens(soul) +
        OpenAiCompatibleClient.estimateTokens(memory);
    final knowledgeTokens =
        OpenAiCompatibleClient.estimateTokens(skills) +
        OpenAiCompatibleClient.estimateTokens(heartbeat) +
        OpenAiCompatibleClient.estimateTokens(systemRules);
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

    // Prefer the actually-measured peak from recent LLM calls.
    // Fall back to the synthesized estimate when no calls have happened yet.
    final peakMeasured = ContextCompactor.peakRecentInputTokens();
    final synthesizedTotal =
        identityTokens + knowledgeTokens + messagesTokens + selectedToolsTokens;
    final usedTokens = peakMeasured > 0 ? peakMeasured : synthesizedTotal;
    final remainingTokens = (maxContextLength - usedTokens).clamp(0, 1 << 30);

    final pct = maxContextLength > 0
        ? ((usedTokens / maxContextLength) * 100).clamp(0, 999).round()
        : 0;

    final headlineKey = pct < 30
        ? 'context_headline_low'
        : pct < 60
        ? 'context_headline_comfortable'
        : pct < 80
        ? 'context_headline_tight'
        : 'context_headline_full';
    final headline = LanguageRegistry.phrase(headlineKey, languageCode, {
      'pct': pct.toString(),
    });

    final fullContextDelta = (allToolsTokens - selectedToolsTokens).clamp(
      0,
      1 << 30,
    );

    final buf = StringBuffer()
      ..writeln(
        LanguageRegistry.phrase('context_title', languageCode, {
          'agent': agentName,
        }),
      )
      ..writeln()
      ..writeln('$headline.')
      ..writeln()
      ..writeln(
        LanguageRegistry.phrase('context_capacity_line', languageCode, {
          'max': maxContextLength.toString(),
          'used': usedTokens.toString(),
          'free': remainingTokens.toString(),
        }),
      )
      ..writeln()
      ..writeln(
        LanguageRegistry.phrase('context_currently_holding', languageCode),
      )
      ..writeln()
      ..writeln(
        LanguageRegistry.phrase('context_item_identity', languageCode, {
          'tokens': identityTokens.toString(),
        }),
      )
      ..writeln(
        LanguageRegistry.phrase('context_item_messages', languageCode, {
          'count': recentMessages.length.toString(),
          'tokens': messagesTokens.toString(),
        }),
      )
      ..writeln(
        LanguageRegistry.phrase('context_item_capabilities', languageCode, {
          'used': selectedTools.length.toString(),
          'total': allTools.length.toString(),
          'tokens': selectedToolsTokens.toString(),
        }),
      );

    if (fullContextDelta > 100) {
      buf
        ..writeln()
        ..writeln(
          LanguageRegistry.phrase('context_savings_note', languageCode, {
            'delta': fullContextDelta.toString(),
          }),
        );
    }

    return buf.toString().trim();
  }
}
