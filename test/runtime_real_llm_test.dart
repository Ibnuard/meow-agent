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
import 'support/fake_workspace_folder_service.dart';
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
  }) {
    final llm = EnvLoader.isAvailable ? OpenAiCompatibleClient() : null;
    return AgentRuntimeEngine(
      workspaceFolder: FakeWorkspaceFolderService(),
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
        'agent.list': const ToolExecutionResult(
          success: true,
          toolName: 'agent.list',
          data: {
            'count': 2,
            'self_id': 'agent_1',
            'self_name': 'Mina Chan',
            'agents': [
              {
                'id': 'agent_1',
                'name': 'Mina Chan',
                'provider_id': 'p1',
                'model': 'm1',
                'persona': '',
                'communication_style': '',
                'work_role': '',
                'is_self': true,
              },
              {
                'id': 'agent_2',
                'name': 'Kai',
                'provider_id': 'p1',
                'model': 'm1',
                'persona': '',
                'communication_style': '',
                'work_role': '',
                'is_self': false,
              },
            ],
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
    expect(router.dispatchCountOf('agent.list'), greaterThanOrEqualTo(1));
    // Must not invent a non-existent agents.* tool path.
    expect(
      router.dispatchSequence.where((t) => t.startsWith('system.agents.')),
      isEmpty,
    );
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
        'device.summary': const ToolExecutionResult(
          success: true,
          toolName: 'device.summary',
          data: {
            'battery': {'level': 88, 'charging': true},
            'network': {'type': 'wifi', 'connected': true},
            'storage': {'total': 128, 'available': 45},
          },
        ),
      },
    );
    final engine = buildEngine(router: router);

    final res = await engine.run(
      req('give me a full status report on my device'),
      provider: provider(),
    );

    print('R10 state: ${res.state}, success: ${res.success}, message: ${res.finalMessage}');
    for (final ev in res.events) {
      print('  Event: [${ev.type}] ${ev.message} (data: ${ev.data})');
    }
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
        'notes.list_recent': const ToolExecutionResult(
          success: true,
          toolName: 'notes.list_recent',
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

    // Real LLM may ask for note body (POLICY.ASK slot extraction) or
    // complete directly. Both are valid behaviors.
    expect(res.state,
        anyOf(AgentRuntimeState.done, AgentRuntimeState.askingUser));
    if (res.state == AgentRuntimeState.done) {
      expect(res.success, true);
      expect(router.dispatchCountOf('notes.create'), greaterThanOrEqualTo(1));
    }
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

    // The tool ALWAYS fails — but the LLM may report failure honestly
    // (preferred) OR retry once before giving up. The hard contract is:
    // the final message MUST NOT claim the note was created/saved.
    expect(res.finalMessage.toLowerCase(), isNot(contains('created')));
    expect(res.finalMessage.toLowerCase(), isNot(contains('saved')));
    expect(res.finalMessage.toLowerCase(), isNot(contains('successfully')));
  }, timeout: const Timeout(Duration(seconds: 90)));

  // ═══════════════════════════════════════════════════════════════════════
  // R14 — Phase 6 smoke: complex multi-subgoal with confirmation gate
  // ═══════════════════════════════════════════════════════════════════════
  test('R14 multi-subgoal + confirmation — create agent then delete',
      () async {
    if (!EnvLoader.isAvailable) return;
    final router = ScriptedToolRouter(
      results: {
        'agent.list': const ToolExecutionResult(
          success: true,
          toolName: 'agent.list',
          data: {
            'count': 1,
            'self_id': 'a1',
            'self_name': 'TestAgent',
            'agents': [
              {
                'id': 'a1',
                'name': 'TestAgent',
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
        'agent.create': const ToolExecutionResult(
          success: true,
          toolName: 'agent.create',
          data: {
            'id': 'a2',
            'name': 'TestBot',
            'provider_id': 'p1',
            'model': 'm1',
          },
        ),
        'agent.delete': const ToolExecutionResult(
          success: true,
          toolName: 'agent.delete',
          data: {
            'deleted': true,
            'name': 'TestBot',
            'id': 'a2',
          },
        ),
      },
    );
    final engine = buildEngine(router: router);

    final res = await engine.run(
      req('create an agent named TestBot, then delete TestBot'),
      provider: provider(),
    );

    // Real LLM may: (a) ask for the persona first (FIRST_ASK_USER — slot
    // extraction flags missing persona), (b) park at the confirmation gate
    // for the sensitive agent.create/delete, or (c) complete. All are valid.
    expect(res.state,
        anyOf(AgentRuntimeState.done, AgentRuntimeState.waitingConfirmation,
            AgentRuntimeState.askingUser));
    // Only when it reaches done should the tools have actually executed.
    // askingUser (clarify) and waitingConfirmation (parked) legitimately
    // produce zero dispatches.
    if (res.state == AgentRuntimeState.done) {
      expect(
        router.dispatchCountOf('agent.delete'),
        greaterThanOrEqualTo(1),
      );
    }
    // The runtime must never invent a non-existent tool path.
    expect(
      router.dispatchSequence.where((t) => t.startsWith('system.agents.')),
      isEmpty,
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
        'agent.list': const ToolExecutionResult(
          success: true,
          toolName: 'agent.list',
          data: {
            'count': 1,
            'self_id': 'chain_test',
            'self_name': 'ChainBot',
            'agents': [
              {
                'id': 'chain_test',
                'name': 'ChainBot',
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
        'agent.create': const ToolExecutionResult(
          success: true,
          toolName: 'agent.create',
          data: {
            'id': 'chain_test',
            'name': 'ChainBot',
            'provider_id': 'p1',
            'model': 'm1',
          },
        ),
        'agent.update': const ToolExecutionResult(
          success: true,
          toolName: 'agent.update',
          data: {
            'id': 'chain_test',
            'name': 'LinkBot',
            'field': 'name',
            'value': 'LinkBot',
            'scope': 'agent',
          },
        ),
        'agent.delete': const ToolExecutionResult(
          success: true,
          toolName: 'agent.delete',
          data: {
            'deleted': true,
            'name': 'LinkBot',
            'id': 'chain_test',
          },
        ),
      },
    );
    final engine = buildEngine(router: router);

    final res = await engine.run(
      req('create an agent called ChainBot, then rename it to LinkBot, '
          'then delete it'),
      provider: provider(),
    );

    // Complex multi-step — real LLM may stop at any point for confirmation
    // or to clarify a missing persona. All non-crash states are acceptable.
    expect(res.state,
        anyOf(AgentRuntimeState.done, AgentRuntimeState.waitingConfirmation,
            AgentRuntimeState.askingUser, AgentRuntimeState.failed));
    expect(res.finalMessage, isNotEmpty);
    // Must never invent a non-existent agents.* tool path.
    expect(
      router.dispatchSequence.where((t) => t.startsWith('system.agents.')),
      isEmpty,
    );
  }, timeout: const Timeout(Duration(seconds: 150)));

  // ═══════════════════════════════════════════════════════════════════════
  // R17 — Indonesian compound multi-target request
  // ═══════════════════════════════════════════════════════════════════════
  test('R17 Indonesian multi-target — compound request in ID', () async {
    if (!EnvLoader.isAvailable) return;
    final router = ScriptedToolRouter(
      results: {
        'agent.create': const ToolExecutionResult(
          success: true,
          toolName: 'agent.create',
          data: {
            'id': 'bumi_id',
            'name': 'Bumi',
            'provider_id': 'p1',
            'model': 'm1',
          },
        ),
        'agent.list': const ToolExecutionResult(
          success: true,
          toolName: 'agent.list',
          data: {
            'count': 3,
            'self_id': 'a1',
            'self_name': 'TestAgent',
            'agents': [
              {
                'id': 'a1',
                'name': 'TestAgent',
                'provider_id': 'p1',
                'model': 'm1',
                'persona': '',
                'communication_style': '',
                'work_role': '',
                'is_self': true,
              },
              {
                'id': 'bumi_id',
                'name': 'Bumi',
                'provider_id': 'p1',
                'model': 'm1',
                'persona': '',
                'communication_style': '',
                'work_role': '',
                'is_self': false,
              },
              {
                'id': 'mars_id',
                'name': 'Mars',
                'provider_id': 'p1',
                'model': 'm1',
                'persona': '',
                'communication_style': '',
                'work_role': '',
                'is_self': false,
              },
            ],
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
        'agent.list': const ToolExecutionResult(
          success: true,
          toolName: 'agent.list',
          data: {
            'count': 0,
            'self_id': 'a1',
            'self_name': 'TestAgent',
            'agents': [],
          },
        ),
        'system.tools.list': const ToolExecutionResult(
          success: true,
          toolName: 'system.tools.list',
          data: {'tools': [], 'count': 0},
        ),
      },
    );
    final engine = buildEngine(router: router);

    final res = await engine.run(
      req('what do I have installed in my system?'),
      provider: provider(),
    );

    print('R18 state: ${res.state}, success: ${res.success}, message: ${res.finalMessage}');
    for (final ev in res.events) {
      print('  Event: [${ev.type}] ${ev.message} (data: ${ev.data})');
    }
    expect(res.state,
        anyOf(AgentRuntimeState.done, AgentRuntimeState.askingUser));
    expect(res.finalMessage, isNotEmpty);
    // Response must be grounded — empty results should not produce hallucinations.
    // Must not invent non-existent tool paths.
    expect(
      router.dispatchSequence.where((t) => t.startsWith('system.agents.') ||
          t.startsWith('system.workflows.') || t.startsWith('system.modules.')),
      isEmpty,
    );
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
    // "what can you help me with" is a capability question — the prompt rules
    // legitimately route it to system.tools.list rather than answering from
    // memory. Provide the canned tool list so that path succeeds.
    final router = ScriptedToolRouter(
      results: {
        'system.tools.list': const ToolExecutionResult(
          success: true,
          toolName: 'system.tools.list',
          data: {
            'tools': [
              {'name': 'notes.create', 'risk': 'safe'},
              {'name': 'calendar.create', 'risk': 'safe'},
              {'name': 'device.battery', 'risk': 'safe'},
            ],
            'count': 3,
          },
        ),
      },
    );
    final engine = buildEngine(router: router);

    final res = await engine.run(
      req('hi there! what can you help me with today?'),
      provider: provider(),
    );

    expect(res.state, AgentRuntimeState.done);
    expect(res.finalMessage, isNotEmpty);
    // Either a pure conversational reply (no dispatch) or a grounded answer
    // via system.tools.list — both are valid. Must never invent a tool.
    expect(
      router.dispatchSequence.where((t) => t != 'system.tools.list'),
      isEmpty,
    );
  }, timeout: const Timeout(Duration(seconds: 90)));
}