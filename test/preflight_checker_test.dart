import 'package:flutter_test/flutter_test.dart';
import 'package:meow_agent/features/settings/data/llm_provider_config.dart';
import 'package:meow_agent/services/agent_runtime/ecosystem_snapshot.dart';
import 'package:meow_agent/services/agent_runtime/language_detector.dart';
import 'package:meow_agent/services/agent_runtime/preflight_checker.dart';
import 'package:meow_agent/services/agent_runtime/runtime_models.dart';
import 'package:meow_agent/services/agent_runtime/tool_verbalizer.dart';

import 'support/scripted_llm_client.dart';

void main() {
  test(
    'normalizes current-agent placeholder before snapshot preflight',
    () async {
      final checker = PreflightChecker(
        snapshotBuilder: () async => EcosystemSnapshot(
          builtAt: DateTime(2026, 1, 1),
          agents: const [
            EcosystemAgent(
              id: 'mina',
              name: 'Mina',
              providerNickname: 'SUMOPOD',
            ),
          ],
          workflows: const [],
          providers: const [],
          modules: const [],
        ),
      );
      final tool = ToolCallRequest(
        name: 'system.agents.update',
        args: {'name': 'current_agent', 'newName': 'Mina Prime'},
        risk: 'sensitive-lite',
        requiresConfirmation: true,
      );

      final result = await checker.check(
        tool: tool,
        definition: const ToolDefinition(
          name: 'system.agents.update',
          description: 'Update an existing agent.',
          risk: 'sensitive-lite',
          requiresConfirmation: true,
          operation: 'update',
          targetEntity: 'agent',
          selectorArgs: ['id', 'name'],
        ),
        verbalizer: ToolVerbalizer(
          client: ScriptedLlmClient(const {}),
          config: const LlmProviderConfig(
            baseUrl: 'test',
            apiKey: 'test',
            model: 'test',
          ),
        ),
        language: const DetectedLanguage(
          code: 'en',
          label: 'English',
          script: 'Latin',
          confidence: 1,
        ),
        userMessage: 'update this agent',
        currentAgentId: 'mina',
        currentAgentName: 'Mina',
      );

      expect(result, isNull);
      expect(tool.args['id'], 'mina');
      expect(tool.args['name'], 'Mina');
      expect(tool.args['agentId'], 'mina');
      expect(tool.args['agentName'], 'Mina');
    },
  );

  test(
    'normalizes current-agent placeholder even with empty snapshot',
    () async {
      final checker = PreflightChecker(
        snapshotBuilder: () async => EcosystemSnapshot(
          builtAt: DateTime(2026, 1, 1),
          agents: const [],
          workflows: const [],
          providers: const [],
          modules: const [],
        ),
      );
      final tool = ToolCallRequest(
        name: 'system.agents.update',
        args: {'id': 'current_agent', 'newName': 'Mina Prime'},
        risk: 'sensitive-lite',
        requiresConfirmation: true,
      );

      final result = await checker.check(
        tool: tool,
        definition: const ToolDefinition(
          name: 'system.agents.update',
          description: 'Update an existing agent.',
          risk: 'sensitive-lite',
          requiresConfirmation: true,
          operation: 'update',
          targetEntity: 'agent',
          selectorArgs: ['id', 'name'],
        ),
        verbalizer: ToolVerbalizer(
          client: ScriptedLlmClient(const {}),
          config: const LlmProviderConfig(
            baseUrl: 'test',
            apiKey: 'test',
            model: 'test',
          ),
        ),
        language: const DetectedLanguage(
          code: 'en',
          label: 'English',
          script: 'Latin',
          confidence: 1,
        ),
        userMessage: 'update this agent',
        currentAgentId: 'mina',
        currentAgentName: 'Mina',
      );

      expect(result, isNull);
      expect(tool.args['id'], 'mina');
      expect(tool.args['name'], 'Mina');
    },
  );
}
