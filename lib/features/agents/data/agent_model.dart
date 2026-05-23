import 'dart:convert';

import 'package:uuid/uuid.dart';

/// An agent that references a provider by id.
class AgentModel {
  AgentModel({
    String? id,
    required this.name,
    required this.providerId,
  }) : id = id ?? const Uuid().v4();

  final String id;
  final String name;
  final String providerId;

  bool get isComplete => name.trim().isNotEmpty && providerId.trim().isNotEmpty;

  AgentModel copyWith({String? name, String? providerId}) {
    return AgentModel(
      id: id,
      name: name ?? this.name,
      providerId: providerId ?? this.providerId,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'providerId': providerId,
      };

  static AgentModel fromJson(Map<String, dynamic> json) {
    return AgentModel(
      id: json['id'] as String,
      name: (json['name'] as String?) ?? '',
      providerId: (json['providerId'] as String?) ?? '',
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
