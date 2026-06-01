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
    List<String>? visionModels,
  }) : id = id ?? const Uuid().v4(),
       models = _normalizeModels(model, models),
       visionModels = _normalizeVisionModels(
         _normalizeModels(model, models),
         visionModels,
       );

  final String id;
  final String nickname;
  final String baseUrl;
  final String apiKey;
  final String model;
  final List<String> models;
  final List<String> visionModels;

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

  bool supportsVisionFor(String? selectedModel) {
    final selected = (selectedModel ?? '').trim();
    if (selected.isEmpty) return false;
    return visionModels.contains(selected);
  }

  ProviderConfig copyWith({
    String? nickname,
    String? baseUrl,
    String? apiKey,
    String? model,
    List<String>? models,
    List<String>? visionModels,
  }) {
    return ProviderConfig(
      id: id,
      nickname: nickname ?? this.nickname,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      models: models ?? this.models,
      visionModels: visionModels ?? this.visionModels,
    );
  }

  /// Public JSON (no API key).
  Map<String, dynamic> toPublicJson() => {
    'id': id,
    'nickname': nickname,
    'baseUrl': baseUrl,
    'model': model,
    'models': models,
    'visionModels': visionModels,
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
      visionModels: (json['visionModels'] as List?)
          ?.map((e) => e.toString())
          .toList(),
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

  static List<String> _normalizeVisionModels(
    List<String> models,
    List<String>? visionModels,
  ) {
    final valid = models.toSet();
    final out = <String>[];
    for (final item in visionModels ?? const <String>[]) {
      final trimmed = item.trim();
      if (trimmed.isEmpty || !valid.contains(trimmed)) continue;
      if (!out.contains(trimmed)) out.add(trimmed);
    }
    return out;
  }

  static String encodeList(List<ProviderConfig> list) =>
      jsonEncode(list.map((p) => p.toPublicJson()).toList());

  static List<Map<String, dynamic>> decodeList(String source) =>
      (jsonDecode(source) as List).cast<Map<String, dynamic>>();
}
