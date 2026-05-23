import 'dart:convert';

import 'package:uuid/uuid.dart';

/// A saved LLM provider connection.
///
/// Multiple agents can reference the same provider by its [id].
class ProviderConfig {
  ProviderConfig({
    String? id,
    required this.nickname,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  }) : id = id ?? const Uuid().v4();

  final String id;
  final String nickname;
  final String baseUrl;
  final String apiKey;
  final String model;

  bool get isComplete =>
      nickname.trim().isNotEmpty &&
      baseUrl.trim().isNotEmpty &&
      apiKey.trim().isNotEmpty &&
      model.trim().isNotEmpty;

  ProviderConfig copyWith({
    String? nickname,
    String? baseUrl,
    String? apiKey,
    String? model,
  }) {
    return ProviderConfig(
      id: id,
      nickname: nickname ?? this.nickname,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
    );
  }

  /// Public JSON (no API key).
  Map<String, dynamic> toPublicJson() => {
        'id': id,
        'nickname': nickname,
        'baseUrl': baseUrl,
        'model': model,
      };

  static ProviderConfig fromPublicJson(
    Map<String, dynamic> json, {
    required String apiKey,
  }) {
    return ProviderConfig(
      id: json['id'] as String,
      nickname: (json['nickname'] as String?) ?? '',
      baseUrl: (json['baseUrl'] as String?) ?? '',
      apiKey: apiKey,
      model: (json['model'] as String?) ?? '',
    );
  }

  static String encodeList(List<ProviderConfig> list) =>
      jsonEncode(list.map((p) => p.toPublicJson()).toList());

  static List<Map<String, dynamic>> decodeList(String source) =>
      (jsonDecode(source) as List).cast<Map<String, dynamic>>();
}
