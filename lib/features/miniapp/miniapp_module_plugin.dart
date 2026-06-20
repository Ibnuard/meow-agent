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
          'Create or update a custom local Mini App by saving its UI and logic definition.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'id': 'string (required, snake_case unique ID, e.g. expense_tracker)',
        'name': 'string (required, user-facing title, e.g. Expense Tracker)',
        'icon': 'string (optional, icon asset or character code)',
        'codeHtml': 'string (required, full UI and logic definition containing window.meow SDK integration)',
      },
      operation: 'create',
      targetEntity: 'miniapp',
      selectorArgs: ['id'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'miniapp',
        expectedDataKeys: ['id', 'created'],
      ),
    ),
    ToolDefinition(
      name: 'miniapp.read',
      description:
          'Read the UI and logic definition of an installed user Mini App by ID. If the definition is too long (e.g. over 700 lines), read it in sliced chunks (e.g. lines 1-700, then 701-1400) using startLine and endLine to avoid token limit overflow.',
      risk: 'safe',
      requiresConfirmation: false,
      isRetrieval: true,
      inputSchema: {
        'id': 'string (required, ID of the mini app to read)',
        'startLine': 'integer (optional, 1-based start line to read a slice of the code)',
        'endLine': 'integer (optional, 1-based end line to read a slice of the code, inclusive)',
      },
    ),
    ToolDefinition(
      name: 'miniapp.patch',
      description:
          'Edit a specific contiguous block of UI and logic definition for a Mini App by ID, similar to a file content replacement.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'id': 'string (required, ID of the mini app to edit)',
        'startLine': 'integer (required, 1-based start line of the block containing targetContent)',
        'endLine': 'integer (required, 1-based end line of the block containing targetContent)',
        'targetContent': 'string (required, the exact substring/lines to find and replace)',
        'replacementContent': 'string (required, the new content to replace the targetContent with)',
      },
      operation: 'update',
      targetEntity: 'miniapp',
      selectorArgs: ['id'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'miniapp',
        expectedDataKeys: ['id', 'patched'],
      ),
    ),
    ToolDefinition(
      name: 'miniapp.delete',
      description: 'Delete an installed user Mini App permanently by ID.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {
        'id': 'string (required, ID of the mini app to delete)',
      },
      operation: 'delete',
      targetEntity: 'miniapp',
      selectorArgs: ['id'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'miniapp',
        expectedDataKeys: ['deleted'],
      ),
    ),
  ];

  @override
  Future<ToolExecutionResult> dispatch(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) async {
    try {
      final db = await MeowDatabase.instance.database;
      switch (request.name) {
        case 'miniapp.list':
          final rows = await db.query('miniapps', orderBy: 'created_at DESC');
          return ToolExecutionResult(
            success: true,
            toolName: request.name,
            data: {
              'apps': rows.map((r) => {
                'id': r['id'],
                'name': r['name'],
                'icon': r['icon'],
                'createdAt': r['created_at'],
              }).toList(),
            },
          );

        case 'miniapp.read':
          final id = (request.args['id'] ?? '').toString().trim();
          if (id.isEmpty) {
            return ToolExecutionResult(
              success: false,
              toolName: request.name,
              error: 'id is required.',
            );
          }

          final rows = await db.query(
            'miniapps',
            where: 'id = ?',
            whereArgs: [id],
          );

          if (rows.isEmpty) {
            return ToolExecutionResult(
              success: false,
              toolName: request.name,
              error: 'Mini App with ID "$id" not found.',
            );
          }

          final row = rows.first;
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

          final formattedCode = _formatHtml(codeHtml);

          await db.insert(
            'miniapps',
            {
              'id': id,
              'name': name,
              'icon': icon,
              'code_html': formattedCode,
              'created_at': DateTime.now().toIso8601String(),
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );

          return ToolExecutionResult(
            success: true,
            toolName: request.name,
            data: {
              'id': id,
              'created': true,
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
          final id = (request.args['id'] ?? '').toString().trim();
          final startLineVal = request.args['startLine'];
          final endLineVal = request.args['endLine'];
          final targetContent = (request.args['targetContent'] ?? '').toString();
          final replacementContent = (request.args['replacementContent'] ?? '').toString();

          if (id.isEmpty) {
            return ToolExecutionResult(
              success: false,
              toolName: request.name,
              error: 'id is required.',
            );
          }

          int? startLine;
          if (startLineVal != null) {
            startLine = int.tryParse(startLineVal.toString());
          }
          int? endLine;
          if (endLineVal != null) {
            endLine = int.tryParse(endLineVal.toString());
          }

          if (startLine == null || endLine == null) {
            return ToolExecutionResult(
              success: false,
              toolName: request.name,
              error: 'startLine and endLine must be valid integers.',
            );
          }

          final rows = await db.query(
            'miniapps',
            columns: ['code_html'],
            where: 'id = ?',
            whereArgs: [id],
          );

          if (rows.isEmpty) {
            return ToolExecutionResult(
              success: false,
              toolName: request.name,
              error: 'Mini App with ID "$id" not found.',
            );
          }

          final codeHtml = (rows.first['code_html'] ?? '').toString();
          final lines = codeHtml.split('\n');
          final totalLines = lines.length;

          if (startLine < 1 || endLine > totalLines || startLine > endLine) {
            return ToolExecutionResult(
              success: false,
              toolName: request.name,
              error: 'Line range [$startLine, $endLine] is out of bounds. '
                     'Total lines in the app is $totalLines.',
            );
          }

          final actualBlock = lines.sublist(startLine - 1, endLine).join('\n');
          if (!actualBlock.contains(targetContent)) {
            return ToolExecutionResult(
              success: false,
              toolName: request.name,
              error: 'The targetContent was not found in lines $startLine to $endLine. '
                     'Actual content in that range is:\n$actualBlock',
            );
          }

          final updatedBlock = actualBlock.replaceFirst(targetContent, replacementContent);
          final beforeLines = lines.sublist(0, startLine - 1);
          final afterLines = lines.sublist(endLine);
          final updatedCodeHtml = [...beforeLines, updatedBlock, ...afterLines].join('\n');
          final formattedUpdatedCode = _formatHtml(updatedCodeHtml);

          await db.update(
            'miniapps',
            {'code_html': formattedUpdatedCode},
            where: 'id = ?',
            whereArgs: [id],
          );

          return ToolExecutionResult(
            success: true,
            toolName: request.name,
            data: {
              'id': id,
              'patched': true,
            },
          );

        case 'miniapp.delete':
          final id = (request.args['id'] ?? '').toString().trim();
          if (id.isEmpty) {
            return ToolExecutionResult(
              success: false,
              toolName: request.name,
              error: 'id is required.',
            );
          }

          final count = await db.delete(
            'miniapps',
            where: 'id = ?',
            whereArgs: [id],
          );

          if (count == 0) {
            return ToolExecutionResult(
              success: false,
              toolName: request.name,
              error: 'Mini App with ID "$id" not found.',
            );
          }

          return ToolExecutionResult(
            success: true,
            toolName: request.name,
            data: {
              'id': id,
              'deleted': true,
            },
          );

        default:
          return ToolExecutionResult(
            success: false,
            toolName: request.name,
            error: 'Tool ${request.name} not implemented.',
          );
      }
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: e.toString(),
      );
    }
  }

  String _formatHtml(String html) {
    // 1. Format HTML tag boundaries
    var formatted = html.replaceAllMapped(RegExp(r'>\s*<'), (m) => '>\n<');

    // 2. Format CSS inside <style> tags
    final styleRegex = RegExp(r'(<style[^>]*>)([\s\S]*?)(</style>)', caseSensitive: false);
    formatted = formatted.replaceAllMapped(styleRegex, (match) {
      final openTag = match.group(1)!;
      final cssContent = match.group(2)!;
      final closeTag = match.group(3)!;
      
      final formattedCss = cssContent
          .replaceAll(';', ';\n')
          .replaceAll('{', '{\n')
          .replaceAll('}', '\n}\n')
          .replaceAll(RegExp(r'\n\s*\n'), '\n');
      
      return '$openTag\n$formattedCss\n$closeTag';
    });

    // 3. Format JS inside <script> tags safely (mostly by braces)
    final scriptRegex = RegExp(r'(<script[^>]*>)([\s\S]*?)(</script>)', caseSensitive: false);
    formatted = formatted.replaceAllMapped(scriptRegex, (match) {
      final openTag = match.group(1)!;
      final jsContent = match.group(2)!;
      final closeTag = match.group(3)!;
      
      final formattedJs = jsContent
          .replaceAll('{', '{\n')
          .replaceAll('}', '\n}\n')
          .replaceAll(RegExp(r'\n\s*\n'), '\n');
          
      return '$openTag\n$formattedJs\n$closeTag';
    });

    // 4. Remove excessive newlines
    formatted = formatted.replaceAll(RegExp(r'\n\s*\n\s*\n'), '\n\n');
    
    return formatted.trim();
  }
}
