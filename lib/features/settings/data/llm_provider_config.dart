import 'dart:convert';

/// Configuration for an OpenAI-compatible LLM provider used by the
/// Master Agent.
class LlmProviderConfig {
  const LlmProviderConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });

  final String baseUrl;
  final String apiKey;
  final String model;

  bool get isComplete =>
      baseUrl.trim().isNotEmpty &&
      apiKey.trim().isNotEmpty &&
      model.trim().isNotEmpty;

  LlmProviderConfig copyWith({
    String? baseUrl,
    String? apiKey,
    String? model,
  }) {
    return LlmProviderConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
    );
  }

  /// Public fields only. Used for non-sensitive storage. The api key
  /// is persisted separately via secure storage.
  Map<String, dynamic> toPublicJson() => {
        'baseUrl': baseUrl,
        'model': model,
      };

  static LlmProviderConfig fromPublicJson(
    Map<String, dynamic> json, {
    required String apiKey,
  }) {
    return LlmProviderConfig(
      baseUrl: (json['baseUrl'] as String?) ?? '',
      apiKey: apiKey,
      model: (json['model'] as String?) ?? '',
    );
  }

  static String encodePublic(LlmProviderConfig config) =>
      jsonEncode(config.toPublicJson());

  static LlmProviderConfig decodePublic(
    String source, {
    required String apiKey,
  }) =>
      fromPublicJson(jsonDecode(source) as Map<String, dynamic>, apiKey: apiKey);
}
