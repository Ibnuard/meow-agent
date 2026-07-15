import 'dart:io';

import 'package:dio/dio.dart';
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
    expect(result.data?['errorCode'], 'vision_model_unsupported');
    expect(result.data?['failureKind'], 'capability_boundary');
    expect(result.data?['messageKey'], 'runtime_vision_model_unsupported');
    expect(result.data?['visionRequired'], isTrue);
    expect(result.data?['visionSupported'], isFalse);
  });

  test('reports image vision support from the active model metadata', () async {
    final result = await plugin.dispatch(
      const ToolCallRequest(
        name: 'attachment.list',
        risk: 'safe',
        requiresConfirmation: false,
      ),
      ModuleToolContext(
        agentName: 'Agent',
        agentId: 'agent-1',
        moduleRepository: ModuleRepository(),
        attachments: const [
          AttachedFile(path: 'image.png', name: 'image.png', sizeBytes: 42),
        ],
        modelSupportsVision: true,
      ),
    );

    final attachments = result.data?['attachments'] as List;
    expect(result.data?['visionSupported'], isTrue);
    expect(attachments.first['visionRequired'], isTrue);
    expect(attachments.first['visionSupported'], isTrue);
  });

  test('describes image when model metadata supports vision', () async {
    final result = await plugin.dispatch(
      const ToolCallRequest(
        name: 'attachment.describe_image',
        args: {'index': 0, 'prompt': 'What is in this image?'},
        risk: 'safe',
        requiresConfirmation: false,
      ),
      ModuleToolContext(
        agentName: 'Agent',
        agentId: 'agent-1',
        moduleRepository: ModuleRepository(),
        attachments: const [
          AttachedFile(path: 'image.png', name: 'image.png', sizeBytes: 42),
        ],
        modelSupportsVision: true,
        describeImage: _fakeDescribeImage,
      ),
    );

    expect(result.success, isTrue);
    expect(result.data?['description'], 'vision answer');
  });

  test('maps provider 404 from image vision to capability boundary', () async {
    final result = await plugin.dispatch(
      ToolCallRequest(
        name: 'attachment.describe_image',
        args: const {'index': 0, 'prompt': 'What is in this image?'},
        risk: 'safe',
        requiresConfirmation: false,
      ),
      ModuleToolContext(
        agentName: 'Agent',
        agentId: 'agent-1',
        moduleRepository: ModuleRepository(),
        attachments: const [
          AttachedFile(path: 'image.png', name: 'image.png', sizeBytes: 42),
        ],
        modelSupportsVision: true,
        describeImage: ({required image, required prompt}) async {
          throw DioException(
            requestOptions: RequestOptions(path: '/chat/completions'),
            response: Response(
              requestOptions: RequestOptions(path: '/chat/completions'),
              statusCode: 404,
            ),
            type: DioExceptionType.badResponse,
          );
        },
      ),
    );

    expect(result.success, isFalse);
    expect(result.error, isNot(contains('DioException')));
    expect(result.data?['errorCode'], 'vision_model_unsupported');
    expect(result.data?['failureKind'], 'capability_boundary');
    expect(result.data?['messageKey'], 'runtime_vision_model_unsupported');
    expect(result.data?['visionRequired'], isTrue);
    expect(result.data?['visionSupported'], isFalse);
    expect(result.data?['httpStatus'], 404);
  });

  test(
    'uses the only current attachment when selector sends a stale name',
    () async {
      final result = await plugin.dispatch(
        const ToolCallRequest(
          name: 'attachment.describe_image',
          args: {'name': 'previous-image.jpg'},
          risk: 'safe',
          requiresConfirmation: false,
        ),
        ModuleToolContext(
          agentName: 'Agent',
          agentId: 'agent-1',
          moduleRepository: ModuleRepository(),
          attachments: const [
            AttachedFile(
              path: 'current.png',
              name: 'current.png',
              sizeBytes: 42,
            ),
          ],
          modelSupportsVision: true,
          currentUserMessage: 'What is this image?',
          describeImage: _fakeDescribeCurrentImage,
        ),
      );

      expect(result.success, isTrue);
      expect(result.data?['name'], 'current.png');
      expect(result.data?['description'], 'current image answer');
    },
  );
}

Future<String> _fakeDescribeImage({
  required AttachedFile image,
  required String prompt,
}) async {
  expect(image.name, 'image.png');
  expect(prompt, 'What is in this image?');
  return 'vision answer';
}

Future<String> _fakeDescribeCurrentImage({
  required AttachedFile image,
  required String prompt,
}) async {
  expect(image.name, 'current.png');
  expect(prompt, 'What is this image?');
  return 'current image answer';
}
