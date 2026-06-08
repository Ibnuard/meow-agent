import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:meow_agent/features/providers/data/provider_config.dart';
import 'package:meow_agent/services/agent_runtime/context_builder.dart';
import 'package:meow_agent/services/agent_runtime/goal_tree.dart';
import 'package:meow_agent/services/agent_runtime/runtime_engine.dart';
import 'package:meow_agent/services/agent_runtime/runtime_models.dart';
import 'package:meow_agent/services/agent_runtime/task_ledger.dart';
import 'package:meow_agent/services/agent_runtime/tool_permission_policy.dart';

import 'support/fake_workspace_loader.dart';
import 'support/scripted_llm_client.dart';
import 'support/scripted_tool_router.dart';

class PermissionDeniedRouter extends ScriptedToolRouter {
  PermissionDeniedRouter({
    required Map<String, ToolExecutionResult> deniedByTool,
  }) : _deniedByTool = deniedByTool,
       super(results: const {});

  final Map<String, ToolExecutionResult> _deniedByTool;

  @override
  Future<ToolExecutionResult?> permissionDeniedResult(String toolName) async {
    return _deniedByTool[toolName];
  }
}

/// Golden-scenario regression suite (Stage 0 safety net).
///
/// Each scenario scripts every LLM phase + tool result, runs the real engine,
/// and asserts: final state, success, the exact LLM phase sequence (the
/// orchestration-cost signal), the tool dispatch sequence, and that the final
/// message is grounded (no hallucinated facts).
///
/// BASELINE phase counts are recorded in comments per scenario as of the
/// pre-Stage-1 engine, so later stages can assert the expected reduction.
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
    FakeWorkspaceLoader? workspace,
    TaskLedgerDatabase? ledgerDb,
  }) => AgentRuntimeEngine(
    workspaceLoader: workspace ?? FakeWorkspaceLoader(),
    toolRouter: router,
    contextBuilder: ContextBuilder(),
    languageCode: 'en',
    llmClient: llm,
    ledgerDb: ledgerDb,
  );

  AgentRuntimeRequest req(String message, {String agentId = 'a1'}) =>
      AgentRuntimeRequest(
        agentId: agentId,
        agentName: 'TestAgent',
        userMessage: message,
      );

  // ── Scenario 1: simple read ────────────────────────────────────────────
  // BASELINE phases: [analyze, reflect, selectTool, review,
  //                   verbalize.answer_from_tool_result] = 5 calls.
  // Post-Stage-1 expectation: review call drops.
  test('S1 simple read — battery', () async {
    final llm = ScriptedLlmClient({
      'analyze': [
        '{"intent":"device.battery","goal":"check battery","requires_tools":true,'
            '"risk":"safe","tool_groups":["device"],"missing_info":[],'
            '"subgoal_seeds":["check battery"],'
            '"task_relation":"none","narrative":""}',
      ],
      'reflect': [
        '{"strategy":"direct_execute","goal_tree":{"main_goal":"check battery",'
            '"completion_criteria":["battery reported"],"subgoals":[{"id":"sg1",'
            '"label":"check battery","required_slots":{},"missing_slots":[],'
            '"status":"pending"}]},"narrative":""}',
      ],
      'plan': [
        '{"main_goal":"check battery","completion_criteria":["battery reported"],'
            '"subgoals":[{"id":"sg1","label":"check battery","required_slots":{},'
            '"missing_slots":[],"status":"pending"}],"narrative":""}',
      ],
      'selectTool': [
        '{"status":"tool_required","tool":{"name":"device.battery","args":{},'
            '"risk":"safe","requires_confirmation":false},"narrative":""}',
      ],
      'review': [
        '{"status":"done","final_response":"Battery is at 80%.",'
            '"subgoal_update":{"id":"sg1","status":"done"},"narrative":""}',
      ],
      'verbalize.answer_from_tool_result': [
        'Your battery is at 80%, not charging.',
      ],
      'verbalize.success': ['Done.'],
    });
    final router = ScriptedToolRouter(
      results: {
        'device.battery': const ToolExecutionResult(
          success: true,
          toolName: 'device.battery',
          data: {'level': 80, 'charging': false},
        ),
      },
    );
    final res = await buildEngine(
      llm: llm,
      router: router,
    ).run(req('what is my battery level'), provider: provider());

    expect(res.state, AgentRuntimeState.done);
    expect(res.success, true);
    expect(router.dispatchSequence, ['device.battery']);
    expect(res.finalMessage, contains('80%'));
    // Grounded: answer reflects canned data (not charging).
    expect(res.finalMessage.toLowerCase(), contains('not charging'));
    // POST-STAGE-2: a trivial, high-confidence, single safe-tool read skips
    // BOTH the redundant `review` (Stage 1) and the `reflect` (Stage 2) phases.
    // Simple read went 5 → 3 LLM calls. Destructive/multi-entity turns still
    // reflect (see S2, S5).
    expect(llm.phaseSequence, [
      'analyze',
      'selectTool',
      'verbalize.answer_from_tool_result',
    ]);
    expect(llm.countOf('review'), 0);
    expect(llm.countOf('reflect'), 0);
  });

  // ── Scenario 2: single sensitive tool + confirmation ───────────────────
  test('S2 sensitive tool parks for confirmation', () async {
    final llm = ScriptedLlmClient({
      'analyze': [
        '{"intent":"app.open","goal":"open app","requires_tools":true,'
            '"risk":"sensitive","missing_info":[],"subgoal_seeds":["open app"],'
            '"task_relation":"none","narrative":""}',
      ],
      'reflect': [
        '{"strategy":"direct_execute","goal_tree":{"main_goal":"open app",'
            '"completion_criteria":["app opened"],"subgoals":[{"id":"sg1",'
            '"label":"open app","required_slots":{},"missing_slots":[],'
            '"status":"pending"}]},"narrative":""}',
      ],
      'plan': [
        '{"main_goal":"open app","completion_criteria":["app opened"],'
            '"subgoals":[{"id":"sg1","label":"open app","required_slots":{},'
            '"missing_slots":[],"status":"pending"}],"narrative":""}',
      ],
      'selectTool': [
        '{"status":"tool_required","tool":{"name":"app.open",'
            '"args":{"package":"com.example"},"risk":"sensitive",'
            '"requires_confirmation":true},"narrative":""}',
      ],
      'verbalize.confirm': ['Open the app?'],
      'verbalize.preview': ['This would open the app.'],
    });
    final router = ScriptedToolRouter(
      results: {
        'app.open': const ToolExecutionResult(
          success: true,
          toolName: 'app.open',
          data: {'opened': true},
        ),
      },
    );
    final res = await buildEngine(
      llm: llm,
      router: router,
    ).run(req('open the example app'), provider: provider());

    expect(res.state, AgentRuntimeState.waitingConfirmation);
    expect(res.pendingTool, 'app.open');
    // Nothing executed before confirmation.
    expect(router.dispatchSequence, isEmpty);
    // Stage 2 safety valve: a sensitive intent still gets the reflection pass
    // (it is NOT skipped), so impact/slot analysis runs before any action.
    expect(llm.countOf('reflect'), 1);
  });

  test(
    'S2b resetAgentState clears pending confirmation and all ledgers',
    () async {
      final ledgerDb = TaskLedgerDatabase(overrideDbPath: inMemoryDatabasePath);
      addTearDown(ledgerDb.close);
      final llm = ScriptedLlmClient({
        'analyze': [
          '{"intent":"app.open","goal":"open app","requires_tools":true,'
              '"risk":"sensitive","missing_info":[],"subgoal_seeds":["open app"],'
              '"task_relation":"none","narrative":""}',
        ],
        'reflect': [
          '{"strategy":"direct_execute","goal_tree":{"main_goal":"open app",'
              '"completion_criteria":["app opened"],"subgoals":[{"id":"sg1",'
              '"label":"open app","required_slots":{},"missing_slots":[],'
              '"status":"pending"}]},"narrative":""}',
        ],
        'plan': [
          '{"main_goal":"open app","completion_criteria":["app opened"],'
              '"subgoals":[{"id":"sg1","label":"open app","required_slots":{},'
              '"missing_slots":[],"status":"pending"}],"narrative":""}',
        ],
        'selectTool': [
          '{"status":"tool_required","tool":{"name":"app.open",'
              '"args":{"package":"com.example"},"risk":"sensitive",'
              '"requires_confirmation":true},"narrative":""}',
        ],
        'verbalize.confirm': ['Open the app?'],
        'verbalize.preview': ['This would open the app.'],
      });
      final router = ScriptedToolRouter(results: const {});
      final engine = buildEngine(llm: llm, router: router, ledgerDb: ledgerDb);
      await ledgerDb.upsert(
        TaskLedger(
          id: 'stale_active',
          agentId: 'a1',
          source: LedgerSource.chat,
          mainGoal: 'old multi-step task',
          languageCode: 'en',
          originalUserMessage: 'old task',
          goalTree: GoalTree(
            mainGoal: 'old multi-step task',
            subgoals: [Subgoal(id: 'sg1', label: 'old step')],
          ),
        ),
      );
      final archived = TaskLedger(
        id: 'stale_archived',
        agentId: 'a1',
        source: LedgerSource.workflow,
        mainGoal: 'old archived task',
        languageCode: 'en',
        originalUserMessage: 'old workflow task',
        goalTree: GoalTree(
          mainGoal: 'old archived task',
          subgoals: [Subgoal(id: 'sg1', label: 'old workflow step')],
        ),
      );
      await ledgerDb.upsert(archived);
      await ledgerDb.archive('stale_archived', LedgerStatus.completed);

      final res = await engine.run(
        req('open the example app'),
        provider: provider(),
      );
      expect(res.state, AgentRuntimeState.waitingConfirmation);
      expect(engine.getPendingAction('a1'), isNotNull);

      await engine.resetAgentState('a1');

      expect(engine.getPendingAction('a1'), isNull);
      expect(await ledgerDb.findById('stale_active'), isNull);
      expect(await ledgerDb.findById('stale_archived'), isNull);
    },
  );

  // ── Scenario 3: ambiguous → clarify ────────────────────────────────────
  test('S3 ambiguous request asks a clarifying question', () async {
    final llm = ScriptedLlmClient({
      'analyze': [
        '{"intent":"calendar.create","goal":"schedule something",'
            '"requires_tools":false,"risk":"safe",'
            '"missing_info":["8 AM or 8 PM?"],"subgoal_seeds":[],'
            '"task_relation":"none","narrative":""}',
      ],
    });
    final router = ScriptedToolRouter(results: const {});
    final res = await buildEngine(
      llm: llm,
      router: router,
    ).run(req('schedule a meeting at 8'), provider: provider());

    expect(res.state, AgentRuntimeState.askingUser);
    expect(res.finalMessage, contains('8'));
    expect(router.dispatchSequence, isEmpty);
    expect(llm.phaseSequence, ['analyze']);
  });

  // ── Scenario 4: no capability → honest refusal ─────────────────────────
  // analyzer says tools required, but the selector can find no suitable tool.
  test('S4 no-capability fails honestly without fabricating success', () async {
    final llm = ScriptedLlmClient({
      'analyze': [
        '{"intent":"sms.send","goal":"send an SMS","requires_tools":true,'
            '"risk":"safe","missing_info":[],"subgoal_seeds":["send sms"],'
            '"task_relation":"none","narrative":""}',
      ],
      'reflect': [
        '{"strategy":"direct_execute","goal_tree":{"main_goal":"send sms",'
            '"completion_criteria":["sms sent"],"subgoals":[{"id":"sg1",'
            '"label":"send sms","required_slots":{},"missing_slots":[],'
            '"status":"pending"}]},"narrative":""}',
      ],
      'plan': [
        '{"main_goal":"send sms","completion_criteria":["sms sent"],'
            '"subgoals":[{"id":"sg1","label":"send sms","required_slots":{},'
            '"missing_slots":[],"status":"pending"}],"narrative":""}',
      ],
      // Selector cannot find a tool → returns failed (no capability).
      'selectTool': [
        '{"status":"failed","error":"No tool can send SMS.","narrative":""}',
        '{"status":"failed","error":"No tool can send SMS.","narrative":""}',
      ],
      'verbalize.abort': ['I can\'t send SMS — there\'s no tool for that.'],
    });
    final router = ScriptedToolRouter(results: const {});
    final res = await buildEngine(
      llm: llm,
      router: router,
    ).run(req('send an sms to mom'), provider: provider());

    expect(res.success, false);
    expect(res.state, AgentRuntimeState.failed);
    expect(router.dispatchSequence, isEmpty);
  });

  // ── Scenario 8: empty-result is the answer, no retry loop ──────────────
  test('S8 empty search result finalizes honestly, no retry loop', () async {
    final llm = ScriptedLlmClient({
      'analyze': [
        '{"intent":"notes.search","goal":"find notes","requires_tools":true,'
            '"risk":"safe","missing_info":[],"subgoal_seeds":["search notes"],'
            '"task_relation":"none","narrative":""}',
      ],
      'reflect': [
        '{"strategy":"direct_execute","goal_tree":{"main_goal":"find notes",'
            '"completion_criteria":["search done"],"subgoals":[{"id":"sg1",'
            '"label":"search notes","required_slots":{},"missing_slots":[],'
            '"status":"pending"}]},"narrative":""}',
      ],
      'plan': [
        '{"main_goal":"find notes","completion_criteria":["search done"],'
            '"subgoals":[{"id":"sg1","label":"search notes","required_slots":{},'
            '"missing_slots":[],"status":"pending"}],"narrative":""}',
      ],
      'selectTool': [
        '{"status":"tool_required","tool":{"name":"notes.search",'
            '"args":{"query":"unicorn"},"risk":"safe",'
            '"requires_confirmation":false},"narrative":""}',
      ],
      // Reviewer recognizes the empty result completes the subgoal.
      'review': [
        '{"status":"done","final_response":"No notes match that.",'
            '"subgoal_update":{"id":"sg1","status":"done"},"narrative":""}',
      ],
      'verbalize.answer_from_tool_result': ['No notes match that.'],
      'verbalize.success': ['No matches found.'],
    });
    final router = ScriptedToolRouter(
      results: {
        'notes.search': const ToolExecutionResult(
          success: true,
          toolName: 'notes.search',
          data: {'count': 0, 'results': []},
        ),
      },
    );
    final res = await buildEngine(
      llm: llm,
      router: router,
    ).run(req('find my notes about unicorns'), provider: provider());

    expect(res.success, true);
    expect(res.state, AgentRuntimeState.done);
    // The search tool ran exactly once — no retry loop on empty results.
    expect(router.dispatchCountOf('notes.search'), 1);
  });

  // ── Scenario 9: failed tool → honest failure, not claimed done ─────────
  // The reviewer returns `failed`; the engine attempts ONE recovery rethink
  // (re-reflect + re-plan + re-loop), the retry fails again, recovery is
  // exhausted, and the run ends as a failure — never a fabricated success.
  test('S9 failed tool is reported as failure', () async {
    final llm = ScriptedLlmClient({
      'analyze': [
        '{"intent":"notes.create","goal":"create note","requires_tools":true,'
            '"risk":"safe","missing_info":[],"subgoal_seeds":["create note"],'
            '"task_relation":"none","narrative":""}',
      ],
      'reflect': [
        '{"strategy":"direct_execute","goal_tree":{"main_goal":"create note",'
            '"completion_criteria":["note created"],"subgoals":[{"id":"sg1",'
            '"label":"create note","required_slots":{},"missing_slots":[],'
            '"status":"pending"}]},"narrative":""}',
        // recovery re-reflect
        '{"strategy":"direct_execute","goal_tree":{"main_goal":"create note",'
            '"completion_criteria":["note created"],"subgoals":[{"id":"sg1",'
            '"label":"create note","required_slots":{},"missing_slots":[],'
            '"status":"pending"}]},"narrative":""}',
      ],
      'plan': [
        '{"main_goal":"create note","completion_criteria":["note created"],'
            '"subgoals":[{"id":"sg1","label":"create note","required_slots":{},'
            '"missing_slots":[],"status":"pending"}],"narrative":""}',
        // recovery re-plan
        '{"main_goal":"create note","completion_criteria":["note created"],'
            '"subgoals":[{"id":"sg1","label":"create note","required_slots":{},'
            '"missing_slots":[],"status":"pending"}],"narrative":""}',
      ],
      'selectTool': [
        '{"status":"tool_required","tool":{"name":"notes.create",'
            '"args":{"title":"x","body":"y"},"risk":"safe",'
            '"requires_confirmation":false},"narrative":""}',
        // recovery loop re-selects the same tool
        '{"status":"tool_required","tool":{"name":"notes.create",'
            '"args":{"title":"x","body":"y"},"risk":"safe",'
            '"requires_confirmation":false},"narrative":""}',
      ],
      'review': [
        '{"status":"failed","error":"storage full",'
            '"subgoal_update":{"id":"sg1","status":"failed"},"narrative":""}',
        '{"status":"failed","error":"storage full",'
            '"subgoal_update":{"id":"sg1","status":"failed"},"narrative":""}',
      ],
      'verbalize.abort': ['Could not save the note — storage is full.'],
    });
    final router = ScriptedToolRouter(
      results: {
        'notes.create': const ToolExecutionResult(
          success: false,
          toolName: 'notes.create',
          error: 'storage full',
        ),
      },
    );
    final res = await buildEngine(
      llm: llm,
      router: router,
    ).run(req('make a note titled x'), provider: provider());

    expect(res.success, false);
    expect(res.finalMessage.toLowerCase(), isNot(contains('created')));
  });

  // ── Scenario 5: multi-target create (guards "→1 agen" regression) ──────
  // Uses notes.create (safe, no confirmation) so the loop runs all subgoals.
  test('S5 multi-target create runs every subgoal', () async {
    final llm = ScriptedLlmClient({
      'analyze': [
        '{"intent":"notes.create","goal":"create 3 notes","requires_tools":true,'
            '"risk":"safe","missing_info":[],'
            '"subgoal_seeds":["create note A","create note B","create note C"],'
            '"task_relation":"none","narrative":""}',
      ],
      'reflect': [
        '{"strategy":"direct_execute","goal_tree":{"main_goal":"create 3 notes",'
            '"completion_criteria":["3 notes exist"],"subgoals":['
            '{"id":"sg1","label":"create note A","required_slots":{},"missing_slots":[],"status":"pending"},'
            '{"id":"sg2","label":"create note B","required_slots":{},"missing_slots":[],"status":"pending"},'
            '{"id":"sg3","label":"create note C","required_slots":{},"missing_slots":[],"status":"pending"}]},'
            '"narrative":""}',
      ],
      'plan': [
        '{"main_goal":"create 3 notes","completion_criteria":["3 notes exist"],'
            '"subgoals":['
            '{"id":"sg1","label":"create note A","required_slots":{},"missing_slots":[],"status":"pending"},'
            '{"id":"sg2","label":"create note B","required_slots":{},"missing_slots":[],"status":"pending"},'
            '{"id":"sg3","label":"create note C","required_slots":{},"missing_slots":[],"status":"pending"}],'
            '"narrative":""}',
      ],
      'selectTool': [
        '{"status":"tool_required","tool":{"name":"notes.create","args":{"title":"A","body":"A"},"risk":"safe","requires_confirmation":false},"narrative":""}',
        '{"status":"tool_required","tool":{"name":"notes.create","args":{"title":"B","body":"B"},"risk":"safe","requires_confirmation":false},"narrative":""}',
        '{"status":"tool_required","tool":{"name":"notes.create","args":{"title":"C","body":"C"},"risk":"safe","requires_confirmation":false},"narrative":""}',
      ],
      'review': [
        '{"status":"continue","reason":"more notes","subgoal_update":{"id":"sg1","status":"done"},"narrative":""}',
        '{"status":"continue","reason":"more notes","subgoal_update":{"id":"sg2","status":"done"},"narrative":""}',
        '{"status":"done","final_response":"Created all three notes.","subgoal_update":{"id":"sg3","status":"done"},"narrative":""}',
      ],
      'verbalize.success': ['Created all three notes.'],
      'verbalize.task_summary': ['Created notes A, B, and C.'],
      'verbalize.answer_from_tool_result': ['Created notes A, B, and C.'],
    });
    final router = ScriptedToolRouter(
      results: {
        'notes.create': const ToolExecutionResult(
          success: true,
          toolName: 'notes.create',
          data: {'noteId': 'note_1', 'created': true},
        ),
      },
    );
    final res = await buildEngine(
      llm: llm,
      router: router,
    ).run(req('create 3 notes A, B, C'), provider: provider());

    expect(res.success, true);
    expect(res.state, AgentRuntimeState.done);
    // The regression guard: all three creates must run.
    expect(router.dispatchCountOf('notes.create'), 3);
  });

  // ── Scenario 11: Stage-1 scoping guard ─────────────────────────────────
  // A single-subgoal flow that needs TWO non-retrieval tools. The first tool
  // (app.resolve) is NOT a retrieval tool, so the early-completion
  // short-circuit must NOT fire after it; the loop must continue and reach the
  // second tool. (Guards against the over-broad "any last successful tool
  // completes the tree" variant that would have stopped after the first tool.)
  // Both tools are safe + no-confirmation so the run stays inside the loop.
  test('S11 two-tool single-subgoal flow does not short-circuit early', () async {
    final llm = ScriptedLlmClient({
      'analyze': [
        '{"intent":"app.resolve","goal":"resolve then open settings",'
            '"requires_tools":true,"risk":"safe","missing_info":[],'
            '"subgoal_seeds":["open app settings"],"task_relation":"none","narrative":""}',
      ],
      'reflect': [
        '{"strategy":"direct_execute","goal_tree":{"main_goal":"open app settings",'
            '"completion_criteria":["settings opened"],"subgoals":[{"id":"sg1",'
            '"label":"open app settings","required_slots":{},"missing_slots":[],'
            '"status":"pending"}]},"narrative":""}',
      ],
      'plan': [
        '{"main_goal":"open app settings","completion_criteria":["settings opened"],'
            '"subgoals":[{"id":"sg1","label":"open app settings","required_slots":{},'
            '"missing_slots":[],"status":"pending"}],"narrative":""}',
      ],
      'selectTool': [
        // First: resolve the friendly name (safe, NOT retrieval).
        '{"status":"tool_required","tool":{"name":"app.resolve",'
            '"args":{"query":"whatsapp"},"risk":"safe",'
            '"requires_confirmation":false},"narrative":""}',
        // After review continues, pick a second safe non-retrieval tool.
        '{"status":"tool_required","tool":{"name":"settings.open",'
            '"args":{"action":"android.settings.SETTINGS"},"risk":"safe",'
            '"requires_confirmation":false},"narrative":""}',
      ],
      'review': [
        '{"status":"continue","reason":"now open settings",'
            '"subgoal_update":{"id":"sg1","status":"in_progress"},"narrative":""}',
        '{"status":"done","final_response":"Opened settings.",'
            '"subgoal_update":{"id":"sg1","status":"done"},"narrative":""}',
      ],
      'verbalize.success': ['Opened settings.'],
    });
    final router = ScriptedToolRouter(
      results: {
        'app.resolve': const ToolExecutionResult(
          success: true,
          toolName: 'app.resolve',
          data: {'package': 'com.whatsapp', 'confidence': 0.95},
        ),
        'settings.open': const ToolExecutionResult(
          success: true,
          toolName: 'settings.open',
          data: {'opened': true},
        ),
      },
    );
    final res = await buildEngine(
      llm: llm,
      router: router,
    ).run(req('open app settings'), provider: provider());

    expect(res.success, true);
    expect(res.state, AgentRuntimeState.done);
    // The guard: BOTH tools ran — resolve did not short-circuit the task.
    expect(router.dispatchSequence, ['app.resolve', 'settings.open']);
  });

  // ── Scenario 10: analyzer-driven language refinement ───────────────────
  // A Latin-script, non-EN/non-ID message (Spanish). The bootstrap detector
  // can't tell Latin languages apart and falls back to the app code ('en');
  // the analyzer reports detected_language="es", and the runtime refines the
  // turn language so the final answer is produced in Spanish. Proves the
  // engine is language-generic without per-language word lists.
  // ── Scenario 12: bulk predicate delete ─────────────────────────────────
  // "delete all notes with 'draft' in the title" — the analyzer emits
  // bulk_selector:true; the reflection target carries a predicate selector;
  // the tool dispatches once per matched entity (2 drafts).
  test('S12 bulk predicate delete — delete all notes matching a pattern', () async {
    final llm = ScriptedLlmClient({
      'analyze': [
        '{"intent":"notes.delete","goal":"delete notes with draft in title",'
            '"requires_tools":true,"risk":"sensitive","tool_groups":["notes"],'
            '"missing_info":[],"bulk_selector":true,'
            '"subgoal_seeds":["delete draft notes"],'
            '"task_relation":"none","narrative":""}',
      ],
      'reflect': [
        '{"strategy":"direct_execute","goal_tree":{"main_goal":"delete draft notes",'
            '"completion_criteria":["draft notes deleted"],"subgoals":[{"id":"sg1",'
            '"label":"delete draft notes","required_slots":{},"missing_slots":[],'
            '"status":"pending"}]},"targets":[{"subgoal_id":"sg1","operation":"delete",'
            '"entity_type":"note","selector":{"scope":"predicate","field":"title",'
            '"op":"contains","value":"draft","case_sensitive":false}}],"narrative":""}',
      ],
      'plan': [
        '{"main_goal":"delete draft notes","completion_criteria":["draft notes deleted"],'
            '"subgoals":[{"id":"sg1","label":"delete draft notes","required_slots":{},'
            '"missing_slots":[],"status":"pending"}],"narrative":""}',
      ],
      'selectTool': [
        '{"status":"tool_required","tool":{"name":"notes.delete",'
            '"args":{"scope":"predicate","field":"title","op":"contains","value":"draft"},'
            '"risk":"sensitive","requires_confirmation":true},"narrative":""}',
      ],
      'verbalize.confirm': ['Delete 2 notes matching "draft" in title?'],
      'verbalize.preview': ['Would delete: draft1.md, draft2.md'],
    });
    final router = ScriptedToolRouter(
      results: {
        'notes.delete': const ToolExecutionResult(
          success: true,
          toolName: 'notes.delete',
          data: {
            'deleted': 2,
            'matched': ['draft1.md', 'draft2.md'],
          },
        ),
      },
    );
    final res = await buildEngine(llm: llm, router: router).run(
      req('delete all notes with draft in the title'),
      provider: provider(),
    );

    // Bulk delete with two drafts → parks for confirmation (sensitive tool).
    expect(res.state, AgentRuntimeState.waitingConfirmation);
    expect(res.pendingTool, 'notes.delete');
    expect(res.finalMessage, contains('Delete'));
    expect(router.dispatchSequence, isEmpty);
  });

  // ── Scenario 13: impact analysis on deletion ───────────────────────────
  // Deleting agent "Coder" that is used by workflow "Code Review" — the
  // reflector surfaces impact and either auto_resolves or asks.
  test('S13 impact analysis — deleting agent used by a workflow', () async {
    final llm = ScriptedLlmClient({
      'analyze': [
        '{"intent":"system.agents.delete","goal":"delete agent Coder",'
            '"requires_tools":true,"risk":"sensitive","tool_groups":["system"],'
            '"missing_info":[],"subgoal_seeds":["delete Coder"],'
            '"task_relation":"none","narrative":""}',
      ],
      'reflect': [
        '{"strategy":"auto_resolve","goal_tree":{"main_goal":"delete Coder",'
            '"completion_criteria":["Coder deleted"],"subgoals":[{"id":"sg1",'
            '"label":"delete Coder","required_slots":{},"missing_slots":[],'
            '"status":"pending"}]},'
            '"impacts":[{"entity_type":"workflow","entity_id":"wf_cr",'
            '"entity_label":"Code Review","relation":"uses agent Coder",'
            '"severity":"high","auto_resolvable":true,'
            '"resolution_hint":"reassign to Writer"}],'
            '"narrative":""}',
      ],
      'plan': [
        '{"main_goal":"delete Coder","completion_criteria":["Coder deleted"],'
            '"subgoals":[{"id":"sg1","label":"delete Coder","required_slots":{},'
            '"missing_slots":[],"status":"pending"}],"narrative":""}',
      ],
      'selectTool': [
        '{"status":"tool_required","tool":{"name":"system.agents.delete",'
            '"args":{"name":"Coder"},"risk":"sensitive",'
            '"requires_confirmation":true},"narrative":""}',
      ],
      'verbalize.confirm': [
        'Delete agent Coder? This will affect the Code Review workflow.',
      ],
      'verbalize.preview': [
        'Coder is used by Code Review workflow. It will need a new agent.',
      ],
    });
    final router = ScriptedToolRouter(
      results: {
        'system.agents.delete': const ToolExecutionResult(
          success: true,
          toolName: 'system.agents.delete',
          data: {'agentId': 'coder_id', 'deleted': true},
        ),
      },
    );
    final res = await buildEngine(
      llm: llm,
      router: router,
    ).run(req('delete agent Coder'), provider: provider());

    expect(res.state, AgentRuntimeState.waitingConfirmation);
    expect(res.pendingTool, 'system.agents.delete');
    expect(res.finalMessage.toLowerCase(), contains('workflow'));
    expect(llm.countOf('reflect'), 1);
  });

  // ── Scenario 16: retrieval terminal short-circuit ──────────────────────
  // system.agents.list is a retrieval tool — the engine skips review phase
  // and goes directly to answer_from_tool_result verbalization.
  test('S16 retrieval tool short-circuits review', () async {
    final llm = ScriptedLlmClient({
      'analyze': [
        '{"intent":"system.agents.list","goal":"list agents",'
            '"requires_tools":true,"risk":"safe","tool_groups":["system"],'
            '"missing_info":[],"subgoal_seeds":["list agents"],'
            '"task_relation":"none","narrative":""}',
      ],
      // system + single group + safe → reflect skipped.
      'selectTool': [
        '{"status":"tool_required","tool":{"name":"system.agents.list",'
            '"args":{},"risk":"safe","requires_confirmation":false},'
            '"narrative":""}',
      ],
      'verbalize.answer_from_tool_result': [
        'You have 2 agents: Mina Chan (assistant) and Kai (productivity).',
      ],
      'verbalize.success': ['Listed.'],
    });
    final router = ScriptedToolRouter(
      results: {
        'system.agents.list': const ToolExecutionResult(
          success: true,
          toolName: 'system.agents.list',
          data: {
            'agents': [
              {'id': 'a1', 'name': 'Mina Chan', 'role': 'assistant'},
              {'id': 'a2', 'name': 'Kai', 'role': 'productivity'},
            ],
            'count': 2,
          },
        ),
      },
    );
    final res = await buildEngine(
      llm: llm,
      router: router,
    ).run(req('what agents do I have?'), provider: provider());

    expect(res.success, true);
    expect(res.state, AgentRuntimeState.done);
    // Retrieval tool: answer must be grounded in canned data.
    expect(res.finalMessage, contains('Mina'));
    expect(res.finalMessage, contains('Kai'));
    expect(router.dispatchCountOf('system.agents.list'), 1);
    // Review phase was skipped (retrieval terminal short-circuit).
    expect(llm.countOf('review'), 0);
  });

  test('S17 capability list is grounded in registered tools', () async {
    final llm = ScriptedLlmClient({
      'analyze': [
        '{"intent":"system.tools.list","goal":"list current capabilities",'
            '"requires_tools":true,"risk":"safe","tool_groups":["system"],'
            '"missing_info":[],"subgoal_seeds":["list tools"],'
            '"task_relation":"none","narrative":""}',
      ],
      'selectTool': [
        '{"status":"tool_required","tool":{"name":"system.tools.list",'
            '"args":{},"risk":"safe","requires_confirmation":false},'
            '"narrative":""}',
      ],
      'verbalize.answer_from_tool_result': [
        'Aku bisa membuka aplikasi, membaca status baterai, dan mengelola catatan. Aku belum punya tool kontrol media.',
      ],
    });
    final router = ScriptedToolRouter(
      results: {
        'system.tools.list': const ToolExecutionResult(
          success: true,
          toolName: 'system.tools.list',
          data: {
            'count': 3,
            'availableCount': 3,
            'tools': [
              {
                'name': 'app.resolve',
                'description': 'Resolve a friendly app name.',
                'available': true,
              },
              {
                'name': 'device.battery',
                'description': 'Read current battery level.',
                'available': true,
              },
              {
                'name': 'notes.create',
                'description': 'Create a note.',
                'available': true,
              },
            ],
          },
        ),
      },
    );
    final res = await buildEngine(
      llm: llm,
      router: router,
    ).run(req('sebagai agent kamu bisa ngapain aja?'), provider: provider());

    expect(res.success, true);
    expect(res.state, AgentRuntimeState.done);
    expect(router.dispatchSequence, ['system.tools.list']);
    expect(
      res.finalMessage.toLowerCase(),
      contains('belum punya tool kontrol media'),
    );
  });

  test(
    'S18 unavailable capability cannot turn into follow-up question',
    () async {
      final llm = ScriptedLlmClient({
        'analyze': [
          '{"intent":"media.play","goal":"play a song","requires_tools":true,'
              '"risk":"safe","tool_groups":["app"],"missing_info":[],'
              '"subgoal_seeds":["play song"],"task_relation":"none",'
              '"narrative":""}',
        ],
        'selectTool': [
          '{"status":"tool_required","tool":{"name":"app.resolve",'
              '"args":{"query":"music player"},"risk":"safe",'
              '"requires_confirmation":false},"narrative":""}',
        ],
        'review': [
          '{"status":"ask_user","question":"Lagu apa yang mau diputar?",'
              '"subgoal_update":{"id":"sg1","status":"in_progress"},'
              '"narrative":"Maaf, ternyata aku belum bisa mengontrol media."}',
        ],
      });
      final router = ScriptedToolRouter(
        results: {
          'app.resolve': const ToolExecutionResult(
            success: false,
            toolName: 'app.resolve',
            error: 'media control unavailable: no tool can play songs',
          ),
        },
      );
      final res = await buildEngine(
        llm: llm,
        router: router,
      ).run(req('coba play lagu katanya bisa'), provider: provider());

      expect(res.success, false);
      expect(res.state, AgentRuntimeState.failed);
      expect(res.finalMessage.toLowerCase(), isNot(contains('lagu apa')));
      expect(router.dispatchSequence, ['app.resolve']);
    },
  );

  test('S19 missing ecosystem module returns an install action', () async {
    final llm = ScriptedLlmClient({
      'analyze': [
        '{"intent":"app.resolve","goal":"find YouTube","requires_tools":true,'
            '"risk":"safe","tool_groups":["app"],"missing_info":[],'
            '"subgoal_seeds":["find YouTube"],'
            '"task_relation":"none","narrative":""}',
      ],
      'selectTool': [
        '{"status":"tool_required","tool":{"name":"app.resolve",'
            '"args":{"query":"youtube"},"risk":"safe",'
            '"requires_confirmation":false},"narrative":""}',
      ],
    });
    final router = PermissionDeniedRouter(
      deniedByTool: {
        'app.resolve': const ToolExecutionResult(
          success: false,
          toolName: 'app.resolve',
          data: {
            'errorCode': ToolPermissionPolicy.permissionDeniedCode,
            'reason': 'moduleMissing',
            'moduleId': 'device_context',
            'moduleName': 'Device Context',
            'actionLabel': 'find installed apps',
          },
          error: 'module_permission_denied: moduleMissing',
        ),
      },
    );

    final res = await buildEngine(
      llm: llm,
      router: router,
    ).run(req('open youtube'), provider: provider());

    expect(res.success, false);
    expect(res.state, AgentRuntimeState.failed);
    expect(res.finalMessage, contains('not installed'));
    expect(res.finalMessage, isNot(contains('{setting}')));
    expect(res.actions, hasLength(1));
    expect(res.actions.single.type, 'install_module');
    expect(res.actions.single.target, 'device_context');
    expect(res.actions.single.label, 'Install Device Context');
    expect(router.dispatchSequence, isEmpty);
  });

  test('S20 disabled ecosystem setting returns an open-module action', () async {
    final llm = ScriptedLlmClient({
      'analyze': [
        '{"intent":"clipboard.read","goal":"read clipboard","requires_tools":true,'
            '"risk":"safe","tool_groups":["clipboard"],"missing_info":[],'
            '"subgoal_seeds":["read clipboard"],'
            '"task_relation":"none","narrative":""}',
      ],
      'selectTool': [
        '{"status":"tool_required","tool":{"name":"clipboard.read",'
            '"args":{},"risk":"safe","requires_confirmation":false},'
            '"narrative":""}',
      ],
    });
    final router = PermissionDeniedRouter(
      deniedByTool: {
        'clipboard.read': const ToolExecutionResult(
          success: false,
          toolName: 'clipboard.read',
          data: {
            'errorCode': ToolPermissionPolicy.permissionDeniedCode,
            'reason': 'settingDisabled',
            'moduleId': 'device_context',
            'moduleName': 'Device Context',
            'settingLabel': 'Read Clipboard',
            'actionLabel': 'read the clipboard',
          },
          error: 'module_permission_denied: settingDisabled',
        ),
      },
    );

    final res = await buildEngine(
      llm: llm,
      router: router,
    ).run(req('read my clipboard'), provider: provider());

    expect(res.success, false);
    expect(res.state, AgentRuntimeState.failed);
    expect(res.finalMessage, contains('Read Clipboard'));
    expect(res.finalMessage, isNot(contains('{setting}')));
    expect(res.actions, hasLength(1));
    expect(res.actions.single.type, 'navigate');
    expect(res.actions.single.target, '/modules/device_context');
    expect(res.actions.single.label, 'Open Device Context');
    expect(router.dispatchSequence, isEmpty);
  });

  test('S10 analyzer detected_language refines the reply language', () async {
    final llm = ScriptedLlmClient({
      'analyze': [
        '{"intent":"device.battery","goal":"check battery","requires_tools":true,'
            '"risk":"safe","detected_language":"es","tool_groups":["device"],'
            '"missing_info":[],"subgoal_seeds":["check battery"],'
            '"task_relation":"none","narrative":""}',
      ],
      // device + single group + safe + empty snapshot → reflect skipped.
      'selectTool': [
        '{"status":"tool_required","tool":{"name":"device.battery","args":{},'
            '"risk":"safe","requires_confirmation":false},"narrative":""}',
      ],
      'verbalize.answer_from_tool_result': ['Tu batería está al 80%.'],
      'verbalize.success': ['Listo.'],
    });
    final router = ScriptedToolRouter(
      results: {
        'device.battery': const ToolExecutionResult(
          success: true,
          toolName: 'device.battery',
          data: {'level': 80, 'charging': false},
        ),
      },
    );

    final res = await buildEngine(llm: llm, router: router).run(
      // App fallback is 'en' (engine languageCode), message is Spanish.
      req('¿cuánta batería me queda?'),
      provider: provider(),
    );

    expect(res.success, true);
    expect(res.state, AgentRuntimeState.done);
    // Verify the REFINED language ('es') actually propagated to the verbalizer
    // — its prompt embeds the language code. This proves the analyzer's
    // detected_language overrode the 'en' bootstrap fallback, not just that a
    // Spanish string happened to be returned.
    final answerCall = llm.callLog.firstWhere(
      (c) => c.phase == 'verbalize.answer_from_tool_result',
    );
    expect(answerCall.lastUserContent, contains('(es)'));
    expect(res.finalMessage, 'Tu batería está al 80%.');
  });
}
