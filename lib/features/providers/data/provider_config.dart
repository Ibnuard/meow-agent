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
    List<String>? models,
  }) : id = id ?? const Uuid().v4(),
       models = _normalizeModels(model, models);

  final String id;
  final String nickname;
  final String baseUrl;
  final String apiKey;
  final String model;
  final List<String> models;

  bool get isComplete =>
      nickname.trim().isNotEmpty &&
      baseUrl.trim().isNotEmpty &&
      apiKey.trim().isNotEmpty &&
      models.isNotEmpty;

  String effectiveModel(String? selectedModel) {
    final selected = (selectedModel ?? '').trim();
    if (selected.isNotEmpty && models.contains(selected)) return selected;
    return model.trim().isNotEmpty ? model.trim() : models.first;
  }

  ProviderConfig copyWith({
    String? nickname,
    String? baseUrl,
    String? apiKey,
    String? model,
    List<String>? models,
  }) {
    return ProviderConfig(
      id: id,
      nickname: nickname ?? this.nickname,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      models: models ?? this.models,
    );
  }

  /// Public JSON (no API key).
  Map<String, dynamic> toPublicJson() => {
    'id': id,
    'nickname': nickname,
    'baseUrl': baseUrl,
    'model': model,
    'models': models,
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
      models: (json['models'] as List?)?.map((e) => e.toString()).toList(),
    );
  }

  static List<String> _normalizeModels(String model, List<String>? models) {
    final out = <String>[];
    void add(String value) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return;
      if (!out.contains(trimmed)) out.add(trimmed);
    }

    add(model);
    for (final item in models ?? const <String>[]) {
      add(item);
    }
    return out;
  }

  static String encodeList(List<ProviderConfig> list) =>
      jsonEncode(list.map((p) => p.toPublicJson()).toList());

  static List<Map<String, dynamic>> decodeList(String source) =>
      (jsonDecode(source) as List).cast<Map<String, dynamic>>();
}
