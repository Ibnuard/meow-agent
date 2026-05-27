import '../../features/chat/data/chat_history_service.dart';
import '../../features/settings/data/app_language_provider.dart';
import '../llm/openai_compatible_client.dart';
import '../workspace/workspace_file_service.dart';
import 'prompt_constants.dart';
import 'tool_catalog.dart';
import 'tool_router.dart';

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

    final sections = <_ContextSection>[
      _ContextSection('system rules', systemRules),
      _ContextSection('SOUL.md', soul),
      _ContextSection('MEMORY.md', memory),
      _ContextSection('SKILLS.md', skills),
      _ContextSection('HEARTBEAT.md', heartbeat),
      _ContextSection(
        'recent messages (${recentMessages.length})',
        recentMessages.map((m) => '${m.role}: ${m.content}').join('\n'),
      ),
      _ContextSection(
        'selected tools (${selectedTools.length})',
        selectedTools.join('\n'),
      ),
      _ContextSection('all tools (${allTools.length})', allTools.join('\n')),
    ];

    final selectedToolsSection = sections.firstWhere(
      (s) => s.name.startsWith('selected tools'),
    );
    final allToolsSection = sections.firstWhere(
      (s) => s.name.startsWith('all tools'),
    );
    final currentRuntimeEstimate = sections
        .where((s) => !s.name.startsWith('all tools'))
        .fold<int>(0, (sum, s) => sum + s.tokens);
    final fullToolEstimate =
        currentRuntimeEstimate -
        selectedToolsSection.tokens +
        allToolsSection.tokens;

    final recentUsage = OpenAiCompatibleClient.usageRecords.reversed
        .take(8)
        .toList();

    final buf = StringBuffer()
      ..writeln('### Context Report')
      ..writeln()
      ..writeln('| Section | Est. tokens | Chars |')
      ..writeln('|---|---:|---:|');

    for (final section in sections) {
      buf.writeln(
        '| ${section.name} | ~${section.tokens} | ${section.chars} |',
      );
    }

    buf
      ..writeln()
      ..writeln('### Runtime Estimate')
      ..writeln()
      ..writeln('| | |')
      ..writeln('|---|---:|')
      ..writeln('| Selected tool context | ~$currentRuntimeEstimate tokens |')
      ..writeln('| Full tool context | ~$fullToolEstimate tokens |')
      ..writeln('| Agent max context | $maxContextLength tokens |')
      ..writeln('| Tool selection | ${toolSelection.reason} |')
      ..writeln(
        '| Tool confidence | ${toolSelection.confidence.toStringAsFixed(2)} |',
      );

    if (recentUsage.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('### Recent LLM Calls')
        ..writeln()
        ..writeln('| Phase | Input | Output | Messages | Model |')
        ..writeln('|---|---:|---:|---:|---|');
      for (final usage in recentUsage) {
        buf.writeln(
          '| ${usage.phase} | ~${usage.inputTokens} | '
          '${usage.outputTokens == null ? '-' : '~${usage.outputTokens}'} | '
          '${usage.messageCount} | ${usage.model} |',
        );
      }
    }

    return buf.toString().trim();
  }
}

class _ContextSection {
  _ContextSection(this.name, this.content)
    : chars = content.length,
      tokens = OpenAiCompatibleClient.estimateTokens(content);

  final String name;
  final String content;
  final int chars;
  final int tokens;
}
