import 'dart:convert';

/// Local JSON recovery helpers shared by the planner and executor.
///
/// LLMs occasionally wrap JSON in markdown fences, prepend prose
/// ("Here is the JSON:"), or trail with explanations. Cheap local fixes
/// here avoid an extra paid LLM call to repair the response.
class JsonUtils {
  JsonUtils._();

  /// Parse a `Map<String, dynamic>` from raw LLM text.
  /// Returns null if no valid JSON object can be extracted locally.
  static Map<String, dynamic>? tryParseObject(String text) {
    final cleaned = _stripJsonWrappers(text);
    if (cleaned == null) return null;
    try {
      final decoded = jsonDecode(cleaned);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return null;
  }

  /// Heuristic local JSON recovery. Order of attempts:
  /// 1. Strip outer markdown code fences.
  /// 2. Extract the first balanced {...} block (drops leading/trailing prose).
  /// Returns null if no plausible JSON shape is found.
  static String? _stripJsonWrappers(String text) {
    var cleaned = text.trim();
    if (cleaned.isEmpty) return null;

    // Strip outer markdown fences (```json ... ``` or ``` ... ```).
    if (cleaned.startsWith('```')) {
      cleaned = cleaned.replaceFirst(RegExp(r'^```[a-zA-Z]*\n?'), '');
      final fenceClose = cleaned.lastIndexOf('```');
      if (fenceClose >= 0) {
        cleaned = cleaned.substring(0, fenceClose);
      }
      cleaned = cleaned.trim();
    }

    // Extract the first balanced {...} object using brace matching.
    // Tolerates leading prose and trailing commentary. Tracks string state
    // so braces inside strings (e.g. "{template}") don't confuse depth.
    final start = cleaned.indexOf('{');
    if (start < 0) return null;
    var depth = 0;
    var inString = false;
    var escape = false;
    for (var i = start; i < cleaned.length; i++) {
      final ch = cleaned[i];
      if (escape) {
        escape = false;
        continue;
      }
      if (ch == '\\') {
        escape = true;
        continue;
      }
      if (ch == '"') {
        inString = !inString;
        continue;
      }
      if (inString) continue;
      if (ch == '{') depth++;
      if (ch == '}') {
        depth--;
        if (depth == 0) {
          return cleaned.substring(start, i + 1).trim();
        }
      }
    }
    return null;
  }
}
