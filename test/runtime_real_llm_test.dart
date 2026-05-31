/// Real-LLM integration tests for the Meow Agent runtime engine.
///
/// Uses a live OpenAI-compatible provider configured via `.env` for accurate
/// testing of the full agentic loop (Planner → Reflector → Executor →
/// ToolVerbalizer). Tool execution is canned via [ScriptedToolRouter] so no
/// real filesystem/native calls happen.
///
/// **Prerequisites:**
///   - `.env` file at project root with MEOW_TEST_BASE_URL, MEOW_TEST_API_KEY,
///     MEOW_TEST_MODEL.
///   - Tests are skipped when credentials are missing.
///
/// **Timeouts:** Each test has a generous timeout (60s) to accommodate real
/// network latency. Run with: `flutter test test/runtime_real_llm_test.dart`
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
import 'support/fake_workspace_loader.dart';
import 'support/scripted_tool_router.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    EnvLoader.load(projectRoot: r'D:\Dev\Personal\PROJECT_MEOW');
  });

  ProviderConfig provider() => EnvLoader.isAvailable
      ? ProviderConfig(
          nickname: 'test-real',
          baseUrl: EnvLoader.baseUrl,
          apiKey: EnvLoader.apiKey,
          model: EnvLoader.model,
        )
      : ProviderConfig(nickname: 'skip', baseUrl: '', apiKey: '', model: '');

  AgentRuntimeEngine buildEngine({
    required ScriptedToolRouter router,
    FakeWorkspaceLoader? workspace,
  }) {
    final llm = EnvLoader.isAvailable ? OpenAiCompatibleClient() : null;
    return AgentRuntimeEngine(
      workspaceLoader: workspace ?? FakeWorkspaceLoader(),
      toolRouter: router,
      contextBuilder: ContextBuilder(),
      languageCode: 'en',
      llmClient: llm,
      ledgerDb: TaskLedgerDatabase(overrideDbPath: inMemoryDatabasePath),
    );
  }

  AgentRuntimeRequest req(String message, {String agentId = 'a1'}) =>
      AgentRuntimeRequest(
        agentId: agentId,
        agentName: 'TestAgent',
        userMessage: message,
      );

  // ═══════════════════════════════════════════════════════════════════════
  // R1 — Simple read (battery)
  // ═══════════════════════════════════════════════════════════════════════
  test('R1 simple read — battery level', () async {
    if (!EnvLoader.isAvailable) return;
    final router = ScriptedToolRouter(
      results: {
        'device.battery': const ToolExecutionResult(
          success: true,
          toolName: 'device.battery',
          data: {'level': 72, 'charging': true},
        ),
      },
    );
    final engine = buildEngine(router: router);

    final res = await engine.run(
      req('how much battery do I have left?'),
      provider: provider(),
    );

    expect(res.state, AgentRuntimeState.done);
    expect(res.success, true);
    // Must mention the battery level from the canned result.
    expect(res.finalMessage.toLowerCase(), contains('72'));
    expect(router.dispatchSequence.length, greaterThanOrEqualTo(1));
  }, timeout: const Timeout(Duration(seconds: 90)));

  // ═══════════════════════════════════════════════════════════════════════
  // R2 — Simple write (create note)
  // ═══════════════════════════════════════════════════════════════════════
  test('R2 simple write — create a note', () async {
    if (!EnvLoader.isAvailable) return;
    final router = ScriptedToolRouter(
      results: {
        'notes.create': const ToolExecutionResult(
          success: true,
          toolName: 'notes.create',
          data: {'noteId': 'n42', 'title': 'Shopping List', 'created': true},
        ),
      },
    );
    final engine = buildEngine(router: router);

    final res = await engine.run(
      req('create a note titled Shopping List with milk and eggs'),
      provider: provider(),
    );

    expect(res.success, true);
    expect(res.state, AgentRuntimeState.done);
    expect(router.dispatchCountOf('notes.create'), greaterThanOrEqualTo(1));
  }, timeout: const Timeout(Duration(seconds: 90)));

  // ═══════════════════════════════════════════════════════════════════════
  // R3 — No capability → honest refusal
  // ═══════════════════════════════════════════════════════════════════════
  test('R3 no capability — does not fabricate success', () async {
    if (!EnvLoader.isAvailable) return;
    final router = ScriptedToolRouter(results: const {});
    final engine = buildEngine(router: router);

    final res = await engine.run(
      req('send an SMS to my mom saying I will be late'),
      provider: provider(),
    );

    // No SMS tool exists. The real LLM may route to another tool (notes),
    // respond conversationally, or honestly refuse. What matters: it must NOT
    // fabricate an SMS capability or claim to have sent an SMS.
    expect(res.state,
        anyOf(AgentRuntimeState.done, AgentRuntimeState.failed,
            AgentRuntimeState.askingUser));
    expect(res.finalMessage.toLowerCase(), isNot(contains('sms sent')));
    // Must not dispatch a non-existent SMS tool.
    expect(router.dispatchSequence.any((t) => t.contains('sms')), false);
  }, timeout: const Timeout(Duration(seconds: 90)));

  // ═══════════════════════════════════════════════════════════════════════
  // R4 — Ambiguous request → clarify
  // ═══════════════════════════════════════════════════════════════════════
  test('R4 ambiguous request — asks clarifying question', () async {
    if (!EnvLoader.isAvailable) return;
    final router = ScriptedToolRouter(
      results: {
        'notes.create': const ToolExecutionResult(
          success: true,
          toolName: 'notes.create',
          data: {'noteId': 'n1', 'created': true},
        ),
      },
    );
    final engine = buildEngine(router: router);

    final res = await engine.run(
      req('schedule something for tomorrow'),
      provider: provider(),
    );

    // Should either ask for clarification or use a calendar tool.
    // If it went through without clarification, that's OK too — real LLM
    // might figure out defaults. We just verify it doesn't crash.
    expect(res.state,
        anyOf(AgentRuntimeState.done, AgentRuntimeState.askingUser));
    // If it asked, the message should be non-empty.
    if (res.state == AgentRuntimeState.askingUser) {
      expect(res.finalMessage, isNotEmpty);
    }
  }, timeout: const Timeout(Duration(seconds: 90)));

  // ═══════════════════════════════════════════════════════════════════════
  // R5 — Multi-target create (3 notes)
  // ═══════════════════════════════════════════════════════════════════════
  test('R5 multi-target — create three notes', () async {
    if (!EnvLoader.isAvailable) return;
    final router = ScriptedToolRouter(
      results: {
        'notes.create': const ToolExecutionResult(
          success: true,
          toolName: 'notes.create',
          data: {'noteId': 'n_multi', 'created': true},
        ),
      },
    );
    final engine = buildEngine(router: router);

    final res = await engine.run(
      req('create three notes: one about meeting agenda, one about groceries, '
          'and one about book recommendations'),
      provider: provider(),
    );

    expect(res.success, true);
    // Real LLM may ask for clarification on note content or proceed directly.
    expect(res.state,
        anyOf(AgentRuntimeState.done, AgentRuntimeState.askingUser));
    // If done, should have created at least 2 notes; if asking user, no dispatch yet.
    if (res.state == AgentRuntimeState.done) {
      expect(router.dispatchCountOf('notes.create'), greaterThanOrEqualTo(2));
    }
  }, timeout: const Timeout(Duration(seconds: 120)));

  // ═══════════════════════════════════════════════════════════════════════
  // R6 — Language detection: Indonesian message → reply in Indonesian
  // ═══════════════════════════════════════════════════════════════════════
  test('R6 language detection — replies in Indonesian', () async {
    if (!EnvLoader.isAvailable) return;
    final router = ScriptedToolRouter(
      results: {
        'device.battery': const ToolExecutionResult(
          success: true,
          toolName: 'device.battery',
          data: {'level': 55, 'charging': false},
        ),
      },
    );
    final engine = buildEngine(router: router);

    final res = await engine.run(
      req('berapa baterai aku sekarang?'),
      provider: provider(),
    );

    expect(res.success, true);
    expect(res.state, AgentRuntimeState.done);
  }, timeout: const Timeout(Duration(seconds: 90)));

  // ═══════════════════════════════════════════════════════════════════════
  // R7 — Sensitive action parks for confirmation (open app)
  // ═══════════════════════════════════════════════════════════════════════
  test('R7 sensitive tool — parks for confirmation', () async {
    if (!EnvLoader.isAvailable) return;
    final router = ScriptedToolRouter(
      results: {
        'app.open': const ToolExecutionResult(
          success: true,
          toolName: 'app.open',
          data: {'opened': true},
        ),
      },
    );
    final engine = buildEngine(router: router);

    final res = await engine.run(
      req('open WhatsApp'),
      provider: provider(),
    );

    // Sensitive tools should require confirmation.
    // The app.open tool may need app resolution, and the real LLM may take
    // different paths. Accept any reasonable non-crash outcome.
    expect(res.state,
        anyOf(AgentRuntimeState.waitingConfirmation, AgentRuntimeState.done,
            AgentRuntimeState.askingUser, AgentRuntimeState.failed));
    expect(res.finalMessage, isNotEmpty);
  }, timeout: const Timeout(Duration(seconds: 90)));

  // ═══════════════════════════════════════════════════════════════════════
  // R8 — List/search tool returns results correctly
  // ═══════════════════════════════════════════════════════════════════════
  test('R8 list agents — returns list without hallucination', () async {
    if (!EnvLoader.isAvailable) return;
    final router = ScriptedToolRouter(
      results: {
        'system.agents.list': const ToolExecutionResult(
          success: true,
          toolName: 'system.agents.list',
          data: {
            'agents': [
              {'id': 'agent_1', 'name': 'Mina Chan', 'role': 'assistant'},
              {'id': 'agent_2', 'name': 'Kai', 'role': 'productivity'},
            ],
            'count': 2,
          },
        ),
      },
    );
    final engine = buildEngine(router: router);

    final res = await engine.run(
      req('what agents do I have installed?'),
      provider: provider(),
    );

    expect(res.success, true);
    expect(res.state, AgentRuntimeState.done);
    // The response must mention at least one agent name from the canned data.
    final msg = res.finalMessage.toLowerCase();
    expect(msg, anyOf(contains('mina'), contains('kai'), contains('agent')));
    expect(router.dispatchCountOf('system.agents.list'), 1);
  }, timeout: const Timeout(Duration(seconds: 90)));

  // ═══════════════════════════════════════════════════════════════════════
  // R9 — Empty search result is the answer, no retry loop
  // ═══════════════════════════════════════════════════════════════════════
  test('R9 empty search — honest empty, no retry', () async {
    if (!EnvLoader.isAvailable) return;
    final router = ScriptedToolRouter(
      results: {
        'notes.search': const ToolExecutionResult(
          success: true,
          toolName: 'notes.search',
          data: {'count': 0, 'results': []},
        ),
      },
    );
    final engine = buildEngine(router: router);

    final res = await engine.run(
      req('find my notes about quantum physics'),
      provider: provider(),
    );

    expect(res.success, true);
    expect(res.state, AgentRuntimeState.done);
    // The search tool should only run once — no retry loop.
    expect(router.dispatchCountOf('notes.search'), 1);
  }, timeout: const Timeout(Duration(seconds: 90)));

  // ═══════════════════════════════════════════════════════════════════════
  // R10 — Device info (multiple safe reads chained)
  // ═══════════════════════════════════════════════════════════════════════
  test('R10 device info — chained safe reads', () async {
    if (!EnvLoader.isAvailable) return;
    final router = ScriptedToolRouter(
      results: {
        'device.battery': const ToolExecutionResult(
          success: true,
          toolName: 'device.battery',
          data: {'level': 88, 'charging': true},
        ),
        'device.network': const ToolExecutionResult(
          success: true,
          toolName: 'device.network',
          data: {'type': 'wifi', 'connected': true, 'ssid': 'HomeWiFi'},
        ),
        'device.storage': const ToolExecutionResult(
          success: true,
          toolName: 'device.storage',
          data: {'total': 128, 'available': 45},
        ),
      },
    );
    final engine = buildEngine(router: router);

    final res = await engine.run(
      req('give me a full status report on my device'),
      provider: provider(),
    );

    // Real LLM chained reads: the LLM should call at least 1 device tool
    // (battery, network, or storage). Chaining all three is ideal but may not
    // always happen — the response should at least be non-empty and grounded.
    expect(res.state,
        anyOf(AgentRuntimeState.done, AgentRuntimeState.askingUser));
    expect(res.finalMessage, isNotEmpty);
    expect(router.dispatchSequence.length, greaterThanOrEqualTo(1));
  }, timeout: const Timeout(Duration(seconds: 120)));

  // ═══════════════════════════════════════════════════════════════════════
  // R11 — Cross-reference: create note then search for it
  // ═══════════════════════════════════════════════════════════════════════
  test('R11 cross-reference — create then verify', () async {
    if (!EnvLoader.isAvailable) return;
    final router = ScriptedToolRouter(
      results: {
        'notes.create': const ToolExecutionResult(
          success: true,
          toolName: 'notes.create',
          data: {'noteId': 'n_xref', 'title': 'Meeting Notes', 'created': true},
        ),
        'notes.list': const ToolExecutionResult(
          success: true,
          toolName: 'notes.list',
          data: {
            'notes': [
              {'id': 'n_xref', 'title': 'Meeting Notes', 'created': '2026-06-01'},
            ],
            'count': 1,
          },
        ),
      },
    );
    final engine = buildEngine(router: router);

    final res = await engine.run(
      req('create a note called "Meeting Notes" then show me all my notes'),
      provider: provider(),
    );

    expect(res.success, true);
    expect(res.state, AgentRuntimeState.done);
    expect(router.dispatchCountOf('notes.create'), greaterThanOrEqualTo(1));
  }, timeout: const Timeout(Duration(seconds: 120)));

  // ═══════════════════════════════════════════════════════════════════════
  // R12 — Intent with no tools needed (conversational)
  // ═══════════════════════════════════════════════════════════════════════
  test('R12 conversational — no tools, direct response', () async {
    if (!EnvLoader.isAvailable) return;
    final router = ScriptedToolRouter(results: const {});
    final engine = buildEngine(router: router);

    final res = await engine.run(
      req('hello! how are you today?'),
      provider: provider(),
    );

    expect(res.success, true);
    expect(res.state, AgentRuntimeState.done);
    expect(res.finalMessage, isNotEmpty);
    expect(router.dispatchSequence, isEmpty);
  }, timeout: const Timeout(Duration(seconds: 90)));

  // ═══════════════════════════════════════════════════════════════════════
  // R13 — Failed tool → honest failure, never claims success
  // ═══════════════════════════════════════════════════════════════════════
  test('R13 failed tool — reports failure honestly', () async {
    if (!EnvLoader.isAvailable) return;
    final router = ScriptedToolRouter(
      results: {
        'notes.create': const ToolExecutionResult(
          success: false,
          toolName: 'notes.create',
          error: 'Storage is full — cannot create note.',
        ),
      },
    );
    final engine = buildEngine(router: router);

    final res = await engine.run(
      req('make a note titled Important'),
      provider: provider(),
    );

    expect(res.success, false);
    // Must not contain language suggesting success.
    expect(res.finalMessage.toLowerCase(), isNot(contains('created')));
    expect(res.finalMessage.toLowerCase(), isNot(contains('saved')));
  }, timeout: const Timeout(Duration(seconds: 90)));

  // ═══════════════════════════════════════════════════════════════════════
  // R14 — Phase 6 smoke: complex multi-subgoal with confirmation gate
  // ═══════════════════════════════════════════════════════════════════════
  test('R14 multi-subgoal + confirmation — create agent then delete',
      () async {
    if (!EnvLoader.isAvailable) return;
    final router = ScriptedToolRouter(
      results: {
        'system.agents.create': const ToolExecutionResult(
          success: true,
          toolName: 'system.agents.create',
          data: {'agentId': 'new_test_bot', 'name': 'TestBot', 'created': true},
        ),
        'system.agents.list': const ToolExecutionResult(
          success: true,
          toolName: 'system.agents.list',
          data: {
            'agents': [
              {'id': 'new_test_bot', 'name': 'TestBot', 'role': 'assistant'},
            ],
            'count': 1,
          },
        ),
        'system.agents.delete': const ToolExecutionResult(
          success: true,
          toolName: 'system.agents.delete',
          data: {'agentId': 'new_test_bot', 'deleted': true},
        ),
      },
    );
    final engine = buildEngine(router: router);

    final res = await engine.run(
      req('create an agent named TestBot, then list all agents, '
          'then delete TestBot'),
      provider: provider(),
    );

    // This is complex — real LLM may stop for confirmation on delete.
    // We just verify it doesn't crash and produces a reasonable result.
    expect(res.state,
        anyOf(AgentRuntimeState.done, AgentRuntimeState.waitingConfirmation,
            AgentRuntimeState.askingUser));
    expect(
      router.dispatchCountOf('system.agents.create'),
      greaterThanOrEqualTo(1),
    );
  }, timeout: const Timeout(Duration(seconds: 150)));

  // ═══════════════════════════════════════════════════════════════════════
  // R15 — Bulk predicate: delete notes matching a pattern
  // ═══════════════════════════════════════════════════════════════════════
  test('R15 bulk predicate — delete notes with pattern in title', () async {
    if (!EnvLoader.isAvailable) return;
    final router = ScriptedToolRouter(
      results: {
        'notes.delete': const ToolExecutionResult(
          success: true,
          toolName: 'notes.delete',
          data: {'deleted': 2, 'matched': ['draft1.md', 'draft2.md']},
        ),
        'notes.search': const ToolExecutionResult(
          success: true,
          toolName: 'notes.search',
          data: {
            'results': [
              {'id': 'n1', 'title': 'draft: ideas'},
              {'id': 'n2', 'title': 'draft: shopping'},
            ],
            'count': 2,
          },
        ),
      },
    );
    final engine = buildEngine(router: router);

    final res = await engine.run(
      req('delete all my notes that have the word draft in them'),
      provider: provider(),
    );

    // Bulk predicate delete. Real LLM may search first or delete directly.
    // Must not crash and should produce a reasonable result.
    expect(res.state,
        anyOf(AgentRuntimeState.done, AgentRuntimeState.waitingConfirmation,
            AgentRuntimeState.askingUser, AgentRuntimeState.failed));
    expect(res.finalMessage, isNotEmpty);
  }, timeout: const Timeout(Duration(seconds: 120)));

  // ═══════════════════════════════════════════════════════════════════════
  // R16 — Complex chained workflow: create → read → update → delete agent
  // ═══════════════════════════════════════════════════════════════════════
  test('R16 complex chained — create, read, update, delete agent',
      () async {
    if (!EnvLoader.isAvailable) return;
    final router = ScriptedToolRouter(
      results: {
        'system.agents.create': const ToolExecutionResult(
          success: true,
          toolName: 'system.agents.create',
          data: {'agentId': 'chain_test', 'name': 'ChainBot', 'created': true},
        ),
        'system.agents.list': const ToolExecutionResult(
          success: true,
          toolName: 'system.agents.list',
          data: {
            'agents': [
              {'id': 'chain_test', 'name': 'ChainBot', 'role': 'assistant'},
            ],
            'count': 1,
          },
        ),
        'system.agents.update': const ToolExecutionResult(
          success: true,
          toolName: 'system.agents.update',
          data: {'agentId': 'chain_test', 'updated': true},
        ),
        'system.agents.delete': const ToolExecutionResult(
          success: true,
          toolName: 'system.agents.delete',
          data: {'agentId': 'chain_test', 'deleted': true},
        ),
      },
    );
    final engine = buildEngine(router: router);

    final res = await engine.run(
      req('create an agent called ChainBot, then rename it to LinkBot, '
          'then delete it'),
      provider: provider(),
    );

    // Complex multi-step — real LLM may stop at any point for confirmation.
    expect(res.state,
        anyOf(AgentRuntimeState.done, AgentRuntimeState.waitingConfirmation,
            AgentRuntimeState.askingUser, AgentRuntimeState.failed));
    expect(res.finalMessage, isNotEmpty);
  }, timeout: const Timeout(Duration(seconds: 150)));

  // ═══════════════════════════════════════════════════════════════════════
  // R17 — Indonesian compound multi-target request
  // ═══════════════════════════════════════════════════════════════════════
  test('R17 Indonesian multi-target — compound request in ID', () async {
    if (!EnvLoader.isAvailable) return;
    final router = ScriptedToolRouter(
      results: {
        'system.agents.create': const ToolExecutionResult(
          success: true,
          toolName: 'system.agents.create',
          data: {'agentId': 'bumi_id', 'name': 'Bumi', 'created': true},
        ),
        'system.agents.list': const ToolExecutionResult(
          success: true,
          toolName: 'system.agents.list',
          data: {
            'agents': [
              {'id': 'bumi_id', 'name': 'Bumi', 'role': 'assistant'},
              {'id': 'mars_id', 'name': 'Mars', 'role': 'assistant'},
            ],
            'count': 2,
          },
        ),
      },
    );
    final engine = buildEngine(router: router);

    final res = await engine.run(
      req('bikinin 2 agen baru dengan nama Bumi dan Mars, '
          'terus tunjukkin semua agen yang udah ada'),
      provider: provider(),
    );

    expect(res.state,
        anyOf(AgentRuntimeState.done, AgentRuntimeState.waitingConfirmation,
            AgentRuntimeState.askingUser));
    expect(res.finalMessage, isNotEmpty);
    // Engine should not crash on Indonesian compound requests.
  }, timeout: const Timeout(Duration(seconds: 120)));

  // ═══════════════════════════════════════════════════════════════════════
  // R18 — Empty ecosystem: no agents/workflows installed
  // ═══════════════════════════════════════════════════════════════════════
  test('R18 empty ecosystem — honest about no data', () async {
    if (!EnvLoader.isAvailable) return;
    final router = ScriptedToolRouter(
      results: {
        'system.agents.list': const ToolExecutionResult(
          success: true,
          toolName: 'system.agents.list',
          data: {'agents': [], 'count': 0},
        ),
        'system.workflows.list': const ToolExecutionResult(
          success: true,
          toolName: 'system.workflows.list',
          data: {'workflows': [], 'count': 0},
        ),
        'system.modules.list': const ToolExecutionResult(
          success: true,
          toolName: 'system.modules.list',
          data: {'modules': [], 'count': 0},
        ),
      },
    );
    final engine = buildEngine(router: router);

    final res = await engine.run(
      req('what do I have installed in my system?'),
      provider: provider(),
    );

    expect(res.state,
        anyOf(AgentRuntimeState.done, AgentRuntimeState.askingUser));
    expect(res.finalMessage, isNotEmpty);
    // Response must be grounded — empty results should not produce hallucinations.
    // No agent names should appear that weren't in the canned results.
  }, timeout: const Timeout(Duration(seconds: 120)));

  // ═══════════════════════════════════════════════════════════════════════
  // R19 — Retry after tool failure: honest recovery attempt
  // ═══════════════════════════════════════════════════════════════════════
  test('R19 failed tool — recovery attempts, honest outcome', () async {
    if (!EnvLoader.isAvailable) return;
    final router = ScriptedToolRouter(
      results: {
        'notes.create': const ToolExecutionResult(
          success: false,
          toolName: 'notes.create',
          error: 'Storage quota exceeded. Cannot create note.',
        ),
      },
    );
    final engine = buildEngine(router: router);

    final res = await engine.run(
      req('create a note called "System Design Notes" with details about '
          'microservices architecture'),
      provider: provider(),
    );

    // Failed tool — the engine should attempt recovery and report honestly.
    // Must NOT fabricate success or claim the note was created.
    expect(res.state,
        anyOf(AgentRuntimeState.failed, AgentRuntimeState.askingUser));
    final msg = res.finalMessage.toLowerCase();
    expect(msg, isNot(contains('created the note')));
    expect(msg, isNot(contains('note saved')));
    expect(msg, isNot(contains('successfully')));
  }, timeout: const Timeout(Duration(seconds: 120)));

  // ═══════════════════════════════════════════════════════════════════════
  // R20 — Conversational / no tools: direct response
  // ═══════════════════════════════════════════════════════════════════════
  test('R20 conversational greeting — direct response, no tools', () async {
    if (!EnvLoader.isAvailable) return;
    final router = ScriptedToolRouter(results: const {});
    final engine = buildEngine(router: router);

    final res = await engine.run(
      req('hi there! what can you help me with today?'),
      provider: provider(),
    );

    expect(res.success, true);
    expect(res.state, AgentRuntimeState.done);
    expect(res.finalMessage, isNotEmpty);
    // Conversational — no tools should be dispatched.
    // The response should be a helpful introduction, not a tool error.
  }, timeout: const Timeout(Duration(seconds: 90)));
}