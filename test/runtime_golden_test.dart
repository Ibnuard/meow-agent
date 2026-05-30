import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:meow_agent/features/providers/data/provider_config.dart';
import 'package:meow_agent/services/agent_runtime/context_builder.dart';
import 'package:meow_agent/services/agent_runtime/runtime_engine.dart';
import 'package:meow_agent/services/agent_runtime/runtime_models.dart';

import 'support/fake_workspace_loader.dart';
import 'support/scripted_llm_client.dart';
import 'support/scripted_tool_router.dart';

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
  }) => AgentRuntimeEngine(
    workspaceLoader: workspace ?? FakeWorkspaceLoader(),
    toolRouter: router,
    contextBuilder: ContextBuilder(),
    languageCode: 'en',
    llmClient: llm,
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
      'verbalize.answer_from_tool_result': ['Your battery is at 80%, not charging.'],
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
    final res = await buildEngine(llm: llm, router: router).run(
      req('what is my battery level'),
      provider: provider(),
    );

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
    final res = await buildEngine(llm: llm, router: router).run(
      req('open the example app'),
      provider: provider(),
    );

    expect(res.state, AgentRuntimeState.waitingConfirmation);
    expect(res.pendingTool, 'app.open');
    // Nothing executed before confirmation.
    expect(router.dispatchSequence, isEmpty);
    // Stage 2 safety valve: a sensitive intent still gets the reflection pass
    // (it is NOT skipped), so impact/slot analysis runs before any action.
    expect(llm.countOf('reflect'), 1);
  });

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
    final res = await buildEngine(llm: llm, router: router).run(
      req('schedule a meeting at 8'),
      provider: provider(),
    );

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
    final res = await buildEngine(llm: llm, router: router).run(
      req('send an sms to mom'),
      provider: provider(),
    );

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
    final res = await buildEngine(llm: llm, router: router).run(
      req('find my notes about unicorns'),
      provider: provider(),
    );

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
    final res = await buildEngine(llm: llm, router: router).run(
      req('make a note titled x'),
      provider: provider(),
    );

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
    final res = await buildEngine(llm: llm, router: router).run(
      req('create 3 notes A, B, C'),
      provider: provider(),
    );

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
  test('S11 two-tool single-subgoal flow does not short-circuit early',
      () async {
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
    final res = await buildEngine(llm: llm, router: router).run(
      req('open app settings'),
      provider: provider(),
    );

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
    final answerCall = llm.callLog
        .firstWhere((c) => c.phase == 'verbalize.answer_from_tool_result');
    expect(answerCall.lastUserContent, contains('(es)'));
    expect(res.finalMessage, 'Tu batería está al 80%.');
  });
}
