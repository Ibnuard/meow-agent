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
    List<String>? functionCallingModels,
    this.codename,
  }) : id = id ?? const Uuid().v4(),
       models = _normalizeModels(model, models),
       visionModels = _normalizeVisionModels(
         _normalizeModels(model, models),
         visionModels,
       ),
       functionCallingModels = _normalizeFunctionCallingModels(
         _normalizeModels(model, models),
         functionCallingModels,
       );

  final String id;
  final String nickname;
  final String baseUrl;
  final String apiKey;
  final String model;
  final List<String> models;
  final List<String> visionModels;
  final List<String> functionCallingModels;
  final String? codename;

  String get displayCode =>
      (codename != null && codename!.trim().isNotEmpty)
          ? codename!.trim().toUpperCase()
          : nickname.replaceAll(RegExp(r'\s+'), '').substring(0, nickname.length < 4 ? nickname.length : 4).toUpperCase();

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

  bool supportsFunctionCallingFor(String? selectedModel) {
    final selected = (selectedModel ?? '').trim();
    if (selected.isEmpty) return false;
    return functionCallingModels.contains(selected);
  }

  ProviderConfig copyWith({
    String? nickname,
    String? baseUrl,
    String? apiKey,
    String? model,
    List<String>? models,
    List<String>? visionModels,
    List<String>? functionCallingModels,
    String? codename,
  }) {
    return ProviderConfig(
      id: id,
      nickname: nickname ?? this.nickname,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      models: models ?? this.models,
      visionModels: visionModels ?? this.visionModels,
      functionCallingModels:
          functionCallingModels ?? this.functionCallingModels,
      codename: codename ?? this.codename,
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
    'functionCallingModels': functionCallingModels,
    if (codename != null && codename!.trim().isNotEmpty) 'codename': codename!.trim(),
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
      functionCallingModels: (json['functionCallingModels'] as List?)
          ?.map((e) => e.toString())
          .toList(),
      codename: (json['codename'] as String?)?.trim(),
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

  static List<String> _normalizeFunctionCallingModels(
    List<String> models,
    List<String>? functionCallingModels,
  ) {
    final valid = models.toSet();
    final out = <String>[];
    for (final item in functionCallingModels ?? const <String>[]) {
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
