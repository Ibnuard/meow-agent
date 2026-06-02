import 'dart:convert';
import 'dart:io';

import '../../../services/agent_runtime/module_plugin.dart';
import '../../../services/agent_runtime/runtime_models.dart';

class AttachmentModulePlugin extends ModulePlugin {
  const AttachmentModulePlugin();

  static const int _maxReadBytes = 128 * 1024;

  @override
  String get moduleId => 'attachments';

  @override
  String get catalogGroup => 'attachment';

  @override
  List<String> get capabilityHints => const [
    'attached file',
    'attachment',
    'upload',
    'read uploaded text',
    'inspect attached image',
  ];

  @override
  List<ToolDefinition> get toolDefinitions => const [
    ToolDefinition(
      name: 'attachment.list',
      description:
          'List files attached to the current user message with type, size, and readability metadata. Does not read file contents.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {},
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'attachment.read_text',
      description:
          'Read the text content of one attached file from the current user message. Only works for text-like attachments, never arbitrary paths.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'index': 'number (optional, zero-based attachment index)',
        'name': 'string (optional, attached file name)',
      },
      isRetrieval: true,
    ),
    ToolDefinition(
      name: 'attachment.describe_image',
      description:
          'Describe or answer questions about one attached image from the current user message.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {
        'index': 'number (optional, zero-based attachment index)',
        'name': 'string (optional, attached file name)',
        'prompt': 'string (optional, question to answer about the image)',
      },
      isRetrieval: true,
    ),
  ];

  @override
  Future<ToolExecutionResult> dispatch(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) async {
    switch (request.name) {
      case 'attachment.list':
        return _list(request.name, ctx.attachments, ctx.modelSupportsVision);
      case 'attachment.read_text':
        return _readText(request, ctx.attachments, ctx.modelSupportsVision);
      case 'attachment.describe_image':
        return _describeImage(request, ctx);
      default:
        return ToolExecutionResult(
          success: false,
          toolName: request.name,
          error: 'Unsupported attachment tool: ${request.name}',
        );
    }
  }

  ToolExecutionResult _list(
    String toolName,
    List<AttachedFile> attachments,
    bool modelSupportsVision,
  ) {
    return ToolExecutionResult(
      success: true,
      toolName: toolName,
      data: {
        'count': attachments.length,
        'attachments': [
          for (var i = 0; i < attachments.length; i++)
            _metadata(i, attachments[i], modelSupportsVision),
        ],
        'visionSupported': modelSupportsVision,
      },
    );
  }

  Future<ToolExecutionResult> _readText(
    ToolCallRequest request,
    List<AttachedFile> attachments,
    bool modelSupportsVision,
  ) async {
    final selected = _selectAttachment(request.args, attachments);
    if (selected.error != null) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: selected.error,
        data: {'available': _available(attachments)},
      );
    }

    final attachment = selected.attachment!;
    final index = selected.index!;
    final kind = _kindFor(attachment.name);
    if (kind == 'image') {
      final message = modelSupportsVision
          ? 'The selected attachment is an image and the active model declares vision support. Image handoff is not implemented in this text reader tool.'
          : 'The selected attachment is an image, but the active model does not support vision. Switch this agent to a vision-capable model and try again.';
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: message,
        data: {
          ..._metadata(index, attachment, modelSupportsVision),
          'errorCode': modelSupportsVision
              ? 'attachment_image_reader_not_applicable'
              : 'vision_model_unsupported',
          if (!modelSupportsVision) ...{
            'failureKind': 'capability_boundary',
            'messageKey': 'runtime_vision_model_unsupported',
          },
          'visionRequired': true,
          'visionSupported': modelSupportsVision,
        },
      );
    }

    if (!_isTextLike(attachment.name)) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'The selected attachment is not a supported text file.',
        data: _metadata(index, attachment, modelSupportsVision),
      );
    }

    try {
      final file = File(attachment.path);
      if (!await file.exists()) {
        return ToolExecutionResult(
          success: false,
          toolName: request.name,
          error: 'The attached file is no longer available on this device.',
          data: _metadata(index, attachment, modelSupportsVision),
        );
      }

      final bytes = await file
          .openRead(0, _maxReadBytes + 1)
          .fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
      final truncated = bytes.length > _maxReadBytes;
      final contentBytes = truncated ? bytes.sublist(0, _maxReadBytes) : bytes;
      final content = utf8.decode(contentBytes, allowMalformed: false);
      return ToolExecutionResult(
        success: true,
        toolName: request.name,
        data: {
          ..._metadata(index, attachment, modelSupportsVision),
          'content': content,
          'truncated': truncated,
          'readBytes': contentBytes.length,
          'maxReadBytes': _maxReadBytes,
        },
      );
    } on FormatException {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'The selected attachment is not valid UTF-8 text.',
        data: _metadata(index, attachment, modelSupportsVision),
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'Failed to read the attached file: $e',
        data: _metadata(index, attachment, modelSupportsVision),
      );
    }
  }

  Future<ToolExecutionResult> _describeImage(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) async {
    final selected = _selectAttachment(request.args, ctx.attachments);
    if (selected.error != null) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: selected.error,
        data: {'available': _available(ctx.attachments)},
      );
    }

    final attachment = selected.attachment!;
    final index = selected.index!;
    if (_kindFor(attachment.name) != 'image') {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'The selected attachment is not an image.',
        data: _metadata(index, attachment, ctx.modelSupportsVision),
      );
    }

    if (!ctx.modelSupportsVision) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error:
            'The active model does not support image input. Switch this agent to a vision-capable model and try again.',
        data: {
          ..._metadata(index, attachment, ctx.modelSupportsVision),
          'errorCode': 'vision_model_unsupported',
          'failureKind': 'capability_boundary',
          'messageKey': 'runtime_vision_model_unsupported',
          'visionRequired': true,
          'visionSupported': false,
        },
      );
    }

    final describeImage = ctx.describeImage;
    if (describeImage == null) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'Image input is not available in this runtime session.',
        data: _metadata(index, attachment, ctx.modelSupportsVision),
      );
    }

    try {
      final prompt = (request.args['prompt'] as String?)?.trim();
      final description = await describeImage(
        image: attachment,
        prompt: prompt?.isNotEmpty == true ? prompt! : ctx.currentUserMessage,
      );
      return ToolExecutionResult(
        success: true,
        toolName: request.name,
        data: {
          ..._metadata(index, attachment, ctx.modelSupportsVision),
          'description': description,
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: request.name,
        error: 'Failed to process the attached image: $e',
        data: _metadata(index, attachment, ctx.modelSupportsVision),
      );
    }
  }

  ({AttachedFile? attachment, int? index, String? error}) _selectAttachment(
    Map<String, dynamic> args,
    List<AttachedFile> attachments,
  ) {
    if (attachments.isEmpty) {
      return (
        attachment: null,
        index: null,
        error: 'No files are attached to this message.',
      );
    }

    final rawIndex = args['index'];
    if (rawIndex is num) {
      final index = rawIndex.toInt();
      if (index >= 0 && index < attachments.length) {
        return (attachment: attachments[index], index: index, error: null);
      }
      return (
        attachment: null,
        index: null,
        error: 'Attachment index is out of range.',
      );
    }

    final rawName = args['name'];
    if (rawName is String && rawName.trim().isNotEmpty) {
      final wanted = rawName.trim().toLowerCase();
      final matches = <int>[];
      for (var i = 0; i < attachments.length; i++) {
        if (attachments[i].name.toLowerCase() == wanted) matches.add(i);
      }
      if (matches.length == 1) {
        final index = matches.first;
        return (attachment: attachments[index], index: index, error: null);
      }
      if (matches.length > 1) {
        return (
          attachment: null,
          index: null,
          error:
              'More than one attachment has that name. Use the attachment index.',
        );
      }
      if (attachments.length == 1) {
        return (attachment: attachments.first, index: 0, error: null);
      }
      return (
        attachment: null,
        index: null,
        error: 'No attached file matches that name.',
      );
    }

    if (attachments.length == 1) {
      return (attachment: attachments.first, index: 0, error: null);
    }

    return (
      attachment: null,
      index: null,
      error:
          'Multiple files are attached. Use attachment.list, then read by index or name.',
    );
  }

  List<Map<String, dynamic>> _available(List<AttachedFile> attachments) => [
    for (var i = 0; i < attachments.length; i++) _metadata(i, attachments[i]),
  ];

  Map<String, dynamic> _metadata(
    int index,
    AttachedFile attachment, [
    bool modelSupportsVision = false,
  ]) {
    final kind = _kindFor(attachment.name);
    return {
      'index': index,
      'name': attachment.name,
      'sizeBytes': attachment.sizeBytes,
      'extension': _extensionOf(attachment.name),
      'kind': kind,
      'readableAsText': _isTextLike(attachment.name),
      'visionRequired': kind == 'image',
      'visionSupported': kind == 'image' && modelSupportsVision,
    };
  }

  static String _extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return '';
    return name.substring(dot).toLowerCase();
  }

  static String _kindFor(String name) {
    final ext = _extensionOf(name);
    if (_imageExtensions.contains(ext)) return 'image';
    if (_isTextLike(name)) return 'text';
    return 'binary';
  }

  static bool _isTextLike(String name) =>
      _textExtensions.contains(_extensionOf(name));

  static const Set<String> _imageExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.webp',
    '.gif',
    '.bmp',
    '.heic',
  };

  static const Set<String> _textExtensions = {
    '.txt',
    '.md',
    '.markdown',
    '.json',
    '.jsonl',
    '.csv',
    '.tsv',
    '.log',
    '.xml',
    '.yaml',
    '.yml',
    '.toml',
    '.ini',
    '.cfg',
    '.env',
    '.dart',
    '.py',
    '.js',
    '.ts',
    '.tsx',
    '.jsx',
    '.html',
    '.css',
    '.java',
    '.kt',
    '.swift',
    '.go',
    '.rs',
    '.c',
    '.cpp',
    '.h',
    '.hpp',
    '.cs',
    '.php',
    '.rb',
    '.sh',
    '.ps1',
    '.sql',
  };
}
