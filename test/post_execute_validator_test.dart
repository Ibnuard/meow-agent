import 'package:flutter_test/flutter_test.dart';
import 'package:meow_agent/services/agent_runtime/ecosystem_snapshot.dart';
import 'package:meow_agent/services/agent_runtime/post_execute_validator.dart';
import 'package:meow_agent/services/agent_runtime/runtime_models.dart';

void main() {
  PostExecuteValidator validator() => PostExecuteValidator(
    snapshotBuilder: () async => EcosystemSnapshot(
      agents: const [],
      workflows: const [],
      providers: const [],
      modules: const [],
      builtAt: DateTime.now(),
    ),
  );

  test('tool_result_data rejects zero affected mutation counts', () async {
    final result = await validator().verify(
      tool: const ToolCallRequest(
        name: 'db.update',
        args: {'table': 'tasks'},
        risk: 'sensitive-lite',
        requiresConfirmation: false,
      ),
      definition: const ToolDefinition(
        name: 'db.update',
        description: 'Update rows',
        risk: 'sensitive-lite',
        requiresConfirmation: false,
        selectorArgs: ['table'],
        verificationProbe: ToolVerificationProbe(
          kind: 'tool_result_data',
          entityType: 'row',
          expectedDataKeys: ['updated'],
        ),
      ),
      result: const ToolExecutionResult(
        success: true,
        toolName: 'db.update',
        data: {'updated': 0},
      ),
    );

    expect(result.isUnverified, true);
    expect(result.reason, 'tool_result_non_positive:updated');
  });

  test(
    'tool_result_data rejects result values that contradict tool args',
    () async {
      final result = await validator().verify(
        tool: const ToolCallRequest(
          name: 'system.profile.update',
          args: {'field': 'name', 'value': 'Nunu'},
          risk: 'sensitive-lite',
          requiresConfirmation: false,
        ),
        definition: const ToolDefinition(
          name: 'system.profile.update',
          description: 'Update profile',
          risk: 'sensitive-lite',
          requiresConfirmation: false,
          selectorArgs: ['field'],
          verificationProbe: ToolVerificationProbe(
            kind: 'tool_result_data',
            entityType: 'profile',
            expectedDataKeys: ['field'],
          ),
        ),
        result: const ToolExecutionResult(
          success: true,
          toolName: 'system.profile.update',
          data: {'field': 'nickname', 'value': 'Nunu'},
        ),
      );

      expect(result.isUnverified, true);
      expect(result.reason, contains('tool_result_arg_mismatch:field'));
    },
  );

  test(
    'tool_result_data accepts positive count and matching echoed args',
    () async {
      final result = await validator().verify(
        tool: const ToolCallRequest(
          name: 'db.delete',
          args: {'table': 'tasks'},
          risk: 'sensitive-lite',
          requiresConfirmation: true,
        ),
        definition: const ToolDefinition(
          name: 'db.delete',
          description: 'Delete rows',
          risk: 'sensitive-lite',
          requiresConfirmation: true,
          selectorArgs: ['table'],
          verificationProbe: ToolVerificationProbe(
            kind: 'tool_result_data',
            entityType: 'row',
            expectedDataKeys: ['deleted', 'table'],
          ),
        ),
        result: const ToolExecutionResult(
          success: true,
          toolName: 'db.delete',
          data: {'deleted': 2, 'table': 'tasks'},
        ),
      );

      expect(result.isOk, true);
    },
  );
}
