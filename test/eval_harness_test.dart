/// Eval harness — real-LLM golden scenarios for regression testing.
///
/// Runs the runtime with a live LLM provider (from .env) and canned tool
/// results. Asserts structural outcomes (tool dispatch presence, final state)
/// rather than exact strings — tolerant of non-deterministic LLM output.
///
/// Run with: `flutter test test/eval_harness_test.dart --timeout 300s`
/// Requires `.env` with MEOW_TEST_BASE_URL, MEOW_TEST_API_KEY, MEOW_TEST_MODEL.
/// Skips cleanly when credentials are missing.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:meow_agent/features/providers/data/provider_config.dart';
import 'package:meow_agent/services/agent_runtime/context_builder.dart';
import 'package:meow_agent/services/agent_runtime/runtime_engine.dart';
import 'package:meow_agent/services/agent_runtime/runtime_models.dart';
import 'package:meow_agent/services/agent_runtime/task_ledger.dart';
import 'package:meow_agent/services/llm/openai_compatible_client.dart';

import 'support/env_loader.dart';
import 'support/fake_workspace_folder_service.dart';
import 'support/scripted_tool_router.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    EnvLoader.load();
  });

  ProviderConfig provider() => EnvLoader.isAvailable
      ? ProviderConfig(
          nickname: 'eval',
          baseUrl: EnvLoader.baseUrl,
          apiKey: EnvLoader.apiKey,
          model: EnvLoader.model,
        )
      : ProviderConfig(nickname: 'skip', baseUrl: '', apiKey: '', model: '');

  AgentRuntimeEngine buildEngine({required ScriptedToolRouter router}) =>
      AgentRuntimeEngine(
        workspaceFolder: FakeWorkspaceFolderService(),
        toolRouter: router,
        contextBuilder: ContextBuilder(),
        languageCode: 'id',
        llmClient: EnvLoader.isAvailable ? OpenAiCompatibleClient() : null,
        ledgerDb: TaskLedgerDatabase(overrideDbPath: inMemoryDatabasePath),
      );

  AgentRuntimeRequest req(String message) => AgentRuntimeRequest(
    agentId: 'eval-agent',
    agentName: 'EvalAgent',
    userMessage: message,
  );

  /// Print scored summary at the end.
  final results = <String, bool>{};
  void record(String name, bool passed) => results[name] = passed;

  tearDownAll(() {
    if (results.isEmpty) return;
    // ignore: avoid_print
    print('\n╔══════════════════════════════════════════════════════════════╗');
    // ignore: avoid_print
    print(
      '║  EVAL RESULTS (model: ${EnvLoader.isAvailable ? EnvLoader.model : "N/A"})',
    );
    // ignore: avoid_print
    print('╠══════════════════════════════════════════════════════════════╣');
    for (final e in results.entries) {
      final icon = e.value ? '✓' : '✗';
      // ignore: avoid_print
      print('║  $icon ${e.key}');
    }
    final passed = results.values.where((v) => v).length;
    // ignore: avoid_print
    print('╠══════════════════════════════════════════════════════════════╣');
    // ignore: avoid_print
    print('║  $passed/${results.length} passed');
    // ignore: avoid_print
    print('╚══════════════════════════════════════════════════════════════╝\n');
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // E1 — Open app (simple, single-tool fast-path)
  // ═══════════════════════════════════════════════════════════════════════════
  test('E1 open-app — buka whatsapp', () async {
    if (!EnvLoader.isAvailable) return;
    final router = ScriptedToolRouter(
      results: {
        'app.resolve': const ToolExecutionResult(
          success: true,
          toolName: 'app.resolve',
          data: {
            'query': 'whatsapp',
            'matched': true,
            'app': {
              'name': 'WhatsApp',
              'packageName': 'com.whatsapp',
              'confidence': 0.95,
            },
          },
        ),
        'app.open': const ToolExecutionResult(
          success: true,
          toolName: 'app.open',
          data: {'package': 'com.whatsapp', 'opened': true},
        ),
      },
    );
    final engine = buildEngine(router: router);
    final res = await engine.run(req('buka whatsapp'), provider: provider());

    final pass =
        res.state == AgentRuntimeState.done ||
        res.state == AgentRuntimeState.waitingConfirmation;
    record(
      'E1 open-app',
      pass && router.dispatchSequence.contains('app.resolve'),
    );
    expect(pass, isTrue, reason: 'state=${res.state}');
    expect(router.dispatchSequence, contains('app.resolve'));
  }, timeout: const Timeout(Duration(seconds: 90)));

  // ═══════════════════════════════════════════════════════════════════════════
  // E2 — Create note (single-tool)
  // ═══════════════════════════════════════════════════════════════════════════
  test(
    'E2 create-note — buat catatan tentang AI',
    () async {
      if (!EnvLoader.isAvailable) return;
      final router = ScriptedToolRouter(
        results: {
          'notes.create': const ToolExecutionResult(
            success: true,
            toolName: 'notes.create',
            data: {
              'noteId': 'note_eval_1',
              'created': true,
              'persisted': true,
              'verifiedFields': 1,
              'title': 'AI',
              'content': 'tentang AI',
            },
          ),
        },
      );
      final engine = buildEngine(router: router);
      final res = await engine.run(
        req('buat catatan tentang AI'),
        provider: provider(),
      );

      final pass =
          (res.state == AgentRuntimeState.done &&
              router.dispatchSequence.contains('notes.create')) ||
          res.state == AgentRuntimeState.askingUser;
      record('E2 create-note', pass);
      expect(
        pass,
        isTrue,
        reason:
            'Expected done+notes.create OR askingUser (clarify), got ${res.state}',
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  // ═══════════════════════════════════════════════════════════════════════════
  // E3 — Ambiguous/clarify (should ask user, NOT dispatch tool)
  // ═══════════════════════════════════════════════════════════════════════════
  test(
    'E3 ambiguous-clarify — set timer (no detail)',
    () async {
      if (!EnvLoader.isAvailable) return;
      final router = ScriptedToolRouter(results: {});
      final engine = buildEngine(router: router);
      await engine.run(req('set timer'), provider: provider());

      // Acceptable: askingUser (clarify) OR done with a "can't do that" message
      // (no timer tool exists). Should NOT dispatch any tool.
      final pass = router.dispatchSequence.isEmpty;
      record('E3 ambiguous-clarify', pass);
      expect(
        router.dispatchSequence,
        isEmpty,
        reason: 'No tool should be dispatched for ambiguous/impossible request',
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  // ═══════════════════════════════════════════════════════════════════════════
  // E4 — Create agent (clone self)
  // ═══════════════════════════════════════════════════════════════════════════
  test(
    'E4 create-agent — buatkan agen baru dengan nama TEST',
    () async {
      if (!EnvLoader.isAvailable) return;
      final router = ScriptedToolRouter(
        results: {
          'agent.create': const ToolExecutionResult(
            success: true,
            toolName: 'agent.create',
            data: {
              'id': 'eval-new-id',
              'name': 'TEST',
              'provider_id': 'p1',
              'model': 'test-model',
            },
          ),
          'agent.list': const ToolExecutionResult(
            success: true,
            toolName: 'agent.list',
            data: {
              'count': 1,
              'self_id': 'eval-agent',
              'self_name': 'EvalAgent',
              'agents': [
                {
                  'id': 'eval-agent',
                  'name': 'EvalAgent',
                  'provider_id': 'p1',
                  'model': 'm1',
                  'persona': '',
                  'communication_style': '',
                  'work_role': '',
                  'is_self': true,
                },
              ],
            },
          ),
        },
      );
      final engine = buildEngine(router: router);
      final res = await engine.run(
        req('buatkan agen baru dengan nama TEST'),
        provider: provider(),
        autoApproveSensitive: true,
      );

      final pass =
          res.state == AgentRuntimeState.done &&
          router.dispatchSequence.contains('agent.create');
      record('E4 create-agent', pass);
      expect(res.state, AgentRuntimeState.done);
      expect(router.dispatchSequence, contains('agent.create'));
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  // ═══════════════════════════════════════════════════════════════════════════
  // E5 — Read clipboard (trivial single tool)
  // ═══════════════════════════════════════════════════════════════════════════
  test(
    'E5 read-clipboard — baca clipboard saya',
    () async {
      if (!EnvLoader.isAvailable) return;
      final router = ScriptedToolRouter(
        results: {
          'clipboard.read': const ToolExecutionResult(
            success: true,
            toolName: 'clipboard.read',
            data: {'text': 'Hello from clipboard'},
          ),
        },
      );
      final engine = buildEngine(router: router);
      final res = await engine.run(
        req('baca clipboard saya'),
        provider: provider(),
      );

      final pass =
          res.state == AgentRuntimeState.done &&
          router.dispatchSequence.contains('clipboard.read');
      record('E5 read-clipboard', pass);
      expect(res.state, AgentRuntimeState.done);
      expect(router.dispatchSequence, contains('clipboard.read'));
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  // ═══════════════════════════════════════════════════════════════════════════
  // E6 — Direct response (no tools needed)
  // ═══════════════════════════════════════════════════════════════════════════
  test(
    'E6 direct-response — siapa namamu',
    () async {
      if (!EnvLoader.isAvailable) return;
      final router = ScriptedToolRouter(results: {});
      final engine = buildEngine(router: router);
      final res = await engine.run(req('siapa namamu?'), provider: provider());

      final pass =
          res.state == AgentRuntimeState.done &&
          router.dispatchSequence.isEmpty;
      record('E6 direct-response', pass);
      expect(res.state, AgentRuntimeState.done);
      expect(
        router.dispatchSequence,
        isEmpty,
        reason: 'Identity question needs no tool',
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
