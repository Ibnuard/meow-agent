import 'dart:convert';

import 'api_config.dart';

/// Parses a curl command string into an [ApiConfig].
///
/// Handles common curl flags: -X, -H, -d/--data, --data-raw, -u (basic auth).
/// Does not cover every curl edge case but handles the vast majority of
/// real-world paste-from-browser/Postman scenarios.
class CurlParser {
  CurlParser._();

  /// Parse a curl command string into an [ApiConfig].
  /// Returns null if the input is not a recognizable curl command.
  static ApiConfig? parse(String input) {
    final trimmed = input.trim();
    if (!trimmed.startsWith('curl')) return null;

    // Normalize line continuations (backslash + newline).
    final normalized = trimmed
        .replaceAll('\\\n', ' ')
        .replaceAll('\\\r\n', ' ')
        .replaceAll(RegExp(r'\s+'), ' ');

    final tokens = _tokenize(normalized);
    if (tokens.isEmpty) return null;

    String? url;
    String method = 'GET';
    final headers = <ApiParam>[];
    String? bodyRaw;
    ApiAuth auth = const ApiAuth();

    var i = 0;
    // Skip "curl" token.
    if (tokens.isNotEmpty && tokens[0].toLowerCase() == 'curl') i = 1;

    while (i < tokens.length) {
      final token = tokens[i];

      if (token == '-X' || token == '--request') {
        i++;
        if (i < tokens.length) method = tokens[i].toUpperCase();
      } else if (token == '-H' || token == '--header') {
        i++;
        if (i < tokens.length) {
          final header = _parseHeader(tokens[i]);
          if (header != null) {
            // Detect auth from headers.
            if (header.key.toLowerCase() == 'authorization') {
              auth = _parseAuthFromValue(header.value);
            } else if (header.key.toLowerCase() != 'content-type') {
              headers.add(header);
            }
          }
        }
      } else if (token == '-d' ||
          token == '--data' ||
          token == '--data-raw' ||
          token == '--data-binary') {
        i++;
        if (i < tokens.length) {
          bodyRaw = tokens[i];
          if (method == 'GET') method = 'POST';
        }
      } else if (token == '-u' || token == '--user') {
        i++;
        if (i < tokens.length) {
          auth = ApiAuth(type: ApiAuthType.basic, value: tokens[i]);
        }
      } else if (!token.startsWith('-') && url == null) {
        // Positional argument = URL.
        url = token;
      }
      i++;
    }

    if (url == null || url.isEmpty) return null;

    // Strip query params from URL and parse them separately.
    final uri = Uri.tryParse(url);
    final queryParams = <ApiParam>[];
    String cleanUrl = url;
    if (uri != null && uri.queryParameters.isNotEmpty) {
      cleanUrl = uri.replace(queryParameters: {}).toString();
      if (cleanUrl.endsWith('?')) {
        cleanUrl = cleanUrl.substring(0, cleanUrl.length - 1);
      }
      uri.queryParameters.forEach((key, value) {
        queryParams.add(ApiParam(key: key, value: value));
      });
    }

    // Parse body into tree if it's valid JSON.
    BodyMode bodyMode = BodyMode.none;
    List<BodyNode> bodyTree = [];
    if (bodyRaw != null && bodyRaw.isNotEmpty) {
      bodyMode = BodyMode.raw;
      try {
        final parsed = _tryParseJsonToTree(bodyRaw);
        if (parsed != null) {
          bodyTree = parsed;
          bodyMode = BodyMode.tree;
        }
      } catch (_) {}
    }

    return ApiConfig(
      id: ApiConfig.generateId(),
      name: '',
      url: cleanUrl,
      method: method,
      auth: auth,
      headers: headers,
      queryParams: queryParams,
      bodyMode: bodyMode,
      bodyTree: bodyTree,
      bodyRaw: bodyMode == BodyMode.raw ? bodyRaw : null,
    );
  }

  /// Tokenize respecting quoted strings.
  static List<String> _tokenize(String input) {
    final tokens = <String>[];
    final buf = StringBuffer();
    String? quote;

    for (var i = 0; i < input.length; i++) {
      final c = input[i];
      if (quote != null) {
        if (c == quote) {
          tokens.add(buf.toString());
          buf.clear();
          quote = null;
        } else {
          buf.write(c);
        }
      } else if (c == '"' || c == "'") {
        if (buf.isNotEmpty) {
          tokens.add(buf.toString());
          buf.clear();
        }
        quote = c;
      } else if (c == ' ') {
        if (buf.isNotEmpty) {
          tokens.add(buf.toString());
          buf.clear();
        }
      } else {
        buf.write(c);
      }
    }
    if (buf.isNotEmpty) tokens.add(buf.toString());
    return tokens;
  }

  static ApiParam? _parseHeader(String raw) {
    final colon = raw.indexOf(':');
    if (colon < 0) return null;
    final key = raw.substring(0, colon).trim();
    final value = raw.substring(colon + 1).trim();
    return ApiParam(key: key, value: value);
  }

  static ApiAuth _parseAuthFromValue(String value) {
    final lower = value.toLowerCase();
    if (lower.startsWith('bearer ')) {
      return ApiAuth(type: ApiAuthType.bearer, value: value.substring(7).trim());
    }
    if (lower.startsWith('basic ')) {
      return ApiAuth(type: ApiAuthType.basic, value: value.substring(6).trim());
    }
    // Treat as API key in Authorization header.
    return ApiAuth(
      type: ApiAuthType.apiKeyHeader,
      value: value,
      headerName: 'Authorization',
    );
  }

  /// Try to parse a JSON string into a list of BodyNode (top-level object keys).
  static List<BodyNode>? _tryParseJsonToTree(String raw) {
    final dynamic parsed;
    try {
      parsed = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (parsed is! Map<String, dynamic>) return null;
    return parsed.entries.map((e) => _valueToNode(e.key, e.value)).toList();
  }

  static BodyNode _valueToNode(String key, dynamic value) {
    if (value is String) {
      return BodyNode(key: key, type: 'string', value: value);
    }
    if (value is num) {
      return BodyNode(key: key, type: 'number', value: value.toString());
    }
    if (value is bool) {
      return BodyNode(key: key, type: 'boolean', value: value.toString());
    }
    if (value is Map<String, dynamic>) {
      return BodyNode(
        key: key,
        type: 'object',
        children:
            value.entries.map((e) => _valueToNode(e.key, e.value)).toList(),
      );
    }
    if (value is List) {
      return BodyNode(
        key: key,
        type: 'array',
        items: value
            .asMap()
            .entries
            .map((e) => _valueToNode('${e.key}', e.value))
            .toList(),
      );
    }
    return BodyNode(key: key, type: 'string', value: value?.toString() ?? '');
  }
}
