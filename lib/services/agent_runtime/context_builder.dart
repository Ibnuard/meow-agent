import '../../features/chat/data/chat_history_service.dart';
import 'runtime_models.dart';

/// Builds the runtime context from workspace, messages, and metadata.
class ContextBuilder {
  /// Build system messages for the LLM based on workspace and context.
  List<Map<String, String>> buildMessages({
    required AgentWorkspace workspace,
    required List<ChatMessage> recentMessages,
    required String systemPrompt,
  }) {
    final messages = <Map<String, String>>[];

    // System prompt with workspace context baked in.
    messages.add({'role': 'system', 'content': systemPrompt});

    // Inject recent chat history for continuity.
    for (final msg in recentMessages.take(10)) {
      messages.add({'role': msg.role, 'content': msg.content});
    }

    return messages;
  }

  /// Extract available tool names from skills.md content.
  List<String> parseAvailableTools(String skillsContent) {
    final tools = <String>[];
    final lines = skillsContent.split('\n');
    for (final line in lines) {
      // Parse lines like: "- clipboard.read: Read current clipboard text. Risk: safe."
      final match = RegExp(r'^-\s+([\w.]+):').firstMatch(line.trim());
      if (match != null) {
        tools.add(match.group(1)!);
      }
    }
    return tools;
  }

  /// Build a formatted tool list string for prompts.
  List<String> buildToolDescriptions(String skillsContent) {
    final descriptions = <String>[];
    final lines = skillsContent.split('\n');
    for (final line in lines) {
      if (line.trim().startsWith('- ') && line.contains(':')) {
        descriptions.add(line.trim());
      }
    }
    return descriptions;
  }
}
