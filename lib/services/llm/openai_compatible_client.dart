import 'package:dio/dio.dart';

import '../../features/settings/data/llm_provider_config.dart';

/// Minimal OpenAI-compatible chat completions client.
///
/// Only [chat] is needed for the MVP. The class also supports a lightweight
/// [testConnection] method used by the Set Up screen to validate the user's
/// credentials before saving them.
class OpenAiCompatibleClient {
  OpenAiCompatibleClient({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  Uri _resolve(String baseUrl, String path) {
    final trimmed = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$trimmed$path');
  }

  Future<String> chat({
    required LlmProviderConfig config,
    required List<Map<String, String>> messages,
  }) async {
    final response = await _dio.postUri<Map<String, dynamic>>(
      _resolve(config.baseUrl, '/chat/completions'),
      data: {
        'model': config.model,
        'messages': messages,
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
    return content;
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
}
