import 'package:sqflite/sqflite.dart';
import '../../core/storage/meow_database.dart';
import '../../services/agent_runtime/module_plugin.dart';
import '../../services/agent_runtime/runtime_models.dart';

class MiniAppModulePlugin extends ModulePlugin {
  const MiniAppModulePlugin();

  @override
  String get moduleId => 'miniapp';

  @override
  String get catalogGroup => 'miniapp';

  @override
  List<String> get capabilityHints => const [
    'mini app',
    'app builder',
    'expense tracker',
    'calorie tracker',
    'calculator',
  ];

  @override
  List<ToolDefinition> get toolDefinitions => const [
    ToolDefinition(
      name: 'miniapp.list',
      description: 'List all installed user Mini Apps.',
      risk: 'safe',
      requiresConfirmation: false,
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'miniapp.create',
      description:
          'Create a new custom local Mini App. This tool never overwrites an existing Mini App; use miniapp.patch for every edit or redesign.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'id': 'string (required, snake_case unique ID, e.g. expense_tracker)',
        'name': 'string (required, user-facing title, e.g. Expense Tracker)',
        'icon': 'string (optional, icon asset or character code)',
        'codeHtml':
            'string (required, full UI and logic definition containing window.meow SDK integration)',
      },
      operation: 'create',
      targetEntity: 'miniapp',
      selectorArgs: ['id'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'miniapp',
        expectedDataKeys: ['id', 'created', 'persisted'],
      ),
    ),
    ToolDefinition(
      name: 'miniapp.read',
      description:
          'Read the UI and logic definition of an installed user Mini App. Pass the user-facing name in app; an internal ID is also accepted. If the definition is too long (e.g. over 700 lines), read it in sliced chunks using startLine and endLine.',
      risk: 'safe',
      requiresConfirmation: false,
      isRetrieval: true,
      resultContextLimits: {'codeHtml': 12000},
      inputSchema: {
        'app': 'string (required, user-facing Mini App name or internal ID)',
        'startLine': 'integer (optional, 1-based start line to read a slice of the code)',
        'endLine': 'integer (optional, 1-based end line to read a slice of the code, inclusive)',
      },
    ),
    ToolDefinition(
      name: 'miniapp.patch',
      description:
          'Edit an installed Mini App after reading it. Prefer expectedRevision plus startLine/endLine for safe range replacement without echoing old code. targetContent remains available for small search-and-replace patches. Never use miniapp.create as an edit fallback.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'app': 'string (required, user-facing Mini App name or internal ID)',
        'startLine': 'integer (optional, 1-based start line of the search range)',
        'endLine': 'integer (optional, 1-based end line of the search range, inclusive)',
        'expectedRevision':
            'string (recommended, revision returned by miniapp.read; required when targetContent is omitted)',
        'targetContent':
            'string (optional, exact substring/lines to find; omit when replacing the explicit line range with expectedRevision)',
        'replacementContent': 'string (required, the new content)',
      },
      operation: 'update',
      targetEntity: 'miniapp',
      selectorArgs: ['app', 'id'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'miniapp',
        expectedDataKeys: ['id', 'patched', 'persisted'],
      ),
    ),
    ToolDefinition(
      name: 'miniapp.delete',
      description:
          'Delete an installed user Mini App permanently by user-facing name or internal ID.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {'app': 'string (required, user-facing Mini App name or internal ID)'},
      operation: 'delete',
      targetEntity: 'miniapp',
      selectorArgs: ['app', 'id'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'miniapp',
        expectedDataKeys: ['deleted'],
      ),
    ),
  ];

  @override
  Future<ToolExecutionResult> dispatch(ToolCallRequest request, ModuleToolContext ctx) async {
    try {
      final db = await MeowDatabase.instance.database;
      switch (request.name) {
        case 'miniapp.list':
          final rows = await db.query('miniapps', orderBy: 'created_at DESC');
          return ToolExecutionResult(
            success: true,
            toolName: request.name,
            data: {
              'apps': rows
                  .map(
                    (r) => {
                      'id': r['id'],
                      'name': r['name'],
                      'icon': r['icon'],
                      'createdAt': r['created_at'],
                    },
                  )
                  .toList(),
            },
          );

        case 'miniapp.read':
          final reference = _appReference(request.args);
          final lookup = await _resolveMiniApp(db, reference);
          if (!lookup.found) return lookup.failure(request.name);

          final row = lookup.row!;
          var codeHtml = (row['code_html'] ?? '').toString();

          final rawLines = codeHtml.split('\n');
          if (rawLines.length < 5) {
            codeHtml = _formatHtml(codeHtml);
            await db.update(
              'miniapps',
              {'code_html': codeHtml},
              where: 'id = ?',
              whereArgs: [row['id']],
            );
          }

          final startLineVal = request.args['startLine'];
          final endLineVal = request.args['endLine'];

          int? startLine;
          if (startLineVal != null) {
            startLine = int.tryParse(startLineVal.toString());
          }
          int? endLine;
          if (endLineVal != null) {
            endLine = int.tryParse(endLineVal.toString());
          }

          final lines = codeHtml.split('\n');
          final totalLines = lines.length;

          String resultHtml;
          int actualStart = 1;
          int actualEnd = totalLines;

          if (startLine != null || endLine != null) {
            actualStart = (startLine ?? 1).clamp(1, totalLines);
            actualEnd = (endLine ?? totalLines).clamp(actualStart, totalLines);

            final sliced = lines.sublist(actualStart - 1, actualEnd);
            resultHtml = sliced.join('\n');
          } else {
            resultHtml = codeHtml;
          }

          return ToolExecutionResult(
            success: true,
            toolName: request.name,
            data: {
              'id': row['id'],
              'name': row['name'],
              'icon': row['icon'],
              'createdAt': row['created_at'],
              'codeHtml': resultHtml,
              'revision': _revisionFor(codeHtml),
              'startLine': actualStart,
              'endLine': actualEnd,
              'totalLines': totalLines,
            },
          );

        case 'miniapp.create':
          final id = (request.args['id'] ?? '').toString().trim();
          final name = (request.args['name'] ?? '').toString().trim();
          final icon = request.args['icon']?.toString().trim();
          final codeHtml = (request.args['codeHtml'] ?? '').toString().trim();

          if (id.isEmpty || name.isEmpty || codeHtml.isEmpty) {
            return ToolExecutionResult(
              success: false,
              toolName: request.name,
              error: 'id, name, and codeHtml are required.',
            );
          }

          final installed = await db.query('miniapps', orderBy: 'created_at DESC');
          final existing = installed.where((row) {
            return row['id'].toString().toLowerCase() == id.toLowerCase() ||
                row['name'].toString().trim().toLowerCase() == name.toLowerCase();
          }).toList();
          if (existing.isNotEmpty) {
            final current = existing.first;
            return ToolExecutionResult(
              success: false,
              toolName: request.name,
              error:
                  'Mini App "${current['name']}" already exists. Existing Mini Apps must be edited with miniapp.patch.',
              data: {
                'id': current['id'],
                'name': current['name'],
                'existing': true,
                'requiredTool': 'miniapp.patch',
                'revision': _revisionFor((current['code_html'] ?? '').toString()),
              },
            );
          }

          final formattedCode = _formatHtml(codeHtml);

          final createdAt = DateTime.now().toIso8601String();
          await db.insert('miniapps', {
            'id': id,
            'name': name,
            'icon': icon,
            'code_html': formattedCode,
            'created_at': createdAt,
          }, conflictAlgorithm: ConflictAlgorithm.abort);

          final persisted = await db.query(
            'miniapps',
            where: 'id = ? AND name = ? AND code_html = ?',
            whereArgs: [id, name, formattedCode],
          );
          if (persisted.length != 1) {
            return ToolExecutionResult(
              success: false,
              toolName: request.name,
              error: 'Mini App save could not be verified.',
            );
          }

          return ToolExecutionResult(
            success: true,
            toolName: request.name,
            data: {
              'id': id,
              'name': name,
              'created': true,
              'persisted': true,
              'revision': _revisionFor(formattedCode),
            },
            actions: [
              ResultAction(
                label: 'Open Mini App',
                icon: 'widgets_outlined',
                type: 'navigate',
                target: '/miniapp/run/$id',
              ),
            ],
          );

        case 'miniapp.patch':
          final reference = _appReference(request.args);
          final startLineVal = request.args['startLine'];
          final endLineVal = request.args['endLine'];
          final expectedRevision = (request.args['expectedRevision'] ?? '')
              .toString()
              .trim();
          final targetContent = (request.args['targetContent'] ?? '').toString();
          final replacementContent = (request.args['replacementContent'] ?? '').toString();
          final hasTarget = targetContent.trim().isNotEmpty;

          if (!hasTarget &&
              (expectedRevision.isEmpty || startLineVal == null || endLineVal == null)) {
            return ToolExecutionResult(
              success: false,
              toolName: request.name,
              error:
                  'Provide targetContent, or provide expectedRevision with explicit startLine and endLine for safe range replacement.',
            );
          }

          final requestedStart = startLineVal == null
              ? null
              : int.tryParse(startLineVal.toString());
          final requestedEnd = endLineVal == null ? null : int.tryParse(endLineVal.toString());
          if ((startLineVal != null && requestedStart == null) ||
              (endLineVal != null && requestedEnd == null)) {
            return ToolExecutionResult(
              success: false,
              toolName: request.name,
              error: 'startLine and endLine must be valid integers when provided.',
            );
          }

          final lookup = await _resolveMiniApp(db, reference);
          if (!lookup.found) return lookup.failure(request.name);
          final row = lookup.row!;
          final id = row['id'].toString();
          final codeHtml = (row['code_html'] ?? '').toString();
          final currentRevision = _revisionFor(codeHtml);
          if (expectedRevision.isNotEmpty && expectedRevision != currentRevision) {
            return ToolExecutionResult(
              success: false,
              toolName: request.name,
              error:
                  'Mini App changed after it was read. Read the current range again before patching.',
              data: {
                'id': id,
                'name': row['name'],
                'staleRevision': true,
                'expectedRevision': expectedRevision,
                'currentRevision': currentRevision,
              },
            );
          }
          final lines = codeHtml.split('\n');
          final totalLines = lines.length;
          final startLine = requestedStart ?? 1;
          final endLine = requestedEnd ?? totalLines;

          if (startLine < 1 || endLine > totalLines || startLine > endLine) {
            return ToolExecutionResult(
              success: false,
              toolName: request.name,
              error:
                  'Line range [$startLine, $endLine] is out of bounds. '
                  'Total lines in the app is $totalLines.',
            );
          }

          final actualBlock = lines.sublist(startLine - 1, endLine).join('\n');
          late final String updatedBlock;
          if (hasTarget) {
            final normalizedTarget = _normalizeForPatch(targetContent);
            final normalizedActual = _normalizeForPatch(actualBlock);

            if (!normalizedActual.contains(normalizedTarget)) {
              return _buildPatchMismatchError(
                request.name,
                id,
                startLine,
                endLine,
                actualBlock,
                totalLines,
                currentRevision,
              );
            }

            final matchCount = _countOccurrences(normalizedActual, normalizedTarget);
            if (requestedStart == null && requestedEnd == null && matchCount > 1) {
              return ToolExecutionResult(
                success: false,
                toolName: request.name,
                error:
                    'targetContent matches $matchCount blocks. Provide startLine and endLine to select one.',
                data: {
                  'id': id,
                  'name': row['name'],
                  'matchCount': matchCount,
                  'currentRevision': currentRevision,
                },
              );
            }

            updatedBlock = _replaceNormalizedMatch(
              actualBlock,
              normalizedActual,
              normalizedTarget,
              replacementContent,
            );
          } else {
            updatedBlock = replacementContent;
          }

          final beforeLines = lines.sublist(0, startLine - 1);
          final afterLines = lines.sublist(endLine);
          final updatedCodeHtml = [...beforeLines, updatedBlock, ...afterLines].join('\n');

          if (updatedCodeHtml.trim().isEmpty) {
            return ToolExecutionResult(
              success: false,
              toolName: request.name,
              error: 'A patch cannot leave the Mini App definition empty.',
              data: {'id': id, 'name': row['name']},
            );
          }

          if (updatedCodeHtml == codeHtml) {
            return ToolExecutionResult(
              success: false,
              toolName: request.name,
              error: 'The requested patch would not change the Mini App.',
              data: {'id': id, 'name': row['name']},
            );
          }

          final updatedCount = await db.update(
            'miniapps',
            {'code_html': updatedCodeHtml},
            where: 'id = ?',
            whereArgs: [id],
          );
          final persisted = await db.query(
            'miniapps',
            columns: ['code_html'],
            where: 'id = ?',
            whereArgs: [id],
          );
          if (updatedCount != 1 ||
              persisted.length != 1 ||
              persisted.first['code_html'] != updatedCodeHtml) {
            return ToolExecutionResult(
              success: false,
              toolName: request.name,
              error: 'Mini App patch could not be verified.',
              data: {'id': id, 'name': row['name']},
            );
          }

          return ToolExecutionResult(
            success: true,
            toolName: request.name,
            data: {
              'id': id,
              'name': row['name'],
              'patched': true,
              'persisted': true,
              'previousRevision': currentRevision,
              'revision': _revisionFor(updatedCodeHtml),
              'startLine': startLine,
              'endLine': endLine,
            },
          );

        case 'miniapp.delete':
          final reference = _appReference(request.args);
          final lookup = await _resolveMiniApp(db, reference);
          if (!lookup.found) return lookup.failure(request.name);
          final row = lookup.row!;
          final id = row['id'].toString();

          final count = await db.delete('miniapps', where: 'id = ?', whereArgs: [id]);

          final remaining = await db.query(
            'miniapps',
            columns: ['id'],
            where: 'id = ?',
            whereArgs: [id],
          );
          if (count != 1 || remaining.isNotEmpty) {
            return ToolExecutionResult(
              success: false,
              toolName: request.name,
              error: 'Mini App deletion could not be verified.',
            );
          }

          return ToolExecutionResult(
            success: true,
            toolName: request.name,
            data: {'id': id, 'name': row['name'], 'deleted': true},
          );

        default:
          return ToolExecutionResult(
            success: false,
            toolName: request.name,
            error: 'Tool ${request.name} not implemented.',
          );
      }
    } catch (e) {
      return ToolExecutionResult(success: false, toolName: request.name, error: e.toString());
    }
  }

  String _appReference(Map<String, dynamic> args) {
    return (args['app'] ?? args['id'] ?? args['name'] ?? '').toString().trim();
  }

  Future<_MiniAppLookup> _resolveMiniApp(Database db, String reference) async {
    if (reference.isEmpty) {
      return _MiniAppLookup.missing('app is required.');
    }

    final rows = await db.query('miniapps', orderBy: 'created_at DESC');
    final lowerReference = reference.toLowerCase();

    final idMatches = rows
        .where((row) => row['id'].toString().toLowerCase() == lowerReference)
        .toList();
    if (idMatches.length == 1) return _MiniAppLookup.found(idMatches.single);

    final nameMatches = rows
        .where((row) => row['name'].toString().trim().toLowerCase() == lowerReference)
        .toList();
    if (nameMatches.length == 1) {
      return _MiniAppLookup.found(nameMatches.single);
    }
    if (nameMatches.length > 1) {
      return _MiniAppLookup.ambiguous(reference, nameMatches);
    }

    final canonicalReference = _canonicalAppReference(reference);
    final canonicalMatches = rows.where((row) {
      return _canonicalAppReference(row['id'].toString()) == canonicalReference ||
          _canonicalAppReference(row['name'].toString()) == canonicalReference;
    }).toList();
    if (canonicalMatches.length == 1) {
      return _MiniAppLookup.found(canonicalMatches.single);
    }
    if (canonicalMatches.length > 1) {
      return _MiniAppLookup.ambiguous(reference, canonicalMatches);
    }

    return _MiniAppLookup.notFound(reference, rows);
  }

  String _canonicalAppReference(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'[\s_-]+'), '');
  }

  // Format HTML for storage — idempotent for CSS/JS blocks.
  // Splits tags, expands CSS/JS braces into multi-line.
  String _formatHtml(String html) {
    var formatted = html.replaceAllMapped(RegExp(r'>\s*<'), (m) => '>\n<');

    final styleRegex = RegExp(r'(<style[^>]*>)([\s\S]*?)(</style>)', caseSensitive: false);
    formatted = formatted.replaceAllMapped(styleRegex, (match) {
      final openTag = match.group(1)!;
      final cssContent = match.group(2)!.trim();
      final closeTag = match.group(3)!;
      final formattedCss = cssContent
          .replaceAll(';', ';\n')
          .replaceAll('{', '{\n')
          .replaceAll('}', '\n}\n')
          .replaceAll(RegExp(r'\n\s*\n'), '\n')
          // Normalize CSS: no space around colons (consistency with normalization)
          .replaceAll(RegExp(r':\s+'), ':');
      return '$openTag\n$formattedCss\n$closeTag';
    });

    final scriptRegex = RegExp(r'(<script[^>]*>)([\s\S]*?)(</script>)', caseSensitive: false);
    formatted = formatted.replaceAllMapped(scriptRegex, (match) {
      final openTag = match.group(1)!;
      final jsContent = match.group(2)!.trim();
      final closeTag = match.group(3)!;
      final formattedJs = jsContent
          .replaceAll('{', '{\n')
          .replaceAll('}', '\n}\n')
          .replaceAll(RegExp(r'\n\s*\n'), '\n');
      return '$openTag\n$formattedJs\n$closeTag';
    });

    formatted = formatted.replaceAll(RegExp(r'\n\s*\n\s*\n'), '\n\n');
    return formatted.trim();
  }

  String _normalizeForPatch(String code) {
    return code.replaceAll(RegExp(r'\s+'), '');
  }

  String _revisionFor(String code) {
    var hash = 0xcbf29ce484222325;
    const prime = 0x100000001b3;
    const mask = 0xffffffffffffffff;
    for (final unit in code.codeUnits) {
      hash ^= unit;
      hash = (hash * prime) & mask;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  int _countOccurrences(String source, String target) {
    var count = 0;
    var offset = 0;
    while (offset <= source.length - target.length) {
      final match = source.indexOf(target, offset);
      if (match < 0) break;
      count++;
      offset = match + target.length;
    }
    return count;
  }

  // Map a whitespace-insensitive match back to raw offsets so code outside
  // the target block is preserved exactly.
  String _replaceNormalizedMatch(
    String rawBlock,
    String normalizedBlock,
    String normalizedTarget,
    String replacementContent,
  ) {
    final normMatchIdx = normalizedBlock.indexOf(normalizedTarget);
    if (normMatchIdx < 0) return rawBlock;

    final rawOffsets = <int>[];
    for (var index = 0; index < rawBlock.length; index++) {
      if (!RegExp(r'\s').hasMatch(rawBlock[index])) rawOffsets.add(index);
    }
    if (normMatchIdx + normalizedTarget.length > rawOffsets.length) {
      return rawBlock;
    }

    final rawStart = rawOffsets[normMatchIdx];
    final rawEnd = rawOffsets[normMatchIdx + normalizedTarget.length - 1] + 1;
    return rawBlock.replaceRange(rawStart, rawEnd, replacementContent);
  }

  ToolExecutionResult _buildPatchMismatchError(
    String toolName,
    String id,
    int startLine,
    int endLine,
    String actualBlock,
    int totalLines,
    String currentRevision,
  ) {
    final preview = actualBlock.length > 300
        ? '${actualBlock.substring(0, 300)}... (${actualBlock.length - 300} more chars)'
        : actualBlock;

    final hint = _extractSearchHint(actualBlock);

    return ToolExecutionResult(
      success: false,
      toolName: toolName,
      error:
          ''
          'targetContent not found in lines $startLine–$endLine.\n'
          '\n'
          'HINT: $hint\n'
          '\n'
          'ACTUAL CONTENT in range:\n'
          '$preview\n'
          '\n'
          'To retry safely, read the intended range and call miniapp.patch with its revision, startLine, endLine, and replacementContent.',
      data: {
        'id': id,
        'startLine': startLine,
        'endLine': endLine,
        'totalLines': totalLines,
        'currentRevision': currentRevision,
        'recommendedMode': 'revision_range',
        'hint': hint,
        'actualContentPreview': preview,
      },
    );
  }

  String _extractSearchHint(String actualBlock) {
    final cssMatch = RegExp(r'([.#]?[\w-]+)\s*\{').firstMatch(actualBlock);
    if (cssMatch != null) {
      return 'This block contains CSS rule: "${cssMatch.group(1)}". '
          'targetContent should include the full selector line.';
    }

    final funcMatch = RegExp(r'(?:function\s+)?(\w+)\s*\(').firstMatch(actualBlock);
    if (funcMatch != null) {
      return 'This block contains JS function: "${funcMatch.group(1)}()". '
          'targetContent should match the exact function body.';
    }

    final htmlMatch = RegExp(r'<(/?)(\w+)').firstMatch(actualBlock);
    if (htmlMatch != null) {
      return 'This block contains HTML tag: <${htmlMatch.group(2)}>. '
          'targetContent should include the full tag structure.';
    }

    final snippet = actualBlock.trim().substring(0, actualBlock.trim().length.clamp(0, 40));
    return 'Code starts with: "$snippet"';
  }
}

class _MiniAppLookup {
  const _MiniAppLookup._({this.row, this.error = '', this.available = const []});

  factory _MiniAppLookup.found(Map<String, Object?> row) {
    return _MiniAppLookup._(row: row);
  }

  factory _MiniAppLookup.missing(String error) {
    return _MiniAppLookup._(error: error);
  }

  factory _MiniAppLookup.ambiguous(String reference, List<Map<String, Object?>> rows) {
    return _MiniAppLookup._(
      error: 'More than one Mini App matches "$reference".',
      available: _summaries(rows),
    );
  }

  factory _MiniAppLookup.notFound(String reference, List<Map<String, Object?>> rows) {
    return _MiniAppLookup._(
      error: 'Mini App "$reference" was not found.',
      available: _summaries(rows),
    );
  }

  final Map<String, Object?>? row;
  final String error;
  final List<Map<String, Object?>> available;

  bool get found => row != null;

  ToolExecutionResult failure(String toolName) {
    return ToolExecutionResult(
      success: false,
      toolName: toolName,
      error: error,
      data: {'available': available},
    );
  }

  static List<Map<String, Object?>> _summaries(List<Map<String, Object?>> rows) {
    return rows.map((row) => <String, Object?>{'id': row['id'], 'name': row['name']}).toList();
  }
}
