import 'package:dio/dio.dart';

import '../../features/settings/data/llm_provider_config.dart';

/// Lightweight request usage estimate for local diagnostics.
class LlmRequestUsage {
  const LlmRequestUsage({
    required this.phase,
    required this.model,
    required this.inputTokens,
    this.outputTokens,
    required this.messageCount,
    required this.createdAt,
  });

  final String phase;
  final String model;
  final int inputTokens;
  final int? outputTokens;
  final int messageCount;
  final DateTime createdAt;
}

/// Minimal OpenAI-compatible chat completions client.
///
/// Only [chat] is needed for the MVP. The class also supports a lightweight
/// [testConnection] method used by the Set Up screen to validate the user's
/// credentials before saving them.
class OpenAiCompatibleClient {
  OpenAiCompatibleClient({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  static const int _maxUsageRecords = 80;
  static final List<LlmRequestUsage> _usageRecords = [];

  static List<LlmRequestUsage> get usageRecords =>
      List.unmodifiable(_usageRecords);

  static void clearUsageRecords() => _usageRecords.clear();

  static int estimateTokens(String text) {
    if (text.isEmpty) return 0;
    return (text.length / 3.2).ceil();
  }

  static int estimateMessagesTokens(List<Map<String, String>> messages) {
    var total = 0;
    for (final message in messages) {
      total += 4;
      total += estimateTokens(message['content'] ?? '');
    }
    return total;
  }

  static void _recordUsage(LlmRequestUsage usage) {
    _usageRecords.add(usage);
    if (_usageRecords.length > _maxUsageRecords) {
      _usageRecords.removeRange(0, _usageRecords.length - _maxUsageRecords);
    }
  }

  Uri _resolve(String baseUrl, String path) {
    final trimmed = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$trimmed$path');
  }

  /// Normalize provider-specific response formats to the JSON shape the
  /// runtime engine expects.
  ///
  /// Some models emit tool calls as XML (with or without a vendor prefix
  /// like `<acme:tool_call>` or just `<tool_call>`) instead of structured
  /// JSON. This converter matches that family of patterns generically,
  /// without naming any specific provider.
  static String _normalizeContent(String raw) {
    final trimmed = raw.trim();

    // Generic XML tool-call wrapper. Accepts:
    //   <tool_call>...</tool_call>
    //   <something:tool_call>...</something:tool_call>
    // The wrapper must contain an <invoke name="..."> block with optional
    // <parameter name="...">value</parameter> children.
    final wrapperRe = RegExp(
      r'<(?:[\w-]+:)?tool_call>\s*'
      r'<invoke\s+name="([^"]+)"\s*>'
      r'(.*?)'
      r'</invoke>\s*'
      r'</(?:[\w-]+:)?tool_call>',
      dotAll: true,
    );
    final match = wrapperRe.firstMatch(trimmed);
    if (match != null) {
      final toolName = match.group(1) ?? '';
      final body = match.group(2) ?? '';
      final args = <String, String>{};
      final paramRe = RegExp(
        r'<parameter\s+name="([^"]+)"\s*>(.*?)</parameter>',
        dotAll: true,
      );
      for (final m in paramRe.allMatches(body)) {
        args[m.group(1) ?? ''] = (m.group(2) ?? '').trim();
      }
      final argEntries = args.entries
          .map((e) => '"${e.key}":${_jsonString(e.value)}')
          .join(',');
      return '{"status":"tool_required","tool":{"name":"$toolName","args":{$argEntries},"risk":"safe","requires_confirmation":false},"reason":"Tool call extracted from XML wrapper.","narrative":""}';
    }
    return raw;
  }

  static String _jsonString(String s) {
    final escaped = s
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r')
        .replaceAll('\t', r'\t');
    return '"$escaped"';
  }

  Future<String> chat({
    required LlmProviderConfig config,
    required List<Map<String, String>> messages,
    String phase = 'chat',
    List<String> imageDataUrls = const [],
  }) async {
    final estimatedInputTokens = estimateMessagesTokens(messages);

    // Build the wire payload. If image data URLs are supplied, the LAST
    // user message is transformed into the OpenAI multipart content format
    // (a content array of {type: text|image_url, ...}). All other messages
    // are passed through unchanged. This lets the model see the user's
    // image inline during a normal conversational turn — no tool required.
    final wireMessages = <Map<String, dynamic>>[];
    if (imageDataUrls.isEmpty) {
      wireMessages.addAll(messages);
    } else {
      var lastUserIdx = -1;
      for (var i = messages.length - 1; i >= 0; i--) {
        if (messages[i]['role'] == 'user') {
          lastUserIdx = i;
          break;
        }
      }
      for (var i = 0; i < messages.length; i++) {
        final m = messages[i];
        if (i == lastUserIdx) {
          wireMessages.add({
            'role': m['role'],
            'content': [
              {'type': 'text', 'text': m['content'] ?? ''},
              for (final url in imageDataUrls)
                {
                  'type': 'image_url',
                  'image_url': {'url': url},
                },
            ],
          });
        } else {
          wireMessages.add({...m});
        }
      }
    }

    final response = await _dio.postUri<Map<String, dynamic>>(
      _resolve(config.baseUrl, '/chat/completions'),
      data: {'model': config.model, 'messages': wireMessages},
      options: Options(
        headers: {
          'Authorization': 'Bearer ${config.apiKey}',
          'Content-Type': 'application/json',
        },
      ),
    );

    final data = response.data;
    if (data == null) {
      throw Exception('Empty response from LLM provider.');
    }

    final choices = data['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      throw Exception('No choices returned by LLM provider.');
    }

    final message = (choices.first as Map)['message'] as Map?;
    final content = message?['content'];
    if (content is! String) {
      throw Exception('Malformed message content.');
    }
    final usage = data['usage'] as Map?;
    final completionTokens = usage?['completion_tokens'];
    _recordUsage(
      LlmRequestUsage(
        phase: phase,
        model: config.model,
        inputTokens: estimatedInputTokens,
        outputTokens: completionTokens is int ? completionTokens : null,
        messageCount: messages.length,
        createdAt: DateTime.now(),
      ),
    );
    return _normalizeContent(content);
  }

  Future<String> chatWithImage({
    required LlmProviderConfig config,
    required String prompt,
    required String imageDataUrl,
    String phase = 'vision',
  }) async {
    final response = await _dio.postUri<Map<String, dynamic>>(
      _resolve(config.baseUrl, '/chat/completions'),
      data: {
        'model': config.model,
        'messages': [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': prompt},
              {
                'type': 'image_url',
                'image_url': {'url': imageDataUrl},
              },
            ],
          },
        ],
      },
      options: Options(
        headers: {
          'Authorization': 'Bearer ${config.apiKey}',
          'Content-Type': 'application/json',
        },
      ),
    );

    final data = response.data;
    if (data == null) {
      throw Exception('Empty response from LLM provider.');
    }

    final choices = data['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      throw Exception('No choices returned by LLM provider.');
    }

    final message = (choices.first as Map)['message'] as Map?;
    final content = message?['content'];
    if (content is! String) {
      throw Exception('Malformed message content.');
    }
    final usage = data['usage'] as Map?;
    final completionTokens = usage?['completion_tokens'];
    _recordUsage(
      LlmRequestUsage(
        phase: phase,
        model: config.model,
        inputTokens: estimateTokens(prompt),
        outputTokens: completionTokens is int ? completionTokens : null,
        messageCount: 1,
        createdAt: DateTime.now(),
      ),
    );
    return _normalizeContent(content);
  }

  /// Lightweight credential test: lists models and returns true on 2xx.
  /// Falls back to a tiny chat completion if /models is not exposed by
  /// the provider.
  Future<bool> testConnection(LlmProviderConfig config) async {
    try {
      final res = await _dio.getUri<dynamic>(
        _resolve(config.baseUrl, '/models'),
        options: Options(
          headers: {'Authorization': 'Bearer ${config.apiKey}'},
          validateStatus: (_) => true,
        ),
      );
      if (res.statusCode != null &&
          res.statusCode! >= 200 &&
          res.statusCode! < 300) {
        return true;
      }
    } catch (_) {
      // fall through to chat fallback
    }

    // Fallback: try a 1-token chat completion
    try {
      await chat(
        config: config,
        messages: [
          {'role': 'user', 'content': 'ping'},
        ],
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> testVisionSupport(LlmProviderConfig config) async {
    try {
      await chatWithImage(
        config: config,
        prompt: 'Reply with the single word ok.',
        imageDataUrl:
            'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=',
        phase: 'vision_probe',
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}
