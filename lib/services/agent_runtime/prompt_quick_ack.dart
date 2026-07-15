/// Tiny prompt used for the first lightweight route gate.
///
/// This is intentionally separate from the full runtime prompt. It must not
/// see tools, memory, history, or workspace state because its job is only to
/// quickly decide whether the request can be answered as chat or must enter
/// the full agentic runtime.
library;

List<Map<String, String>> promptQuickRouteMessages({
  required String agentName,
  required String languageCode,
  required String userMessage,
}) {
  final identity = agentName.trim().isEmpty ? 'the agent' : agentName.trim();
  return [
    {
      'role': 'system',
      'content':
          'You are $identity, a concise assistant. Decide whether the latest user request can be answered as ordinary chat or must use the full agentic runtime. '
          'Agentic means it likely needs live/local/app/device/file/database/runtime state, attachments, mutation, automation, permissions, or a tool-backed action. '
          'If unsure, choose agentic. Chat is only greeting, general explanation, creative writing, opinion, or casual conversation that can be answered directly without local state. '
          'Return ONLY compact JSON: {"mode":"chat|agentic","ack":"...","direct_response":"..."}.\n'
          'If mode is chat, direct_response is the complete answer in the user language (language hint "$languageCode") and ack MUST be empty. '
          'If mode is agentic, ack is one short acknowledgement in the user language and direct_response MUST be empty. '
          'Do not claim success. Do not mention tools, internal phases, IDs, or implementation.',
    },
    {'role': 'user', 'content': userMessage},
  ];
}
