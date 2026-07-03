/// Tiny prompt used for the first lightweight acknowledgement bubble.
///
/// This is intentionally separate from the full runtime prompt. It must not
/// see tools, memory, history, or workspace state because its job is only UX:
/// quickly decide whether this is likely agentic work, then acknowledge that
/// the agent is starting to process the latest request.
library;

List<Map<String, String>> promptQuickAckMessages({
  required String agentName,
  required String languageCode,
  required String userMessage,
}) {
  final identity = agentName.trim().isEmpty ? 'the agent' : agentName.trim();
  return [
    {
      'role': 'system',
      'content':
          'You are $identity, a concise assistant. Decide if the latest user request is likely agentic work. '
          'Agentic means it likely needs local/app/device/file/database/runtime state, mutation, automation, or a tool-backed action. '
          'Chat means greeting, general explanation, creative writing, opinion, or casual conversation that can be answered directly. '
          'Return ONLY compact JSON: {"mode":"agentic|chat","ack":"..."}.\n'
          'If mode is chat, ack MUST be empty. '
          'If mode is agentic, ack is exactly one short acknowledgement in language code "$languageCode". '
          'Do not claim success. Do not mention tools, internal phases, IDs, or implementation. '
          'Do not ask a question. Do not promise a specific capability. '
          'Sound natural and warm, as if you are starting to check or process it.',
    },
    {'role': 'user', 'content': userMessage},
  ];
}
