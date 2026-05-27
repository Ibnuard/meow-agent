import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'agent_appearance.dart';

/// An agent that references a provider by id.
class AgentModel {
  AgentModel({
    String? id,
    required this.name,
    required this.providerId,
    this.maxContextLength = 8191,
    String? iconKey,
    String? colorKey,
  })  : id = id ?? const Uuid().v4(),
        iconKey = (iconKey == null || iconKey.isEmpty)
            ? kDefaultAgentIconKey
            : iconKey,
        colorKey = (colorKey == null || colorKey.isEmpty)
            ? kDefaultAgentColorKey
            : colorKey;

  final String id;
  final String name;
  final String providerId;
  final int maxContextLength;

  /// Stable preset key for the avatar icon — see [kAgentIconOptions].
  final String iconKey;

  /// Stable preset key for the avatar tint — see [kAgentColorOptions].
  final String colorKey;

  bool get isComplete =>
      name.trim().isNotEmpty && providerId.trim().isNotEmpty;

  AgentModel copyWith({
    String? name,
    String? providerId,
    int? maxContextLength,
    String? iconKey,
    String? colorKey,
  }) {
    return AgentModel(
      id: id,
      name: name ?? this.name,
      providerId: providerId ?? this.providerId,
      maxContextLength: maxContextLength ?? this.maxContextLength,
      iconKey: iconKey ?? this.iconKey,
      colorKey: colorKey ?? this.colorKey,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'providerId': providerId,
        'maxContextLength': maxContextLength,
        'iconKey': iconKey,
        'colorKey': colorKey,
      };

  static AgentModel fromJson(Map<String, dynamic> json) {
    return AgentModel(
      id: json['id'] as String,
      name: (json['name'] as String?) ?? '',
      providerId: (json['providerId'] as String?) ?? '',
      maxContextLength: (json['maxContextLength'] as int?) ?? 8191,
      iconKey: json['iconKey'] as String?,
      colorKey: json['colorKey'] as String?,
    );
  }

  static String encodeList(List<AgentModel> list) =>
      jsonEncode(list.map((a) => a.toJson()).toList());

  static List<AgentModel> decodeList(String source) =>
      (jsonDecode(source) as List)
          .cast<Map<String, dynamic>>()
          .map(AgentModel.fromJson)
          .toList();
}
