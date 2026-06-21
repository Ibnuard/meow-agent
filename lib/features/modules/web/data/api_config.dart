import 'dart:convert';

/// Mode for a parameter value: fixed (always sent as-is) or dynamic
/// (agent fills from user context at runtime).
enum ParamMode { fixed, dynamic }

/// A single key-value parameter with optional dynamic resolution.
class ApiParam {
  const ApiParam({
    required this.key,
    required this.value,
    this.mode = ParamMode.fixed,
    this.hint,
    this.defaultValue,
  });

  final String key;

  /// For [ParamMode.fixed]: the literal value sent.
  /// For [ParamMode.dynamic]: ignored at runtime (agent fills), but may
  /// hold a sample value for the UI "Test" feature.
  final String value;

  final ParamMode mode;

  /// Human-readable hint shown to the agent for dynamic params.
  /// E.g. "search keyword", "page number (1-100)".
  final String? hint;

  /// Fallback value used when the agent cannot infer from context.
  /// Empty string means "omit this param entirely".
  final String? defaultValue;

  Map<String, dynamic> toJson() => {
        'key': key,
        'value': value,
        'mode': mode.name,
        if (hint != null && hint!.isNotEmpty) 'hint': hint,
        if (defaultValue != null) 'default': defaultValue,
      };

  factory ApiParam.fromJson(Map<String, dynamic> json) => ApiParam(
        key: json['key'] as String? ?? '',
        value: json['value'] as String? ?? '',
        mode: json['mode'] == 'dynamic' ? ParamMode.dynamic : ParamMode.fixed,
        hint: json['hint'] as String?,
        defaultValue: json['default'] as String?,
      );
}

/// Authentication type for an API.
enum ApiAuthType { none, bearer, apiKeyHeader, basic }

/// Auth configuration.
class ApiAuth {
  const ApiAuth({this.type = ApiAuthType.none, this.value = '', this.headerName});

  final ApiAuthType type;

  /// For bearer: the token. For apiKeyHeader: the key value.
  /// For basic: "username:password" encoded.
  final String value;

  /// Only for [ApiAuthType.apiKeyHeader]: the header name (e.g. "X-API-Key").
  final String? headerName;

  Map<String, dynamic> toJson() => {
        'type': type.name,
        if (value.isNotEmpty) 'value': value,
        if (headerName != null && headerName!.isNotEmpty)
          'header_name': headerName,
      };

  factory ApiAuth.fromJson(Map<String, dynamic> json) => ApiAuth(
        type: ApiAuthType.values.firstWhere(
          (e) => e.name == (json['type'] as String? ?? 'none'),
          orElse: () => ApiAuthType.none,
        ),
        value: json['value'] as String? ?? '',
        headerName: json['header_name'] as String?,
      );
}

/// Body content mode.
enum BodyMode { none, tree, raw }

/// Nested JSON tree node for the visual body builder.
class BodyNode {
  BodyNode({
    required this.key,
    required this.type,
    this.value,
    this.mode = ParamMode.fixed,
    this.hint,
    this.defaultValue,
    List<BodyNode>? children,
    List<BodyNode>? items,
  })  : children = children ?? [],
        items = items ?? [];

  final String key;

  /// One of: string, number, boolean, object, array
  final String type;

  /// Leaf value (for string/number/boolean).
  final String? value;
  final ParamMode mode;
  final String? hint;
  final String? defaultValue;

  /// Children nodes (for type == 'object').
  final List<BodyNode> children;

  /// Array items (for type == 'array').
  final List<BodyNode> items;

  Map<String, dynamic> toJson() => {
        'key': key,
        'type': type,
        if (value != null) 'value': value,
        'mode': mode.name,
        if (hint != null && hint!.isNotEmpty) 'hint': hint,
        if (defaultValue != null) 'default': defaultValue,
        if (children.isNotEmpty)
          'children': children.map((c) => c.toJson()).toList(),
        if (items.isNotEmpty) 'items': items.map((c) => c.toJson()).toList(),
      };

  factory BodyNode.fromJson(Map<String, dynamic> json) => BodyNode(
        key: json['key'] as String? ?? '',
        type: json['type'] as String? ?? 'string',
        value: json['value'] as String?,
        mode: json['mode'] == 'dynamic' ? ParamMode.dynamic : ParamMode.fixed,
        hint: json['hint'] as String?,
        defaultValue: json['default'] as String?,
        children: (json['children'] as List?)
                ?.map((c) => BodyNode.fromJson(c as Map<String, dynamic>))
                .toList() ??
            [],
        items: (json['items'] as List?)
                ?.map((c) => BodyNode.fromJson(c as Map<String, dynamic>))
                .toList() ??
            [],
      );
}

/// Full API configuration stored in the global registry.
class ApiConfig {
  ApiConfig({
    required this.id,
    required this.name,
    required this.url,
    this.method = 'GET',
    this.auth = const ApiAuth(),
    this.headers = const [],
    this.queryParams = const [],
    this.bodyMode = BodyMode.none,
    this.bodyTree = const [],
    this.bodyRaw,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  final String name;
  final String url;
  final String method;
  final ApiAuth auth;
  final List<ApiParam> headers;
  final List<ApiParam> queryParams;
  final BodyMode bodyMode;
  final List<BodyNode> bodyTree;
  final String? bodyRaw;
  final DateTime createdAt;

  /// Unique short ID generation.
  static String generateId() =>
      DateTime.now().millisecondsSinceEpoch.toRadixString(36);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'method': method,
        'auth': auth.toJson(),
        'headers': headers.map((h) => h.toJson()).toList(),
        'query_params': queryParams.map((q) => q.toJson()).toList(),
        'body_mode': bodyMode.name,
        'body_tree': bodyTree.map((n) => n.toJson()).toList(),
        if (bodyRaw != null) 'body_raw': bodyRaw,
        'created_at': createdAt.toIso8601String(),
      };

  factory ApiConfig.fromJson(Map<String, dynamic> json) => ApiConfig(
        id: json['id'] as String? ?? ApiConfig.generateId(),
        name: json['name'] as String? ?? '',
        url: json['url'] as String? ?? '',
        method: json['method'] as String? ?? 'GET',
        auth: json['auth'] != null
            ? ApiAuth.fromJson(json['auth'] as Map<String, dynamic>)
            : const ApiAuth(),
        headers: (json['headers'] as List?)
                ?.map((h) => ApiParam.fromJson(h as Map<String, dynamic>))
                .toList() ??
            [],
        queryParams: (json['query_params'] as List?)
                ?.map((q) => ApiParam.fromJson(q as Map<String, dynamic>))
                .toList() ??
            [],
        bodyMode: BodyMode.values.firstWhere(
          (e) => e.name == (json['body_mode'] as String? ?? 'none'),
          orElse: () => BodyMode.none,
        ),
        bodyTree: (json['body_tree'] as List?)
                ?.map((n) => BodyNode.fromJson(n as Map<String, dynamic>))
                .toList() ??
            [],
        bodyRaw: json['body_raw'] as String?,
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
      );

  /// Serialize the entire config to a JSON string.
  String encode() => jsonEncode(toJson());

  /// Deserialize from a JSON string.
  factory ApiConfig.decode(String source) =>
      ApiConfig.fromJson(jsonDecode(source) as Map<String, dynamic>);
}
