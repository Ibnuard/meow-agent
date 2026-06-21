import '../../core/storage/agent_memory_repository.dart';
import '../../core/storage/agent_soul_repository.dart';
import '../../features/chat/data/chat_history_service.dart';
import '../../features/settings/data/app_language_provider.dart';
import '../llm/openai_compatible_client.dart';
import 'context_compactor.dart';
import 'prompt_constants.dart';
import 'tool_catalog.dart';
import 'tool_router.dart';

/// Builds a human-readable summary of the agent's runtime context for the
/// `/context` command.
///
/// Clean, simple format — one glance shows context pressure and breakdown.
class ContextReport {
  ContextReport._();

  static Future<String> build({
    required String agentName,
    required String agentId,
    required String languageCode,
    required List<ChatMessage> messages,
    required int maxContextLength,
    AgentSoulRepository? soulRepo,
    AgentMemoryRepository? memoryRepo,
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

    // Phase 7: identity & memory live in the database, not in workspace
    // markdown files. Read from the same repos the runtime engine uses so
    // the token estimate matches what's actually injected into the prompt.
    final soul = await soulRepo?.get(agentId);
    final memoryEntries = await memoryRepo?.recent(agentId, limit: 30);
    final identityText = _formatIdentity(agentName, soul);
    final memoryText = _formatMemoryEntries(memoryEntries ?? const []);

    // Token estimates by category.
    final identityTokens =
        OpenAiCompatibleClient.estimateTokens(identityText) +
        OpenAiCompatibleClient.estimateTokens(memoryText);
    final knowledgeTokens = OpenAiCompatibleClient.estimateTokens(systemRules);
    final messagesText = recentMessages
        .map((m) => '${m.role}: ${m.content}')
        .join('\n');
    final messagesTokens = OpenAiCompatibleClient.estimateTokens(messagesText);
    final selectedToolsText = selectedTools.join('\n');
    final selectedToolsTokens = OpenAiCompatibleClient.estimateTokens(
      selectedToolsText,
    );

    // Prefer measured peak from recent LLM calls.
    final peakMeasured = ContextCompactor.peakRecentInputTokens();
    final synthesizedTotal =
        identityTokens + knowledgeTokens + messagesTokens + selectedToolsTokens;
    final usedTokens = peakMeasured > 0 ? peakMeasured : synthesizedTotal;
    final remainingTokens = (maxContextLength - usedTokens).clamp(0, 1 << 30);

    final pct = maxContextLength > 0
        ? ((usedTokens / maxContextLength) * 100).clamp(0, 999).round()
        : 0;

    // Status indicator.
    final String statusIcon;
    final String statusLabel;
    if (pct < 30) {
      statusIcon = '\u{2705}';
      statusLabel = isId ? 'Lega' : 'Comfortable';
    } else if (pct < 60) {
      statusIcon = '\u{1F7E1}';
      statusLabel = isId ? 'Normal' : 'Normal';
    } else if (pct < 80) {
      statusIcon = '\u{1F7E0}';
      statusLabel = isId ? 'Padat' : 'Getting tight';
    } else {
      statusIcon = '\u{1F534}';
      statusLabel = isId ? 'Penuh' : 'Near limit';
    }

    final buf = StringBuffer()
      ..writeln('\u{1F4CA} Context \u{2014} $agentName')
      ..writeln()
      ..writeln('${isId ? 'Penggunaan' : 'Usage'}: $usedTokens / $maxContextLength ($pct%)')
      ..writeln('Status: $statusIcon $statusLabel')
      ..writeln()
      ..writeln('${isId ? 'Rincian' : 'Breakdown'}:')
      ..writeln('\u{2022} ${isId ? 'Identitas & memori' : 'Identity & memory'}: ~$identityTokens tokens')
      ..writeln('\u{2022} ${isId ? 'Riwayat chat' : 'Chat history'} (${recentMessages.length} ${isId ? 'pesan' : 'msgs'}): ~$messagesTokens tokens')
      ..writeln('\u{2022} ${isId ? 'Kemampuan' : 'Capabilities'} (${selectedTools.length}/${allTools.length}): ~$selectedToolsTokens tokens')
      ..writeln('\u{2022} ${isId ? 'Pengetahuan & aturan' : 'Knowledge & rules'}: ~$knowledgeTokens tokens')
      ..writeln()
      ..writeln('$remainingTokens tokens ${isId ? 'tersisa' : 'remaining'}.');

    return buf.toString().trim();
  }

  // ─── Identity / memory formatting ──────────────────────────────────────────
  //
  // Mirrors `_formatSoul` / `_formatMemory` in [AgentRuntimeEngine] so the
  // token estimate matches the bytes the runtime actually sends to the LLM.

  static String _formatIdentity(String agentName, AgentSoul? soul) {
    if (soul == null) return '';
    final buf = StringBuffer()
      ..writeln('# Soul — $agentName')
      ..writeln()
      ..writeln('## User Identity')
      ..writeln('Name: ${soul.userName ?? '[Your Name]'}')
      ..writeln('Nickname: ${soul.userNickname ?? ''}')
      ..writeln('Preferred Language: ${soul.preferredLanguage ?? ''}')
      ..writeln('Timezone: ${soul.timezone ?? ''}')
      ..writeln()
      ..writeln('## Profile')
      ..writeln('Work Role: ${soul.workRole ?? ''}')
      ..writeln('Main Project: ${soul.mainProject ?? ''}')
      ..writeln('Communication Style: ${soul.communicationStyle ?? ''}')
      ..writeln('Design Preference: ${soul.designPreference ?? ''}');
    if ((soul.persona ?? '').isNotEmpty) {
      buf
        ..writeln()
        ..writeln('## Persona')
        ..writeln(soul.persona);
    }
    return buf.toString();
  }

  static String _formatMemoryEntries(List<AgentMemoryEntry> entries) {
    if (entries.isEmpty) return '';
    final buf = StringBuffer()
      ..writeln('# Memory')
      ..writeln();
    final byCat = <String, List<AgentMemoryEntry>>{};
    for (final e in entries) {
      byCat.putIfAbsent(e.category, () => []).add(e);
    }
    for (final entry in byCat.entries) {
      buf
        ..writeln('## ${entry.key}')
        ..writeln();
      for (final m in entry.value) {
        final date = m.createdAt.toIso8601String().split('T').first;
        buf.writeln('- $date: ${m.content}');
      }
      buf.writeln();
    }
    return buf.toString();
  }
}
