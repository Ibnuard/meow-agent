import '../../../services/agent_runtime/module_plugin.dart';
import '../../../services/agent_runtime/runtime_models.dart';
import 'notes_tools.dart';

/// Notes module: create/read/search/update/delete + pin/archive/append/export.
///
/// Self-registers its tool surface so the runtime derives the registry,
/// dispatch, and catalog group from here — no edits to tool_router.dart or
/// tool_catalog.dart when notes tools change.
class NotesModulePlugin extends ModulePlugin {
  const NotesModulePlugin();

  @override
  String get moduleId => 'notes';

  @override
  String get catalogGroup => 'notes';

  @override
  List<String> get capabilityHints => const [
    'note',
    'notes',
    'memo',
    'jot',
    'write down',
  ];

  @override
  List<ToolDefinition> get toolDefinitions => const [
    ToolDefinition(
      name: 'notes.create',
      description:
          'Create a markdown note with a title and optional content/tags.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'title': 'string (required)',
        'content': 'string (markdown body)',
        'tags': 'list<string> (optional)',
        'source': 'string (optional, default runtime)',
      },
      operation: 'create',
      targetEntity: 'note',
      selectorArgs: ['title'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'note',
        expectedDataKeys: ['noteId'],
      ),
    ),
    ToolDefinition(
      name: 'notes.list_recent',
      description: 'List recent notes sorted by last updated.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'limit': 'int (optional, default 10)'},
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'notes.read',
      description: 'Read a note by ID. Returns full markdown content.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'noteId': 'string (required)'},
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'notes.search',
      description: 'Search notes by keyword in title, content, and tags.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'query': 'string (required)'},
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'notes.update',
      description:
          'Update an existing note. Requires confirmation before overwriting.',
      risk: 'sensitive-lite',
      requiresConfirmation: true,
      inputSchema: {
        'noteId': 'string (required)',
        'title': 'string (optional)',
        'content': 'string (optional)',
        'tags': 'list<string> (optional)',
      },
      operation: 'update',
      targetEntity: 'note',
      selectorArgs: ['noteId'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'note',
        expectedDataKeys: ['updated'],
      ),
    ),
    ToolDefinition(
      name: 'notes.delete',
      description: 'Delete a note permanently. Requires confirmation.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {'noteId': 'string (required)'},
      operation: 'delete',
      targetEntity: 'note',
      selectorArgs: ['noteId'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'note',
        expectedDataKeys: ['deleted'],
      ),
    ),
    ToolDefinition(
      name: 'notes.export',
      description:
          'Export notes as markdown files to the agent workspace notes/ folder. Pass empty noteIds to export all.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'agentName': 'string (required)',
        'noteIds': 'list<string> (optional, empty = all)',
      },
    ),
    ToolDefinition(
      name: 'notes.pin',
      description:
          'Pin a note so it stays at the top of the list. Reversible via notes.unpin.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {'noteId': 'string (required)'},
      operation: 'update',
      targetEntity: 'note',
      selectorArgs: ['noteId'],
    ),
    ToolDefinition(
      name: 'notes.unpin',
      description: 'Remove pinned status from a note.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {'noteId': 'string (required)'},
      operation: 'update',
      targetEntity: 'note',
      selectorArgs: ['noteId'],
    ),
    ToolDefinition(
      name: 'notes.archive',
      description:
          'Archive a note (hidden from main list but kept). Use when user wants to declutter without deleting. Reversible via notes.unarchive.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {'noteId': 'string (required)'},
      operation: 'update',
      targetEntity: 'note',
      selectorArgs: ['noteId'],
    ),
    ToolDefinition(
      name: 'notes.unarchive',
      description: 'Restore an archived note back to the main list.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {'noteId': 'string (required)'},
      operation: 'update',
      targetEntity: 'note',
      selectorArgs: ['noteId'],
    ),
    ToolDefinition(
      name: 'notes.append',
      description:
          'Append content to an existing note (additive, non-destructive). Useful for daily journals, running logs, accumulating ideas.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {
        'noteId': 'string (required)',
        'content': 'string (required, markdown body to append)',
        'separator': 'string (optional, default = double newline)',
      },
      operation: 'update',
      targetEntity: 'note',
      selectorArgs: ['noteId'],
    ),
  ];

  @override
  Future<ToolExecutionResult> dispatch(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) {
    final tools = NotesTools(moduleRepository: ctx.moduleRepository);
    switch (request.name) {
      case 'notes.create':
        return tools.executeCreate(request.args);
      case 'notes.list_recent':
        return tools.executeListRecent(request.args);
      case 'notes.read':
        return tools.executeRead(request.args);
      case 'notes.search':
        return tools.executeSearch(request.args);
      case 'notes.update':
        return tools.executeUpdate(request.args);
      case 'notes.delete':
        return tools.executeDelete(request.args);
      case 'notes.export':
        return tools.executeExport(request.args);
      case 'notes.pin':
        return tools.executeSetPinned(request.args, pinned: true);
      case 'notes.unpin':
        return tools.executeSetPinned(request.args, pinned: false);
      case 'notes.archive':
        return tools.executeSetArchived(request.args, archived: true);
      case 'notes.unarchive':
        return tools.executeSetArchived(request.args, archived: false);
      case 'notes.append':
        return tools.executeAppend(request.args);
      default:
        return Future.value(
          ToolExecutionResult(
            success: false,
            toolName: request.name,
            error: 'NotesModulePlugin cannot handle ${request.name}',
          ),
        );
    }
  }
}
