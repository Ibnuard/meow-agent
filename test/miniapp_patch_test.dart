import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:meow_agent/features/providers/data/provider_config.dart';
import 'package:meow_agent/services/agent_runtime/context_builder.dart';
import 'package:meow_agent/services/agent_runtime/runtime_engine.dart';
import 'package:meow_agent/services/agent_runtime/runtime_models.dart';
import 'package:meow_agent/services/agent_runtime/task_ledger.dart';

import 'support/fake_workspace_folder_service.dart';
import 'support/scripted_llm_client.dart';
import 'support/scripted_tool_router.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  ProviderConfig provider() => ProviderConfig(
        nickname: 'test',
        baseUrl: 'http://localhost',
        apiKey: 'k',
        model: 'm',
      );

  AgentRuntimeEngine buildEngine({
    required ScriptedLlmClient llm,
    required ScriptedToolRouter router,
    TaskLedgerDatabase? ledgerDb,
  }) =>
      AgentRuntimeEngine(
        workspaceFolder: FakeWorkspaceFolderService(),
        toolRouter: router,
        contextBuilder: ContextBuilder(),
        languageCode: 'en',
        llmClient: llm,
        ledgerDb: ledgerDb,
      );

  AgentRuntimeRequest req(String message) => AgentRuntimeRequest(
        agentId: 'a1',
        agentName: 'TestAgent',
        userMessage: message,
      );

  group('Mini App Patch Reliability Gates (P0/P1)', () {
    test('rejects done status from selector when required capabilities are missing in codeInspection', () async {
      // Setup an LLM client that returns "done" prematurely, but requiredCapabilities has 'usesUserDatabase'.
      final llm = ScriptedLlmClient({
        'chat_route': [
          '{"route":"agentic","detected_language":"en","reason":"agentic execution required"}',
        ],
        'classify': [
          // Classify phase returns requiredCapabilities
          '{"intent":"miniapp.patch","goal":"Add database tracking to calorie tracker","requires_tools":true,'
              '"risk":"safe","tool_groups":["miniapp"],"missing_info":[],'
              '"subgoal_seeds":["Add database tracking"],'
              '"task_relation":"none","narrative":"",'
              '"required_capabilities":["usesUserDatabase"]}',
        ],
        'selectTool': [
          // 1. Selector selects miniapp.patch
          '{"status":"tool_required","tool":{"name":"miniapp.patch",'
              '"args":{"app":"calorie_tracker","targetContent":"<div>Calories</div>",'
              '"replacementContent":"<div>Calories (No DB)</div>"},"risk":"safe",'
              '"requires_confirmation":false},"narrative":""}',
          // 2. Selector returns done prematurely.
          // BUT since usesUserDatabase was false in the previous result, the gate must reject it,
          // and ask the selector to make a tool call instead. Let's make sure the selector sees the gate rejection note.
          '{"status":"done","final_response":"Finished.","narrative":""}',
          // 3. Since the selector is forced to continue by the gate, it now provides the correct patch.
          '{"status":"tool_required","tool":{"name":"miniapp.patch",'
              '"args":{"app":"calorie_tracker","targetContent":"<div>Calories (No DB)</div>",'
              '"replacementContent":"<script>window.meow.db.execute(\'CREATE TABLE...\');</script><div>Calories (DB)</div>"},"risk":"safe",'
              '"requires_confirmation":false},"narrative":""}',
          // 4. Selector returns done again. This time it will succeed because usesUserDatabase is true in the latest result.
          '{"status":"done","final_response":"Calorie tracker now uses database!","narrative":""}',
        ],
        'review': [
          // For miniapp.patch, it goes through selectTool -> execute -> review.
          // First attempt review: continues because we want the selector to return done or continue.
          // Here the reviewer returns continue, prompting the next selectTool.
          '{"status":"continue","reason":"Check if done","subgoal_update":{"id":"sg_main","status":"in_progress"},"narrative":""}',
          // Second attempt review: reviewer returns done. But since usesUserDatabase is true now, this will pass.
          '{"status":"done","final_response":"Calorie tracker now uses database!","subgoal_update":{"id":"sg_main","status":"done"},"narrative":""}',
        ],
        'verbalize.success': ['Done.'],
      });

      // The router returns custom codeInspection values.
      final router = ScriptedToolRouter(results: const {});
      router.resultsByCall['miniapp.patch'] = [
        // First patch doesn't add database.
        const ToolExecutionResult(
          success: true,
          toolName: 'miniapp.patch',
          data: {
            'id': 'calorie_tracker',
            'patched': true,
            'persisted': true,
            'codeInspection': {
              'usesMeowSdk': false,
              'usesUserDatabase': false,
              'usesThemeTokens': false,
            }
          },
        ),
        // Second patch successfully adds database.
        const ToolExecutionResult(
          success: true,
          toolName: 'miniapp.patch',
          data: {
            'id': 'calorie_tracker',
            'patched': true,
            'persisted': true,
            'codeInspection': {
              'usesMeowSdk': true,
              'usesUserDatabase': true,
              'usesThemeTokens': false,
            }
          },
        ),
      ];

      final engine = buildEngine(llm: llm, router: router);
      final res = await engine.run(
        req('Add database tracking to calorie tracker'),
        provider: provider(),
      );

      expect(res.success, true);
      expect(res.state, AgentRuntimeState.done);
      expect(res.finalMessage, contains('Calorie tracker now uses database!'));

      // Verify that two calls to miniapp.patch were dispatched.
      expect(router.dispatchCountOf('miniapp.patch'), 2);

      // Verify that the loop ran selector phase 3 times:
      // - First selectTool: tool_required (miniapp.patch)
      // - Second selectTool: done (rejected by gate, injected warning note)
      // - Third selectTool: tool_required (miniapp.patch)
      expect(llm.countOf('selectTool'), 3);

      // Verify that a capability_gate_rejected event was logged.
      final hasGateRejectedEvent = res.events.any((e) => e.type == 'divergence' && e.message == 'Recovery: capability_gate_rejected');
      expect(hasGateRejectedEvent, isTrue);
    });

    test('rejects done status from reviewer when required capabilities are missing in codeInspection', () async {
      // Setup an LLM client where reviewer attempts to return "done" prematurely, but requiredCapabilities has 'usesUserDatabase'.
      final llm = ScriptedLlmClient({
        'chat_route': [
          '{"route":"agentic","detected_language":"en","reason":"agentic execution required"}',
        ],
        'classify': [
          '{"intent":"miniapp.patch","goal":"Add database tracking to calorie tracker","requires_tools":true,'
              '"risk":"safe","tool_groups":["miniapp"],"missing_info":[],'
              '"subgoal_seeds":["Add database tracking"],'
              '"task_relation":"none","narrative":"",'
              '"required_capabilities":["usesUserDatabase"]}',
        ],
        'selectTool': [
          // 1. Selector selects miniapp.patch (no DB yet)
          '{"status":"tool_required","tool":{"name":"miniapp.patch",'
              '"args":{"app":"calorie_tracker","targetContent":"<div>Calories</div>",'
              '"replacementContent":"<div>Calories (No DB)</div>"},"risk":"safe",'
              '"requires_confirmation":false},"narrative":""}',
          // 2. After reviewer rejects the first done, selector patches again with the DB.
          '{"status":"tool_required","tool":{"name":"miniapp.patch",'
              '"args":{"app":"calorie_tracker","targetContent":"<div>Calories (No DB)</div>",'
              '"replacementContent":"<script>window.meow.db.execute(\'CREATE TABLE...\');</script><div>Calories (DB)</div>"},"risk":"safe",'
              '"requires_confirmation":false},"narrative":""}',
          // 3. Selector returns done.
          '{"status":"done","final_response":"Calorie tracker now uses database!","narrative":""}',
        ],
        'review': [
          // First attempt review: reviewer returns done prematurely (but usesUserDatabase is false).
          // The gate must reject it, log the divergence, retryCount = 0, and continue the loop.
          '{"status":"done","final_response":"Finished.","subgoal_update":{"id":"sg_main","status":"done"},"narrative":""}',
          // Second attempt review: reviewer returns done. Since usesUserDatabase is true now, it will succeed.
          '{"status":"done","final_response":"Calorie tracker now uses database!","subgoal_update":{"id":"sg_main","status":"done"},"narrative":""}',
        ],
        'verbalize.success': ['Done.'],
      });

      final router = ScriptedToolRouter(results: const {});
      router.resultsByCall['miniapp.patch'] = [
        const ToolExecutionResult(
          success: true,
          toolName: 'miniapp.patch',
          data: {
            'id': 'calorie_tracker',
            'patched': true,
            'persisted': true,
            'codeInspection': {
              'usesMeowSdk': false,
              'usesUserDatabase': false,
              'usesThemeTokens': false,
            }
          },
        ),
        const ToolExecutionResult(
          success: true,
          toolName: 'miniapp.patch',
          data: {
            'id': 'calorie_tracker',
            'patched': true,
            'persisted': true,
            'codeInspection': {
              'usesMeowSdk': true,
              'usesUserDatabase': true,
              'usesThemeTokens': false,
            }
          },
        ),
      ];

      final engine = buildEngine(llm: llm, router: router);
      final res = await engine.run(
        req('Add database tracking to calorie tracker'),
        provider: provider(),
      );

      expect(res.success, true);
      expect(res.state, AgentRuntimeState.done);

      expect(router.dispatchCountOf('miniapp.patch'), 2);
      expect(llm.countOf('review'), 1);

      final hasGateRejectedEvent = res.events.any((e) => e.type == 'divergence' && e.message == 'Recovery: capability_gate_rejected');
      expect(hasGateRejectedEvent, isTrue);
    });
  });
}
