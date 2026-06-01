import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meow_agent/features/modules/attachments/attachment_module.dart';
import 'package:meow_agent/features/modules/data/module_repository.dart';
import 'package:meow_agent/services/agent_runtime/module_plugin.dart';
import 'package:meow_agent/services/agent_runtime/runtime_models.dart';

void main() {
  const plugin = AttachmentModulePlugin();

  ModuleToolContext contextWith(List<AttachedFile> attachments) =>
      ModuleToolContext(
        agentName: 'Agent',
        agentId: 'agent-1',
        moduleRepository: ModuleRepository(),
        attachments: attachments,
      );

  test('lists attachment metadata without contents', () async {
    final result = await plugin.dispatch(
      const ToolCallRequest(
        name: 'attachment.list',
        risk: 'safe',
        requiresConfirmation: false,
      ),
      contextWith(const [
        AttachedFile(path: 'ignored.txt', name: 'notes.md', sizeBytes: 12),
      ]),
    );

    expect(result.success, isTrue);
    expect(result.data?['count'], 1);
    final attachments = result.data?['attachments'] as List;
    expect(attachments.first['name'], 'notes.md');
    expect(attachments.first['readableAsText'], isTrue);
    expect(attachments.first.containsKey('content'), isFalse);
  });

  test('reads only text from an attached file', () async {
    final file = File('${Directory.systemTemp.path}/meow_attachment_test.txt');
    await file.writeAsString('hello attachment');
    addTearDown(() async {
      if (await file.exists()) await file.delete();
    });

    final result = await plugin.dispatch(
      const ToolCallRequest(
        name: 'attachment.read_text',
        args: {'index': 0},
        risk: 'safe',
        requiresConfirmation: false,
      ),
      contextWith([
        AttachedFile(path: file.path, name: 'sample.txt', sizeBytes: 16),
      ]),
    );

    expect(result.success, isTrue);
    expect(result.data?['content'], 'hello attachment');
    expect(result.data?['truncated'], isFalse);
  });

  test('does not pretend image vision is available', () async {
    final result = await plugin.dispatch(
      const ToolCallRequest(
        name: 'attachment.read_text',
        args: {'index': 0},
        risk: 'safe',
        requiresConfirmation: false,
      ),
      contextWith(const [
        AttachedFile(path: 'image.png', name: 'image.png', sizeBytes: 42),
      ]),
    );

    expect(result.success, isFalse);
    expect(result.data?['visionRequired'], isTrue);
    expect(result.data?['visionSupported'], isFalse);
  });
}
