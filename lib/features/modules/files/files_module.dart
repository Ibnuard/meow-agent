import '../../../services/agent_runtime/module_plugin.dart';
import '../../../services/agent_runtime/runtime_models.dart';
import 'files_tools.dart';

/// Files module: workspace-sandboxed file CRUD + search/tree.
///
/// Self-registers its tool surface; the runtime derives registry, dispatch,
/// and catalog group from here.
class FilesModulePlugin extends ModulePlugin {
  const FilesModulePlugin();

  @override
  String get moduleId => 'files';

  @override
  String get catalogGroup => 'files';

  @override
  List<String> get capabilityHints => const [
    'file',
    'files',
    'folder',
    'directory',
    'workspace',
    'document',
  ];

  @override
  List<ToolDefinition> get toolDefinitions => const [
    ToolDefinition(
      name: 'files.create',
      description:
          'Create a new file under the MeowAgent workspace root. Defaults to the calling agent. To target a peer agent use "Agents/<Name>/<rel>" — the runtime will require user confirmation. Fails if file already exists.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'path':
            'string (required, relative to own workspace OR "Agents/<Name>/..." for a peer)',
        'content': 'string (optional, file content)',
      },
      operation: 'create',
      targetEntity: 'file',
      selectorArgs: ['path'],
      postconditions: {'file_present': 'path'},
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'file',
        expectedDataKeys: ['path'],
      ),
    ),
    ToolDefinition(
      name: 'files.read',
      description:
          'Read a file under the MeowAgent workspace root. Use "Agents/<Name>/<rel>" to read a peer agent file (e.g. "Agents/Penulis/notes.md"); the runtime will require confirmation for cross-agent reads.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'path':
            'string (required, relative to own workspace OR "Agents/<Name>/..." for a peer)',
      },
      operation: 'read',
      targetEntity: 'file',
      selectorArgs: ['path'],
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'files.write',
      description:
          'Write or overwrite content to a file under the MeowAgent workspace root. Cross-agent writes (e.g. "Agents/<Name>/notes.md") require user confirmation — use this for sharing user files between peer agents. NOT for identity/persona — use system.profile.update instead.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'path':
            'string (required, relative to own workspace OR "Agents/<Name>/..." for a peer)',
        'content': 'string (required)',
        'append': 'bool (optional, default false)',
      },
      operation: 'update',
      targetEntity: 'file',
      selectorArgs: ['path'],
      postconditions: {'file_present': 'path'},
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'file',
        expectedDataKeys: ['path'],
      ),
    ),
    ToolDefinition(
      name: 'files.delete',
      description:
          'Delete a file or directory under the MeowAgent workspace root. Always requires confirmation — cross-agent paths are also surfaced for explicit user approval.',
      risk: 'sensitive',
      requiresConfirmation: true,
      inputSchema: {
        'path':
            'string (required, relative to own workspace OR "Agents/<Name>/..." for a peer)',
      },
      operation: 'delete',
      targetEntity: 'file',
      selectorArgs: ['path'],
      postconditions: {'file_absent': 'path'},
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'file',
        expectedDataKeys: ['deleted'],
      ),
    ),
    ToolDefinition(
      name: 'files.list',
      description:
          'List files and directories under the MeowAgent workspace root. Empty path = own workspace root. Use "Agents" to enumerate peer agents, or "Agents/<Name>" for a peer’s root — cross-agent reads ask for confirmation.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'path':
            'string (optional; empty = own root, "Agents/<Name>" for a peer)',
      },
      operation: 'list',
      targetEntity: 'file',
      selectorArgs: ['path'],
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'files.move',
      description:
          'Move or rename a file/directory under the MeowAgent workspace root. Cross-agent moves (using "Agents/<Name>/..." on either side) require confirmation.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'from': 'string (required, relative or "Agents/<Name>/...")',
        'to': 'string (required, relative or "Agents/<Name>/...")',
      },
      operation: 'rename',
      targetEntity: 'file',
      selectorArgs: ['from', 'to'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'file',
        expectedDataKeys: ['to'],
      ),
    ),
    ToolDefinition(
      name: 'files.mkdir',
      description:
          'Create a directory under the MeowAgent workspace root. Cross-agent creation ("Agents/<Name>/...") requires confirmation.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'path':
            'string (required, relative to own workspace OR "Agents/<Name>/..." for a peer)',
      },
      operation: 'create',
      targetEntity: 'file',
      selectorArgs: ['path'],
      postconditions: {'directory_present': 'path'},
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'file',
        expectedDataKeys: ['path'],
      ),
    ),
    ToolDefinition(
      name: 'files.copy',
      description:
          'Copy a file or directory within the workspace. Source remains intact.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {
        'from': 'string (required, source path)',
        'to': 'string (required, destination path)',
      },
      operation: 'create',
      targetEntity: 'file',
      selectorArgs: ['to'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'file',
        expectedDataKeys: ['copied', 'to', 'persisted'],
      ),
    ),
    ToolDefinition(
      name: 'files.append',
      description:
          'Append content to an existing file (additive, non-destructive). Auto-creates the file with the appended content if it does not exist. Inserts a newline before content if file does not end with one.',
      risk: 'sensitive-lite',
      requiresConfirmation: false,
      inputSchema: {
        'path': 'string (required)',
        'content': 'string (required, text to append)',
      },
      operation: 'update',
      targetEntity: 'file',
      selectorArgs: ['path'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'file',
        expectedDataKeys: ['path', 'size', 'stateVerified'],
      ),
    ),
    ToolDefinition(
      name: 'files.metadata',
      description:
          'Get file metadata: size, modified time, mime type, line count for small text files. Read-only, no content returned.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'path': 'string (required)'},
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'files.search',
      description:
          'Search files by name pattern (glob: * and ?) and/or content keyword inside the agent workspace. Returns paths with content snippets. OMIT "root" to search the current agent\'s own workspace (this is what users normally mean). Only set "root" when user explicitly references a peer agent (e.g. "Agents/<Name>").',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'query': 'string (optional, content keyword; case-insensitive)',
        'namePattern':
            'string (optional, glob filename pattern e.g. *.md or report-*.txt)',
        'root':
            'string (optional, OMIT for own workspace. Only use "Agents/<Name>" for peer agents)',
        'maxResults': 'int (optional, 1-200, default 50)',
      },
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'files.tree',
      description:
          'Render a workspace directory as ASCII tree (1-8 depth). Useful for giving the user/LLM a structural overview without listing every file. OMIT "root" to render the current agent\'s own workspace (this is what users normally mean by "struktur folder agen ini" / "workspace structure"). Only set "root" when user explicitly references a peer agent (e.g. "Agents/<Name>"). Do NOT pass absolute paths from system.self output.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'root':
            'string (optional, OMIT for own workspace. Only use "Agents/<Name>" for peer agents)',
        'maxDepth': 'int (optional, 1-8, default 3)',
      },
      isRetrieval: true,
    ),
  ];

  @override
  Future<ToolExecutionResult> dispatch(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) {
    final tools = FilesTools(
      agentName: ctx.agentName,
      moduleRepository: ctx.moduleRepository,
    );
    switch (request.name) {
      case 'files.create':
        return tools.executeCreate(request.args);
      case 'files.read':
        return tools.executeRead(request.args);
      case 'files.write':
        return tools.executeWrite(request.args);
      case 'files.delete':
        return tools.executeDelete(request.args);
      case 'files.list':
        return tools.executeList(request.args);
      case 'files.move':
        return tools.executeMove(request.args);
      case 'files.mkdir':
        return tools.executeMkdir(request.args);
      case 'files.copy':
        return tools.executeCopy(request.args);
      case 'files.append':
        return tools.executeAppend(request.args);
      case 'files.metadata':
        return tools.executeMetadata(request.args);
      case 'files.search':
        return tools.executeSearch(request.args);
      case 'files.tree':
        return tools.executeTree(request.args);
      default:
        return Future.value(
          ToolExecutionResult(
            success: false,
            toolName: request.name,
            error: 'FilesModulePlugin cannot handle ${request.name}',
          ),
        );
    }
  }
}
