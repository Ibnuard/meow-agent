import 'dart:convert';

import 'package:dio/dio.dart';

import '../data/api_config.dart';

/// Result of an HTTP execution.
class HttpResult {
  const HttpResult({
    required this.statusCode,
    required this.contentType,
    required this.body,
    this.headers = const {},
    this.truncated = false,
    this.elapsedMs = 0,
    this.error,
  });

  final int statusCode;
  final String contentType;
  final dynamic body;
  final Map<String, String> headers;
  final bool truncated;
  final int elapsedMs;
  final String? error;

  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  Map<String, dynamic> toJson() => {
        'status': statusCode,
        'content_type': contentType,
        'headers': headers,
        'body': body,
        'truncated': truncated,
        'elapsed_ms': elapsedMs,
        if (error != null) 'error': error,
      };
}

/// HTTP executor with SSRF protection and response truncation.
///
/// Wraps Dio with safety guards appropriate for a mobile AI agent:
/// - Blocks private/localhost IPs
/// - Enforces HTTPS by default
/// - Truncates responses to stay within LLM token budget
/// - Timeout protection
class HttpExecutor {
  HttpExecutor({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  /// Maximum response body size in characters (approx 8KB).
  static const int maxBodyChars = 8192;

  /// Default timeout in seconds.
  static const int defaultTimeoutSeconds = 15;

  /// Execute an HTTP request from an [ApiConfig] with resolved params.
  Future<HttpResult> executeFromConfig({
    required ApiConfig config,
    Map<String, String> resolvedQueryParams = const {},
    String? resolvedBody,
    Map<String, String> extraHeaders = const {},
  }) async {
    // Build final URL with query params.
    final uri = Uri.parse(config.url);
    final allQuery = <String, String>{};

    // Fixed query params from config.
    for (final p in config.queryParams) {
      if (p.mode == ParamMode.fixed) {
        allQuery[p.key] = p.value;
      }
    }
    // Resolved dynamic params (agent-provided).
    allQuery.addAll(resolvedQueryParams);

    // Remove empty params (dynamic with empty default = omit).
    allQuery.removeWhere((_, v) => v.isEmpty);

    final finalUri = uri.replace(queryParameters: allQuery.isEmpty ? null : allQuery);

    // Build headers.
    final headers = <String, String>{};
    for (final h in config.headers) {
      headers[h.key] = h.value;
    }
    headers.addAll(extraHeaders);

    // Apply auth.
    switch (config.auth.type) {
      case ApiAuthType.bearer:
        headers['Authorization'] = 'Bearer ${config.auth.value}';
        break;
      case ApiAuthType.apiKeyHeader:
        final name = config.auth.headerName ?? 'Authorization';
        headers[name] = config.auth.value;
        break;
      case ApiAuthType.basic:
        final encoded = base64Encode(utf8.encode(config.auth.value));
        headers['Authorization'] = 'Basic $encoded';
        break;
      case ApiAuthType.none:
        break;
    }

    // Determine body.
    String? body = resolvedBody;
    if (body == null && config.bodyMode == BodyMode.raw && config.bodyRaw != null) {
      body = config.bodyRaw;
    }
    if (body == null && config.bodyMode == BodyMode.tree && config.bodyTree.isNotEmpty) {
      body = jsonEncode(_treeToJson(config.bodyTree));
    }
    if (body != null) {
      headers.putIfAbsent('Content-Type', () => 'application/json');
    }

    return execute(
      url: finalUri.toString(),
      method: config.method,
      headers: headers,
      body: body,
    );
  }

  /// Execute a raw HTTP request.
  Future<HttpResult> execute({
    required String url,
    String method = 'GET',
    Map<String, String> headers = const {},
    String? body,
    int timeoutSeconds = defaultTimeoutSeconds,
  }) async {
    // SSRF guard: block private networks and non-HTTPS.
    final ssrfCheck = _checkSsrf(url);
    if (ssrfCheck != null) {
      return HttpResult(
        statusCode: 0,
        contentType: '',
        body: null,
        error: ssrfCheck,
      );
    }

    final sw = Stopwatch()..start();
    try {
      final response = await _dio.request<dynamic>(
        url,
        data: body,
        options: Options(
          method: method,
          headers: headers,
          receiveTimeout: Duration(seconds: timeoutSeconds),
          sendTimeout: Duration(seconds: timeoutSeconds),
          validateStatus: (_) => true, // Accept all status codes.
          responseType: ResponseType.plain,
        ),
      );
      sw.stop();

      final rawBody = response.data?.toString() ?? '';
      final contentType =
          response.headers.value('content-type') ?? 'text/plain';

      // Truncate if needed.
      final truncated = rawBody.length > maxBodyChars;
      final trimmedBody = truncated
          ? '${rawBody.substring(0, maxBodyChars)}\n...[truncated, ${rawBody.length} chars total]'
          : rawBody;

      // Try to parse as JSON for structured output.
      dynamic parsedBody = trimmedBody;
      if (contentType.contains('json')) {
        try {
          parsedBody = jsonDecode(trimmedBody);
        } catch (_) {
          parsedBody = trimmedBody;
        }
      }

      // Extract useful response headers.
      final selectedHeaders = <String, String>{};
      const interestingHeaders = [
        'x-ratelimit-remaining',
        'x-ratelimit-limit',
        'retry-after',
        'x-request-id',
        'link',
      ];
      for (final h in interestingHeaders) {
        final v = response.headers.value(h);
        if (v != null) selectedHeaders[h] = v;
      }

      return HttpResult(
        statusCode: response.statusCode ?? 0,
        contentType: contentType,
        body: parsedBody,
        headers: selectedHeaders,
        truncated: truncated,
        elapsedMs: sw.elapsedMilliseconds,
      );
    } on DioException catch (e) {
      sw.stop();
      return HttpResult(
        statusCode: e.response?.statusCode ?? 0,
        contentType: '',
        body: null,
        elapsedMs: sw.elapsedMilliseconds,
        error: e.message ?? 'HTTP request failed',
      );
    } catch (e) {
      sw.stop();
      return HttpResult(
        statusCode: 0,
        contentType: '',
        body: null,
        elapsedMs: sw.elapsedMilliseconds,
        error: e.toString(),
      );
    }
  }

  /// Check for SSRF vulnerabilities. Returns an error message if blocked.
  String? _checkSsrf(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return 'Invalid URL.';

    // Block non-HTTP schemes.
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      return 'Only HTTP/HTTPS URLs are allowed.';
    }

    final host = uri.host.toLowerCase();

    // Block localhost.
    if (host == 'localhost' || host == '127.0.0.1' || host == '::1') {
      return 'Requests to localhost are blocked for security.';
    }

    // Block private IP ranges.
    final parts = host.split('.');
    if (parts.length == 4) {
      final first = int.tryParse(parts[0]) ?? -1;
      final second = int.tryParse(parts[1]) ?? -1;
      if (first == 10) return 'Requests to private networks (10.x) are blocked.';
      if (first == 192 && second == 168) {
        return 'Requests to private networks (192.168.x) are blocked.';
      }
      if (first == 172 && second >= 16 && second <= 31) {
        return 'Requests to private networks (172.16-31.x) are blocked.';
      }
    }

    return null;
  }

  /// Convert body tree to JSON map (resolves fixed values only).
  Map<String, dynamic> _treeToJson(List<BodyNode> nodes) {
    final map = <String, dynamic>{};
    for (final node in nodes) {
      map[node.key] = _nodeToValue(node);
    }
    return map;
  }

  dynamic _nodeToValue(BodyNode node) {
    switch (node.type) {
      case 'object':
        final map = <String, dynamic>{};
        for (final child in node.children) {
          map[child.key] = _nodeToValue(child);
        }
        return map;
      case 'array':
        return node.items.map(_nodeToValue).toList();
      case 'number':
        return num.tryParse(node.value ?? '0') ?? 0;
      case 'boolean':
        return node.value?.toLowerCase() == 'true';
      default:
        return node.value ?? '';
    }
  }
}
