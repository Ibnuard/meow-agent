import 'dart:convert';

import 'package:uuid/uuid.dart';

/// An agent that references a provider by id.
class AgentModel {
  AgentModel({
    String? id,
    required this.name,
    required this.providerId,
    this.maxContextLength = 8191,
  }) : id = id ?? const Uuid().v4();

  final String id;
  final String name;
  final String providerId;
  final int maxContextLength;

  bool get isComplete => name.trim().isNotEmpty && providerId.trim().isNotEmpty;

  AgentModel copyWith({String? name, String? providerId, int? maxContextLength}) {
    return AgentModel(
      id: id,
      name: name ?? this.name,
      providerId: providerId ?? this.providerId,
      maxContextLength: maxContextLength ?? this.maxContextLength,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'providerId': providerId,
        'maxContextLength': maxContextLength,
      };

  static AgentModel fromJson(Map<String, dynamic> json) {
    return AgentModel(
      id: json['id'] as String,
      name: (json['name'] as String?) ?? '',
      providerId: (json['providerId'] as String?) ?? '',
      maxContextLength: (json['maxContextLength'] as int?) ?? 8191,
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

