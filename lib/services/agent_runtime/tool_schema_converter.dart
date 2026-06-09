import 'runtime_models.dart';

/// Converts [ToolDefinition] instances to the OpenAI function calling
/// `tools` array format. Used by the fast-path FC selector to send tool
/// schemas as API parameters instead of prompt text.
class ToolSchemaConverter {
  ToolSchemaConverter._();

  /// Convert a list of [ToolDefinition]s to OpenAI-compatible tools array.
  ///
  /// Each entry:
  /// ```json
  /// {
  ///   "type": "function",
  ///   "function": {
  ///     "name": "app.open",
  ///     "description": "...",
  ///     "parameters": { "type": "object", "properties": {...}, "required": [...] }
  ///   }
  /// }
  /// ```
  static List<Map<String, dynamic>> toOpenAiTools(List<ToolDefinition> tools) {
    return tools.map(_convertTool).toList(growable: false);
  }

  static Map<String, dynamic> _convertTool(ToolDefinition tool) {
    final properties = <String, dynamic>{};
    final required = <String>[];

    for (final entry in tool.inputSchema.entries) {
      final parsed = _parseArgSpec(entry.key, entry.value);
      properties[entry.key] = parsed['schema'];
      if (parsed['required'] == true) {
        required.add(entry.key);
      }
    }

    return {
      'type': 'function',
      'function': {
        'name': tool.name,
        'description': tool.description,
        'parameters': {
          'type': 'object',
          'properties': properties,
          if (required.isNotEmpty) 'required': required,
        },
      },
    };
  }

  /// Parse a single inputSchema entry like `'string (required)'` or
  /// `'int (optional, default 10)'` into a JSON Schema property + required flag.
  static Map<String, dynamic> _parseArgSpec(String key, String spec) {
    final lower = spec.toLowerCase();
    final isRequired = lower.contains('required');

    // Detect type
    String type = 'string';
    if (lower.startsWith('int') || lower.startsWith('number')) {
      type = 'integer';
    } else if (lower.startsWith('bool')) {
      type = 'boolean';
    } else if (lower.startsWith('list') || lower.startsWith('array')) {
      type = 'array';
    } else if (lower.startsWith('object') || lower.startsWith('map')) {
      type = 'object';
    }

    // Build schema
    final schema = <String, dynamic>{'type': type};

    // Extract enum from "required: A|B|C" pattern.
    final enumMatch = RegExp(r'required:\s*([^)]+)').firstMatch(lower);
    if (enumMatch != null) {
      // Re-extract from the original spec to preserve casing.
      final originalMatch = RegExp(
        r'required:\s*([^)]+)',
        caseSensitive: false,
      ).firstMatch(spec);
      final values = (originalMatch?.group(1) ?? '')
          .split('|')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      if (values.length > 1) {
        schema['enum'] = values;
      }
    }

    // For array type, specify items
    if (type == 'array') {
      // Try to detect item type from "list<string>" pattern
      final itemMatch = RegExp(r'list<(\w+)>|array<(\w+)>').firstMatch(lower);
      final itemType = itemMatch?.group(1) ?? itemMatch?.group(2) ?? 'string';
      schema['items'] = {'type': itemType == 'int' ? 'integer' : itemType};
    }

    // Add description (the raw spec minus type prefix for context)
    schema['description'] = spec;

    return {
      'schema': schema,
      'required': isRequired,
    };
  }
}
