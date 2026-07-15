import 'dart:convert';

import 'package:dio/dio.dart';

import '../../features/settings/data/llm_provider_config.dart';

/// Lightweight request usage estimate for local diagnostics.
class LlmRequestUsage {
  const LlmRequestUsage({
    required this.phase,
    required this.model,
    required this.inputTokens,
    this.outputTokens,
    this.cachedTokens,
    required this.messageCount,
    required this.createdAt,
  });

  final String phase;
  final String model;
  final int inputTokens;
  final int? outputTokens;
  final int? cachedTokens;
  final int messageCount;
  final DateTime createdAt;
}

/// Result of a native function calling chat completion.
///
/// When the model emits a `tool_calls` array, the first call is parsed into
/// this structure. Returns null in [OpenAiCompatibleClient.chatWithTools]
/// when the model returns plain content with no tool_call (caller should
/// fallback to JSON path).
class FunctionCallResult {
  const FunctionCallResult({
    required this.toolName,
    required this.args,
    this.toolCallId,
  });

  final String toolName;
  final Map<String, dynamic> args;
  final String? toolCallId;
}

/// Minimal OpenAI-compatible chat completions client.
///
/// Only [chat] is needed for the MVP. The class also supports a lightweight
/// [testConnection] method used by the Set Up screen to validate the user's
/// credentials before saving them.
class OpenAiCompatibleClient {
  OpenAiCompatibleClient({Dio? dio}) : _dio = dio ?? _defaultDio();

  final Dio _dio;

  /// Default Dio with explicit timeouts. Without these a stalled provider
  /// (radio drop, captive portal, dead endpoint) hangs the agent turn forever
  /// on mobile. Receive timeout is generous because long completions stream
  /// slowly; connect/send are tighter since they should be near-instant.
  static Dio _defaultDio() => Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 60),
      receiveTimeout: const Duration(seconds: 300),
      sendTimeout: const Duration(seconds: 60),
    ),
  );

  static const int _maxUsageRecords = 80;
  static final List<LlmRequestUsage> _usageRecords = [];

  /// Session-scoped prompt cache key. Set once per conversation turn flow
  /// so the provider can reuse the cached prompt prefix across multi-phase
  /// LLM calls (analyze → reflect → plan → execute).
  /// See REVIEWED.md Level 1: Provider Prompt Caching.
  static String _sessionCacheKey = '';

  /// Initialize prompt caching for the current conversation.
  /// Call this at the start of [AgentRuntimeEngine.run] with a stable
  /// identifier (agentId + conversation segment). When set and the provider
  /// config has [LlmProviderConfig.supportsPromptCaching], every subsequent
  /// request carries the `prompt_cache_key` header.
  static void initSession(String sessionId) {
    _sessionCacheKey = sessionId;
  }

  /// Clear the session cache key (e.g. on conversation reset).
  static void clearSession() {
    _sessionCacheKey = '';
  }

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

  /// Build headers for a request, injecting prompt_cache_key when the
  /// provider supports caching and a session key has been set.
  Map<String, dynamic> _buildHeaders(LlmProviderConfig config) {
    final headers = <String, dynamic>{
      'Authorization': 'Bearer ${config.apiKey}',
      'Content-Type': 'application/json',
    };
    if (config.supportsPromptCaching && _sessionCacheKey.isNotEmpty) {
      headers['prompt_cache_key'] = _sessionCacheKey;
    }
    return headers;
  }

  /// Extract cached token count from provider response usage data.
  /// OpenAI-compatible providers return this under
  /// `usage.prompt_tokens_details.cached_tokens`.
  static int? _extractCachedTokens(Map? usage) {
    if (usage == null) return null;
    final details = usage['prompt_tokens_details'];
    if (details is Map) {
      final cached = details['cached_tokens'];
      if (cached is int) return cached;
    }
    return null;
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
    CancelToken? cancelToken,
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

    final response = await _postWithRetry<Map<String, dynamic>>(
      () => _dio.postUri<Map<String, dynamic>>(
        _resolve(config.baseUrl, '/chat/completions'),
        data: {'model': config.model, 'messages': wireMessages},
        options: Options(headers: _buildHeaders(config)),
        cancelToken: cancelToken,
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
        cachedTokens: _extractCachedTokens(usage),
        messageCount: messages.length,
        createdAt: DateTime.now(),
      ),
    );
    return _normalizeContent(content);
  }

  /// Execute a POST request with a bounded retry on transient network/HTTP
  /// failures (connection reset, receive timeout, 429 Too Many Requests, 5xx).
  ///
  /// Without this a single dropped packet or a momentary provider 503 aborts
  /// the entire agent turn — even though the very next attempt would likely
  /// succeed. We retry up to [_maxChatRetries] times with exponential backoff,
  /// reusing the provider prompt-cache key so retried calls still benefit from
  /// prefix caching. Non-transient failures (4xx auth/validation) propagate
  /// immediately, and a cancelled request is never retried.
  static const int _maxChatRetries = 2;

  Future<Response<T>> _postWithRetry<T>(
    Future<Response<T>> Function() request,
  ) async {
    var attempt = 0;
    while (true) {
      try {
        return await request();
      } on DioException catch (e) {
        if (!_isTransientDioError(e) || attempt >= _maxChatRetries) rethrow;
        // Backoff: 500ms, 1500ms — long enough for a transient provider
        // blip to clear without making a stalled turn feel hung.
        final backoffMs = (500 * (attempt + 1)) + (attempt * 1000);
        await Future.delayed(Duration(milliseconds: backoffMs));
        attempt++;
      }
    }
  }

  /// True for errors worth retrying: timeouts, connection resets, and provider
  /// rate-limit/server errors. False for auth failures, bad requests, and
  /// cancellations.
  bool _isTransientDioError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.connectionError:
        return true;
      case DioExceptionType.badResponse:
        final status = e.response?.statusCode ?? 0;
        // 429 Too Many Requests and 5xx server errors are transient.
        return status == 429 || (status >= 500 && status < 600);
      case DioExceptionType.cancel:
      case DioExceptionType.badCertificate:
      case DioExceptionType.unknown:
        return false;
    }
  }

  /// Native function calling path. Sends `tools` as an API parameter and
  /// reads `message.tool_calls[0].function` from the response.
  ///
  /// Returns null when the model emits plain content with no tool_call —
  /// the caller should fallback to the JSON-in-content selector path.
  Future<FunctionCallResult?> chatWithTools({
    required LlmProviderConfig config,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    String toolChoice = 'required',
    String phase = 'fc',
    CancelToken? cancelToken,
  }) async {
    final estimatedInputTokens = estimateMessagesTokens(
      messages
          .map(
            (m) => Map<String, String>.from(
              m.map((k, v) => MapEntry(k, v.toString())),
            ),
          )
          .toList(),
    );

    final response = await _postWithRetry<Map<String, dynamic>>(
      () => _dio.postUri<Map<String, dynamic>>(
        _resolve(config.baseUrl, '/chat/completions'),
        data: {
          'model': config.model,
          'messages': messages,
          'tools': tools,
          'tool_choice': toolChoice,
        },
        options: Options(headers: _buildHeaders(config)),
        cancelToken: cancelToken,
      ),
    );

    final data = response.data;
    if (data == null) return null;

    final choices = data['choices'] as List?;
    if (choices == null || choices.isEmpty) return null;

    final message = (choices.first as Map)['message'] as Map?;
    if (message == null) return null;

    // Record usage.
    final usage = data['usage'] as Map?;
    final completionTokens = usage?['completion_tokens'];
    _recordUsage(
      LlmRequestUsage(
        phase: phase,
        model: config.model,
        inputTokens: estimatedInputTokens,
        outputTokens: completionTokens is int ? completionTokens : null,
        cachedTokens: _extractCachedTokens(usage),
        messageCount: messages.length,
        createdAt: DateTime.now(),
      ),
    );

    // Parse tool_calls.
    final toolCalls = message['tool_calls'] as List?;
    if (toolCalls == null || toolCalls.isEmpty) return null;

    final firstCall = toolCalls.first as Map;
    final function_ = firstCall['function'] as Map?;
    if (function_ == null) return null;

    final name = (function_['name'] ?? '').toString();
    if (name.isEmpty) return null;

    Map<String, dynamic> args;
    final rawArgs = function_['arguments'];
    if (rawArgs is String) {
      try {
        final decoded = jsonDecode(rawArgs);
        args = decoded is Map
            ? Map<String, dynamic>.from(decoded)
            : <String, dynamic>{};
      } catch (_) {
        args = <String, dynamic>{};
      }
    } else if (rawArgs is Map) {
      args = Map<String, dynamic>.from(rawArgs);
    } else {
      args = <String, dynamic>{};
    }

    return FunctionCallResult(
      toolName: name,
      args: args,
      toolCallId: (firstCall['id'] ?? '').toString(),
    );
  }

  Future<String> chatWithImage({
    required LlmProviderConfig config,
    required String prompt,
    required String imageDataUrl,
    String phase = 'vision',
    CancelToken? cancelToken,
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
      options: Options(headers: _buildHeaders(config)),
      cancelToken: cancelToken,
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
        cachedTokens: _extractCachedTokens(usage),
        messageCount: 1,
        createdAt: DateTime.now(),
      ),
    );
    return _normalizeContent(content);
  }

  Future<List<String>> fetchModels({
    required String baseUrl,
    required String apiKey,
    CancelToken? cancelToken,
  }) async {
    final response = await _dio.getUri<dynamic>(
      _resolve(baseUrl, '/models'),
      options: Options(
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        },
      ),
      cancelToken: cancelToken,
    );
    return _extractModelIds(response.data);
  }

  static List<String> _extractModelIds(dynamic data) {
    final rawItems = switch (data) {
      {'data': final List items} => items,
      {'models': final List items} => items,
      {'items': final List items} => items,
      final List items => items,
      _ => const <dynamic>[],
    };

    final out = <String>[];
    void add(dynamic value) {
      final trimmed = value?.toString().trim() ?? '';
      if (trimmed.isEmpty || out.contains(trimmed)) return;
      out.add(trimmed);
    }

    for (final item in rawItems) {
      if (item is String) {
        add(item);
      } else if (item is Map) {
        add(item['id'] ?? item['name'] ?? item['model']);
      }
    }
    return out;
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
