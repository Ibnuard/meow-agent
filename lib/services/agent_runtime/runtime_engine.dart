import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/modules/data/module_repository.dart';
import '../../features/agents/data/agent_repository.dart';
import '../../features/settings/data/app_language_provider.dart';
import '../../features/providers/data/provider_config.dart';
import '../../features/providers/data/provider_repository.dart';
import '../../features/settings/data/llm_provider_config.dart';
import '../llm/openai_compatible_client.dart';
import 'context_builder.dart';
import 'ecosystem_snapshot.dart';
import 'executor.dart';
import 'goal_tree.dart';
import 'language_detector.dart';
import 'pending_action.dart';
import 'pending_clarification.dart';
import 'planner.dart';
import 'prompt_constants.dart';
import 'reflector.dart';
import 'runtime_logger.dart';
import 'runtime_memory.dart';
import 'runtime_models.dart';
import 'snapshot_target_resolver.dart';
import 'target_resolution.dart';
import 'target_reference_utils.dart';
import 'task_ledger.dart';
import 'tool_catalog.dart';
import 'tool_permission_policy.dart';
import 'tool_router.dart';
import 'tool_verbalizer.dart';
import 'workspace_loader.dart';
import '../../features/agents/data/agent_model.dart';
import '../../features/modules/workflows/workflow_repository.dart';

/// Callback for real-time event streaming.
typedef RuntimeEventCallback = void Function(RuntimeEvent event);

/// The main agentic runtime engine.
/// Stateful: maintains pending actions per agent.
class AgentRuntimeEngine {
  AgentRuntimeEngine({
    required this.workspaceLoader,
    required this.toolRouter,
    required this.contextBuilder,
    required this.languageCode,
    this.snapshotBuilder,
    this.agentLoader,
    TaskLedgerDatabase? ledgerDb,
  }) : ledgerDb = ledgerDb ?? TaskLedgerDatabase();

  final WorkspaceLoader workspaceLoader;
  final ToolRouter toolRouter;
  final ContextBuilder contextBuilder;
  final String languageCode;

  /// Optional ecosystem snapshot builder. When null, reflection runs without
  /// snapshot context (still useful for slot extraction).
  final EcosystemSnapshotBuilder? snapshotBuilder;

  /// Loader for the current agent registry. Optional — reflection still works
  /// without it but loses cross-reference detection.
  final List<AgentModel> Function()? agentLoader;

  /// Persistent ledger store for multi-step tasks. Single-target work keeps
  /// using [PendingAction] in-memory; multi-target work creates a ledger
  /// row that survives app restarts and confirmation gates.
  final TaskLedgerDatabase ledgerDb;

  /// Shared LLM client. Reused across all turns of this engine instance so
  /// the underlying Dio's connection pool can keep keep-alive sockets warm.
  final OpenAiCompatibleClient _client = OpenAiCompatibleClient();

  static const int maxSteps = 5;

  /// System-level behavior rules for direct (no-tool) responses.
  /// Always enforced regardless of SOUL.md content. Output language follows
  /// the **detected** language of the current turn, not a global setting.
  String _directResponseRulesFor({
    required String languageLabel,
    bool isWorkflowAutoExecute = false,
    bool userNotIntroduced = false,
  }) {
    final base = PromptConstants.systemRules(
      languageLabel,
      isWorkflowAutoExecute: isWorkflowAutoExecute,
    );
    if (!userNotIntroduced || isWorkflowAutoExecute) return base;
    return '$base\n\n${PromptConstants.introductionGateRule}';
  }

  /// Pending actions per agent (agentId → PendingAction).
  final Map<String, PendingAction> _pendingActions = {};

  /// Pending clarification per agent.
  /// Used when analyzer asked missing-info questions. The next user message is
  /// merged with the original request before analysis.
  final Map<String, PendingClarification> _pendingClarifications = {};

  /// Per-agent scratchpad: remembers recent tool calls + structured results.
  /// Persists across turns so the planner can reference prior tool output
  /// (e.g. noteId from notes.search when user later says "hapus yang itu").
  final RuntimeMemory _memory = RuntimeMemory();

  /// Per-turn user-message language detector. Drives every user-facing string.
  final LanguageDetector _languageDetector = LanguageDetector();

  /// Build a [DetectedLanguage] for the engine's fallback code.
  /// Used when the engine has no real user message (e.g. executeConfirmed).
  DetectedLanguage _fallbackLanguage() => DetectedLanguage(
    code: languageCode,
    label: LanguageDetector.labelForCode(languageCode),
    script: 'Latin',
    confidence: 0.4,
  );

  /// Get pending action for an agent.
  PendingAction? getPendingAction(String agentId) => _pendingActions[agentId];

  /// Clear pending action for an agent.
  void clearPendingAction(String agentId) => _pendingActions.remove(agentId);

  /// Clear pending clarification for an agent.
  void clearPendingClarification(String agentId) =>
      _pendingClarifications.remove(agentId);

  /// Abort the current chat task scope for an agent.
  ///
  /// Used by the UI reject path: clearing the visible confirmation is not
  /// enough, because a persisted ledger can otherwise rehydrate the same
  /// pending tool on the next user turn.
  Future<void> abortActiveTask(
    String agentId, {
    RequestSource source = RequestSource.chat,
  }) async {
    await _finishTaskScope(
      agentId: agentId,
      source: source,
      terminal: LedgerStatus.aborted,
    );
  }

  /// Run the full agentic loop for a request.
  ///
  /// [autoApproveSensitive] bypasses the confirmation gate for tools that
  /// would normally require user approval. Used by workflows with the
  /// "Allow Sensitive Actions" flag enabled.
  Future<AgentRuntimeResponse> run(
    AgentRuntimeRequest request, {
    required ProviderConfig provider,
    RuntimeEventCallback? onEvent,
    bool autoApproveSensitive = false,
  }) async {
    final logger = RuntimeLogger();

    void emit(RuntimeEvent event) {
      onEvent?.call(event);
    }

    final llmConfig = LlmProviderConfig(
      baseUrl: provider.baseUrl,
      apiKey: provider.apiKey,
      model: provider.model,
    );
    final client = _client;
    final planner = Planner(
      client: client,
      config: llmConfig,
      languageCode: languageCode,
    );
    final executor = Executor(client: client, config: llmConfig);
    final reflector = Reflector(client: client, config: llmConfig);

    // Workflow auto-execute mode: scheduled run + sensitive actions pre-approved.
    // Used by prompt builders to switch language/rules and by the runtime to
    // bypass the confirmation gate.
    final isWorkflowAutoExecute =
        request.source == RequestSource.workflow && autoApproveSensitive;

    // Detect the user's language for THIS turn. Drives every user-facing
    // string built by the verbalizer below.
    final detectedLang = _languageDetector.detect(
      userMessage: request.userMessage,
      fallbackCode: languageCode,
    );
    logger.logStateChange(
      AgentRuntimeState.analyzing,
      'Language detected: ${detectedLang.code} '
      '(${detectedLang.script}, conf ${detectedLang.confidence.toStringAsFixed(2)})',
    );
    emit(logger.events.last);

    final verbalizer = ToolVerbalizer(client: client, config: llmConfig);
    verbalizer.resetTurn();

    try {
      // Resume from a persisted ledger if the in-memory pending was lost
      // (e.g. app was killed). Best-effort — unable-to-resume cases just
      // proceed normally and the next turn will plan from scratch.
      try {
        await _maybeRestorePendingFromLedger(request.agentId);
      } catch (e) {
        logger.logError('Ledger auto-resume failed; continuing fresh', e);
      }

      // Check if there's a pending action for this agent.
      //
      // Only deterministic yes/no/preview replies are resolved immediately.
      // Ambiguous replies must go through the analyzer with active-task
      // context first; otherwise a fresh request can be misread as approval
      // for the old pending tool and re-lock the conversation.
      var pending = _pendingActions[request.agentId];
      var pendingDecision = ConfirmationDecision.none;
      if (pending != null) {
        // Tier-1: deterministic ID/EN keyword check.
        pendingDecision = ConfirmationChecker.check(request.userMessage);

        logger.logStateChange(
          AgentRuntimeState.analyzing,
          'Pending action detected: ${pending.toolName}, '
          'deterministic decision: ${pendingDecision.name}',
        );
        emit(logger.events.last);

        final pendingResponse = await _handlePendingDecision(
          request: request,
          pending: pending,
          decision: pendingDecision,
          executor: executor,
          verbalizer: verbalizer,
          detectedLang: detectedLang,
          logger: logger,
          emit: emit,
        );
        if (pendingResponse != null) {
          return pendingResponse;
        }
      }

      // 1. Load workspace.
      final wsName = request.agentName.isNotEmpty
          ? request.agentName
          : request.agentId;
      toolRouter.agentName = wsName;
      toolRouter.agentId = request.agentId;
      await workspaceLoader.ensureWorkspace(wsName);

      // Opportunistic auto-fill: if SOUL.md still says "Preferred Language:
      // [Not set]" / placeholder, silently set it to the detected language.
      // Only when detection is reasonably confident, else leave alone so
      // ambiguous turns don't lock-in the wrong language.
      if (detectedLang.isHighConfidence) {
        await workspaceLoader.maybeFillPreferredLanguage(
          wsName,
          detectedLang.label,
        );
      }

      final workspace = await workspaceLoader.load(wsName);
      final userNotIntroduced = WorkspaceLoader.isUserNameMissing(
        workspace.soul,
      );

      // Build recent messages for context (latest 20, chronological order).
      final sourceMessages = request.recentMessages;
      final latestMessages = sourceMessages.length > 20
          ? sourceMessages.sublist(sourceMessages.length - 20)
          : sourceMessages;
      final recentMsgs = latestMessages
          .map((m) => {'role': m.role, 'content': m.content})
          .toList();

      var pendingClarification = _pendingClarifications[request.agentId];
      if (pendingClarification != null && pendingClarification.isExpired) {
        _pendingClarifications.remove(request.agentId);
        pendingClarification = null;
      }

      // Build active-task context for the analyzer when an unresolved ledger
      // exists for this scope. The analyzer uses it to set task_relation so
      // the engine can decide between continuation, revision, or new task.
      //
      // This runs even while a pending confirmation exists. Pending does NOT
      // imply continuation: a user may send a completely new task instead of
      // confirming/rejecting the previous one.
      final activeLedger = await ledgerDb.findActive(
        agentId: request.agentId,
        source: _ledgerSourceFor(request.source),
      );
      String activeTaskContext = '';
      if (activeLedger != null) {
        activeTaskContext = activeLedger.describeForUser();
      } else if (pending != null) {
        activeTaskContext =
            'pending confirmation: ${pending.debugDescriptor}; '
            'summary: ${pending.userFacingSummary}';
      } else if (pendingClarification != null) {
        activeTaskContext =
            'pending clarification for: ${pendingClarification.originalMessage} '
            '(questions: ${pendingClarification.questions.join('; ')})';
      }

      // If a prior clarify is active, probe the raw user message first so a
      // fresh task can escape the old clarify. Only after relation is known do
      // we merge the answer with the original request.
      final mergedUserMessage = pendingClarification != null
          ? pendingClarification.mergedWith(request.userMessage)
          : request.userMessage;
      var effectiveUserMessage = activeTaskContext.isNotEmpty
          ? request.userMessage
          : mergedUserMessage;

      // Tool list comes from the ToolRouter registry (system source of truth),
      // NOT from user-editable SKILLS.md template. While an old task is active
      // use the broad catalog for the analyzer, because the current message may
      // be a new task in any domain.
      var toolSelection = ToolCatalog.select(
        userMessage: request.userMessage,
        pendingAction: pending,
        isWorkflowAutoExecute: isWorkflowAutoExecute,
      );
      var analyzerTools = activeTaskContext.isNotEmpty
          ? toolRouter.buildAllAnalyzerToolDescriptions()
          : toolRouter.buildAnalyzerToolDescriptions(toolSelection.toolNames);
      var availableTools = activeTaskContext.isNotEmpty
          ? toolRouter.buildAllToolDescriptions()
          : toolRouter.buildToolDescriptions(toolSelection.toolNames);
      if (availableTools.isEmpty) {
        analyzerTools = toolRouter.buildAllAnalyzerToolDescriptions();
        availableTools = toolRouter.buildAllToolDescriptions();
      }
      logger.logStateChange(
        AgentRuntimeState.analyzing,
        'Tool context: ${activeTaskContext.isNotEmpty ? 'active-task relation probe' : toolSelection.reason} '
        '(${availableTools.length} tools, confidence ${toolSelection.confidence.toStringAsFixed(2)})',
      );
      emit(logger.events.last);

      // 2. Analyze.
      var state = AgentRuntimeState.analyzing;
      logger.logStateChange(state, 'Analyzing user intent');
      emit(logger.events.last);
      await workspaceLoader.updateHeartbeat(
        wsName,
        state: state.name,
        task: effectiveUserMessage,
      );

      var analysis = await planner.analyze(
        userMessage: effectiveUserMessage,
        workspace: workspace,
        availableTools: analyzerTools,
        logger: logger,
        recentMessages: recentMsgs,
        pendingAction: pending,
        recentToolMemory: _memory.formatForPrompt(request.agentId),
        isWorkflowAutoExecute: isWorkflowAutoExecute,
        activeTaskContext: activeTaskContext,
      );
      emit(logger.events.last);

      if (analysis == null) {
        await _finishTaskScopeForRequest(request, LedgerStatus.failed);
        return _fail('Failed to analyze request.', logger);
      }

      final analyzeNarrative = (analysis['narrative'] ?? '').toString();
      if (analyzeNarrative.isNotEmpty) {
        logger.logNarrative('analyze', analyzeNarrative);
        emit(logger.events.last);
      }

      // Relation gate: active ledger/pending/clarify state must not lock the
      // next user message. If the analyzer says the raw message is unrelated,
      // abort the old scope and continue with this request as a new task.
      var relation = (analysis['task_relation'] as String? ?? 'none').trim();
      if (activeTaskContext.isNotEmpty) {
        if (relation == 'none' &&
            pendingDecision != ConfirmationDecision.confirmed &&
            pendingDecision != ConfirmationDecision.rejected &&
            pendingDecision != ConfirmationDecision.previewOnly &&
            analysis['requires_tools'] == true) {
          relation = 'new_task';
        }
        if (relation == 'new_task') {
          final previousGoal =
              activeLedger?.mainGoal ??
              pending?.userFacingSummary ??
              pendingClarification?.originalMessage ??
              'the previous task';
          await _finishTaskScopeForRequest(request, LedgerStatus.aborted);
          pending = null;
          pendingDecision = ConfirmationDecision.none;
          pendingClarification = null;
          effectiveUserMessage = request.userMessage;

          toolSelection = ToolCatalog.select(
            userMessage: request.userMessage,
            isWorkflowAutoExecute: isWorkflowAutoExecute,
          );
          analyzerTools = toolRouter.buildAnalyzerToolDescriptions(
            toolSelection.toolNames,
          );
          availableTools = toolRouter.buildToolDescriptions(
            toolSelection.toolNames,
          );
          if (availableTools.isEmpty) {
            analyzerTools = toolRouter.buildAllAnalyzerToolDescriptions();
            availableTools = toolRouter.buildAllToolDescriptions();
          }

          final headsUp = await verbalizer.taskAborted(
            previousMainGoal: previousGoal,
            language: detectedLang,
          );
          logger.logStateChange(
            AgentRuntimeState.analyzing,
            'Active task scope archived (aborted) due to '
            'new_task classification. Heads-up surfaced.',
          );
          emit(logger.events.last);
          logger.logNarrative('relation', headsUp);
          emit(logger.events.last);
        } else if (pendingClarification != null &&
            effectiveUserMessage != mergedUserMessage) {
          effectiveUserMessage = mergedUserMessage;
          analysis = await planner.analyze(
            userMessage: effectiveUserMessage,
            workspace: workspace,
            availableTools: analyzerTools,
            logger: logger,
            recentMessages: recentMsgs,
            pendingAction: pending,
            recentToolMemory: _memory.formatForPrompt(request.agentId),
            isWorkflowAutoExecute: isWorkflowAutoExecute,
            activeTaskContext: activeTaskContext,
          );
          emit(logger.events.last);
          if (analysis == null) {
            await _finishTaskScopeForRequest(request, LedgerStatus.failed);
            return _fail('Failed to analyze clarified request.', logger);
          }
        }
      }

      if (pending != null &&
          pendingDecision != ConfirmationDecision.confirmed &&
          pendingDecision != ConfirmationDecision.rejected &&
          pendingDecision != ConfirmationDecision.previewOnly &&
          relation != 'new_task') {
        final pendingLang = pending.languageCode;
        final coveredByTier1 =
            pendingLang == 'id' ||
            pendingLang == 'en' ||
            detectedLang.code == 'id' ||
            detectedLang.code == 'en';
        if (!coveredByTier1 ||
            pendingDecision == ConfirmationDecision.unclear) {
          final classifier = ConfirmationClassifier(
            client: client,
            config: llmConfig,
          );
          pendingDecision = await classifier.classify(
            userMessage: request.userMessage,
            pendingSummary: pending.userFacingSummary,
            languageCode: pendingLang,
          );
          logger.logStateChange(
            AgentRuntimeState.analyzing,
            'Pending action LLM decision after relation gate: '
            '${pendingDecision.name}',
          );
          emit(logger.events.last);
          final pendingResponse = await _handlePendingDecision(
            request: request,
            pending: pending,
            decision: pendingDecision,
            executor: executor,
            verbalizer: verbalizer,
            detectedLang: detectedLang,
            logger: logger,
            emit: emit,
          );
          if (pendingResponse != null) {
            return pendingResponse;
          }
        }
      }

      // Conflict-clarify: when an active ledger exists and the new message
      // is classified as a brand-new unrelated task, ask the user to confirm
      // whether to abandon the in-flight task before continuing. Revision
      // and continuation simply proceed — they edit/answer the same goal.
      if (activeLedger != null && relation == '__legacy_disabled__') {
        final legacyRelation = (analysis['task_relation'] as String? ?? 'none')
            .trim();
        if (legacyRelation == 'new_task') {
          // Soft-archive the old ledger as aborted to free the scope, then
          // surface a friendly heads-up so the user knows their previous task
          // was set aside. The runtime continues with the new request.
          await ledgerDb.archive(activeLedger.id, LedgerStatus.aborted);
          final headsUp = await verbalizer.taskAborted(
            previousMainGoal: activeLedger.mainGoal,
            language: detectedLang,
          );
          logger.logStateChange(
            AgentRuntimeState.analyzing,
            'Active ledger ${activeLedger.id} archived (aborted) due to '
            'new_task classification. Heads-up surfaced.',
          );
          emit(logger.events.last);
          // We do NOT short-circuit — we just emit the heads-up as a system
          // narrative event and continue planning the new request.
          logger.logNarrative('relation', headsUp);
          emit(logger.events.last);
        }
        // For 'revision' / 'continuation' / 'none' we keep the ledger and
        // let the analyzer's own narrative + downstream phases proceed.
      }

      // If analyzer detected ambiguity, ask user before doing anything else.
      final missingInfo =
          (analysis['missing_info'] as List?)
              ?.map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList() ??
          const <String>[];
      if (missingInfo.isNotEmpty) {
        state = AgentRuntimeState.askingUser;
        final question = missingInfo.length == 1
            ? missingInfo.first
            : missingInfo.map((q) => '- $q').join('\n');
        _pendingClarifications[request.agentId] = PendingClarification(
          originalMessage:
              pendingClarification?.originalMessage ?? request.userMessage,
          questions: missingInfo,
          createdAt: DateTime.now(),
        );
        logger.logFinalResponse(question);
        return AgentRuntimeResponse(
          finalMessage: question,
          success: true,
          state: state,
          events: logger.events,
        );
      }

      _pendingClarifications.remove(request.agentId);

      // 2.5 Reflection (mandatory deep-thinking phase).
      // Builds an ecosystem snapshot, asks the LLM to decide a strategy
      // (direct_execute / clarify / auto_resolve / block), and short-circuits
      // when the strategy demands user input or refusal.
      ReflectionOutput? reflection;
      TargetResolutionGraph? targetGraph;
      final analyzerSaysToolsForReflect = analysis['requires_tools'] == true;
      final shouldReflect =
          analyzerSaysToolsForReflect && !isWorkflowAutoExecute;
      if (shouldReflect) {
        state = AgentRuntimeState.analyzing;
        logger.logStateChange(state, 'Reflecting on impact and slot needs');
        emit(logger.events.last);

        // Snapshot is opt-in via the engine constructor. When the loader is
        // missing (tests, sandbox), reflection still runs without snapshot.
        final snapshot = await _buildSnapshot();

        reflection = await reflector.reflect(
          userMessage: effectiveUserMessage,
          analysis: analysis,
          snapshot: snapshot,
          availableTools: _toolDefinitionsFor(toolSelection.toolNames),
          language: detectedLang,
          logger: logger,
          recentMessages: recentMsgs,
        );
        final targetResolution = TargetResolver.resolveReflection(
          reflection: reflection,
          snapshot: snapshot,
          request: request,
          language: detectedLang,
        );
        reflection = targetResolution.reflection;
        targetGraph = targetResolution.graph;
        logger.logLlmDecision('reflect', reflection.toJson());
        emit(logger.events.last);
        if (targetResolution.graph.isNotEmpty) {
          logger.logLlmDecision(
            'target_resolution',
            targetResolution.graph.toJson(),
          );
          emit(logger.events.last);
        }

        if (reflection.narrative.isNotEmpty) {
          logger.logNarrative('reflect', reflection.narrative);
          emit(logger.events.last);
        }

        // Strategy: clarify — ask the user one short combined question.
        if (reflection.strategy == ReflectionStrategy.clarify &&
            reflection.clarifyQuestions.isNotEmpty) {
          final question = reflection.clarifyQuestions.first;
          _pendingClarifications[request.agentId] = PendingClarification(
            originalMessage: request.userMessage,
            questions: reflection.clarifyQuestions,
            createdAt: DateTime.now(),
          );
          logger.logFinalResponse(question);
          return AgentRuntimeResponse(
            finalMessage: question,
            success: true,
            state: AgentRuntimeState.askingUser,
            events: logger.events,
          );
        }

        // Strategy: block — polite refusal with reason.
        if (reflection.strategy == ReflectionStrategy.block) {
          final reason = reflection.blockReason.isNotEmpty
              ? reflection.blockReason
              : await verbalizer.abort(
                  reason: 'destructive request blocked',
                  language: detectedLang,
                );
          logger.logFinalResponse(reason);
          return AgentRuntimeResponse(
            finalMessage: reason,
            success: true,
            state: AgentRuntimeState.done,
            events: logger.events,
          );
        }
        // Strategy: auto_resolve and direct_execute — continue to planning.
        // Phase 4 will handle silent prep steps for auto_resolve.
      }

      // If no tools required, respond directly with full context.
      // EXCEPT during scheduled workflow auto-execution: the runtime must
      // run the tool deterministically, not let the LLM craft a permission
      // request. Force the planning path.
      final analyzerSaysTools = analysis['requires_tools'] == true;
      final requiresTools = analyzerSaysTools || isWorkflowAutoExecute;
      if (!requiresTools) {
        state = AgentRuntimeState.done;
        logger.logStateChange(state, 'Direct response (no tools needed)');
        emit(logger.events.last);

        // Build messages with pending action context if exists.
        // System rules are always enforced; SOUL.md is identity context only.
        final identityBlock =
            'Identity context (from SOUL.md — user-editable):\n${workspace.soul}';
        final recentToolMemory = _memory.formatForPrompt(request.agentId);
        final toolMemoryBlock = recentToolMemory.isEmpty
            ? ''
            : '\n\nRECENT TOOL RESULTS (source of truth):\n'
                  '$recentToolMemory\n\n'
                  'Use successful retrieval results (read/list/search/status) '
                  'to answer follow-up questions. Never treat failed tool '
                  'results or prior progress/narrative messages as evidence. '
                  'If the relevant result failed or is missing, say you cannot '
                  'verify it yet and ask for the exact target or next step.';
        final baseSystem =
            '${_directResponseRulesFor(languageLabel: detectedLang.label, isWorkflowAutoExecute: isWorkflowAutoExecute, userNotIntroduced: userNotIntroduced)}\n\n$identityBlock$toolMemoryBlock';
        final systemContent = pending != null
            ? '$baseSystem\n\n'
                  'PENDING ACTION (user was asked to confirm):\n'
                  'Tool: ${pending.toolName}\n'
                  'Args: ${pending.toolArgs}\n'
                  'Summary: ${pending.userFacingSummary}\n'
                  'If user asks about the result or preview, show them what the result would be.'
            : baseSystem;

        final directResponse = await client.chat(
          config: llmConfig,
          phase: 'direct',
          messages: [
            {'role': 'system', 'content': systemContent},
            ...recentMsgs,
            {'role': 'user', 'content': request.userMessage},
          ],
        );

        // Clear pending action after handling.
        if (pending != null) {
          _pendingActions.remove(request.agentId);
        }

        logger.logFinalResponse(directResponse);
        return AgentRuntimeResponse(
          finalMessage: directResponse,
          success: true,
          state: AgentRuntimeState.done,
          events: logger.events,
        );
      }

      // 3. Plan.
      // Fast path: if the local tool catalog matched a single group with high
      // confidence AND there's no pending action / workflow auto-execute,
      // skip the planner LLM call and synthesize a 1-step plan locally.
      // The selectTool phase will still pick the exact tool + args.
      //
      // CRITICAL: never take the fast path when analyzer enumerated multiple
      // subgoal_seeds. A 1-step synthetic plan would short-circuit the loop
      // before sg2/sg3 ever ran (the "buat 3 agen → 1 agen" bug).
      final seeds = analysis['subgoal_seeds'];
      final hasMultiTarget = seeds is List && seeds.length > 1;
      final canSkipPlanner =
          pending == null &&
          !isWorkflowAutoExecute &&
          toolSelection.isHighConfidence &&
          toolSelection.groups.length == 1 &&
          missingInfo.isEmpty &&
          !hasMultiTarget;

      Map<String, dynamic>? plan;
      if (canSkipPlanner) {
        state = AgentRuntimeState.planning;
        logger.logStateChange(
          state,
          'Plan synthesized locally (group: ${toolSelection.groups.first})',
        );
        emit(logger.events.last);
        plan = {
          'steps': [
            {
              'id': 1,
              'description':
                  analysis['goal'] as String? ?? 'Execute requested action',
              'tool': null,
            },
          ],
        };
      } else {
        state = AgentRuntimeState.planning;
        logger.logStateChange(state, 'Creating execution plan');
        emit(logger.events.last);
        await workspaceLoader.updateHeartbeat(
          request.agentName.isNotEmpty ? request.agentName : request.agentId,
          state: state.name,
          task: request.userMessage,
        );

        plan = await planner.plan(
          analysis: analysis,
          availableTools: availableTools,
          logger: logger,
        );
        emit(logger.events.last);

        if (plan == null) {
          await _finishTaskScopeForRequest(request, LedgerStatus.failed);
          return _fail('Failed to create execution plan.', logger);
        }

        final planNarrative = (plan['narrative'] ?? '').toString();
        if (planNarrative.isNotEmpty) {
          logger.logNarrative('plan', planNarrative);
          emit(logger.events.last);
        }
      }

      // Build the goal tree from the planner output. If the planner returned
      // a legacy flat plan or no subgoals, fall back to a single-subgoal tree
      // so the rest of the loop has a consistent shape to reason about.
      // Reflection's goal tree wins when available — it has the most accurate
      // slot extraction and impact-aware structure.
      final goalTree = reflection != null && reflection.goalTree.isNotEmpty
          ? reflection.goalTree
          : _buildGoalTree(
              plan: plan,
              analysis: analysis,
              userMessage: effectiveUserMessage,
            );
      if (targetGraph != null && targetGraph.isNotEmpty) {
        plan['runtime_target_graph'] = targetGraph.toJson();
      }
      logger.logLlmDecision('plan.goal_tree', goalTree.toJson());

      final loopRequest = effectiveUserMessage == request.userMessage
          ? request
          : AgentRuntimeRequest(
              agentId: request.agentId,
              agentName: request.agentName,
              userMessage: effectiveUserMessage,
              recentMessages: request.recentMessages,
              metadata: request.metadata,
              source: request.source,
            );

      // 4. Execute loop.
      return _executeLoop(
        request: loopRequest,
        plan: plan,
        goalTree: goalTree,
        executor: executor,
        verbalizer: verbalizer,
        detectedLang: detectedLang,
        availableTools: availableTools,
        logger: logger,
        emit: emit,
        memorySnapshot: _memory.formatForPrompt(request.agentId),
        autoApproveSensitive: autoApproveSensitive,
        isWorkflowAutoExecute: isWorkflowAutoExecute,
      );
    } catch (e) {
      logger.logError('Runtime exception', e);
      await _finishTaskScopeForRequest(request, LedgerStatus.failed);
      return _fail('Runtime error: $e', logger);
    }
  }

  /// Execute a confirmed tool (after user approval via button).
  Future<AgentRuntimeResponse> executeConfirmed(
    AgentRuntimeRequest request, {
    required ProviderConfig provider,
    required String toolName,
    required Map<String, dynamic> toolArgs,
    RuntimeEventCallback? onEvent,
  }) async {
    final logger = RuntimeLogger();

    void emit(RuntimeEvent event) {
      onEvent?.call(event);
    }

    // Capture the pending action BEFORE clearing so we can use its
    // resumeContext to continue a multi-subgoal task.
    final priorPending = _pendingActions[request.agentId];
    _pendingActions.remove(request.agentId);

    final llmConfig = LlmProviderConfig(
      baseUrl: provider.baseUrl,
      apiKey: provider.apiKey,
      model: provider.model,
    );
    final client = _client;
    final executor = Executor(client: client, config: llmConfig);

    // Confirmed-button taps don't carry a user message. Reuse the language
    // captured at the time the pending action was created (or fall back to
    // the engine's default).
    final detectedLang = priorPending != null
        ? DetectedLanguage(
            code: priorPending.languageCode,
            label: LanguageDetector.labelForCode(priorPending.languageCode),
            script: 'Latin',
            confidence: 0.5,
          )
        : _fallbackLanguage();
    final verbalizer = ToolVerbalizer(client: client, config: llmConfig);
    verbalizer.resetTurn();

    final pending = PendingAction(
      toolName: toolName,
      toolArgs: toolArgs,
      userFacingSummary: 'Confirmed by user',
      languageCode: detectedLang.code,
      resumeContext: priorPending?.resumeContext,
    );

    return _executePendingTool(
      request: request,
      pending: pending,
      executor: executor,
      verbalizer: verbalizer,
      detectedLang: detectedLang,
      logger: logger,
      emit: emit,
    );
  }

  Future<AgentRuntimeResponse?> _handlePendingDecision({
    required AgentRuntimeRequest request,
    required PendingAction pending,
    required ConfirmationDecision decision,
    required Executor executor,
    required ToolVerbalizer verbalizer,
    required DetectedLanguage detectedLang,
    required RuntimeLogger logger,
    required void Function(RuntimeEvent) emit,
  }) async {
    switch (decision) {
      case ConfirmationDecision.confirmed:
        _pendingActions.remove(request.agentId);
        return _executePendingTool(
          request: request,
          pending: pending,
          executor: executor,
          verbalizer: verbalizer,
          detectedLang: detectedLang,
          logger: logger,
          emit: emit,
        );

      case ConfirmationDecision.rejected:
        await _finishTaskScopeForRequest(request, LedgerStatus.aborted);
        logger.logStateChange(
          AgentRuntimeState.done,
          'User rejected pending action',
        );
        emit(logger.events.last);
        final cancelMsg = await verbalizer.cancel(
          tool: ToolCallRequest(
            name: pending.toolName,
            args: pending.toolArgs,
            risk: 'sensitive',
            requiresConfirmation: true,
          ),
          language: detectedLang,
        );
        return AgentRuntimeResponse(
          finalMessage: cancelMsg,
          success: true,
          state: AgentRuntimeState.done,
          events: logger.events,
        );

      case ConfirmationDecision.previewOnly:
        logger.logStateChange(
          AgentRuntimeState.done,
          'User requested preview only',
        );
        emit(logger.events.last);
        final previewMsg = pending.userFacingPreview.isNotEmpty
            ? pending.userFacingPreview
            : await verbalizer.preview(
                tool: ToolCallRequest(
                  name: pending.toolName,
                  args: pending.toolArgs,
                  risk: 'sensitive',
                  requiresConfirmation: true,
                ),
                language: detectedLang,
              );
        return AgentRuntimeResponse(
          finalMessage: previewMsg,
          success: true,
          state: AgentRuntimeState.done,
          events: logger.events,
        );

      case ConfirmationDecision.unclear:
      case ConfirmationDecision.none:
        return null;
    }
  }

  /// Execute a pending tool (after confirmation).
  Future<AgentRuntimeResponse> _executePendingTool({
    required AgentRuntimeRequest request,
    required PendingAction pending,
    required Executor executor,
    required ToolVerbalizer verbalizer,
    required DetectedLanguage detectedLang,
    required RuntimeLogger logger,
    required void Function(RuntimeEvent) emit,
  }) async {
    try {
      var state = AgentRuntimeState.executingTool;
      logger.logStateChange(
        state,
        'Executing confirmed tool: ${pending.toolName}',
      );
      emit(logger.events.last);

      final toolRequest = ToolCallRequest(
        name: pending.toolName,
        args: pending.toolArgs,
        risk: 'confirmed',
        requiresConfirmation: false,
      );
      logger.logToolCall(toolRequest);

      final result = await toolRouter.forceExecute(toolRequest);
      logger.logToolResult(result);
      emit(logger.events.last);

      _memory.record(
        agentId: request.agentId,
        toolName: pending.toolName,
        args: pending.toolArgs,
        data: result.data,
        success: result.success,
        error: result.error,
      );

      final permissionFinal = _permissionDeniedResponseFor(result);
      if (permissionFinal != null) {
        await _finishTaskScopeForRequest(request, LedgerStatus.failed);
        logger.logFinalResponse(permissionFinal);
        await workspaceLoader.updateHeartbeat(
          request.agentName.isNotEmpty ? request.agentName : request.agentId,
          state: 'failed',
          task: request.userMessage,
          lastTool: pending.toolName,
          lastResult: 'permission_denied',
          lastError: result.error,
        );
        return AgentRuntimeResponse(
          finalMessage: permissionFinal,
          success: false,
          state: AgentRuntimeState.failed,
          events: logger.events,
        );
      }

      // Verbalizer generates the user-facing success message in the
      // detected language. Generic across all tools — no per-tool switch.
      if (result.success) {
        // Resume path: when this confirmation interrupted a multi-subgoal
        // task, mark the active subgoal done and re-enter the execute loop
        // so the remaining subgoals can run.
        final resume = pending.resumeContext;
        if (resume != null) {
          final treeJson = resume['goal_tree'] as Map<String, dynamic>?;
          final goalTree = treeJson != null
              ? GoalTree.fromJson(treeJson)
              : GoalTree.singleSubgoal(
                  mainGoal: pending.toolName,
                  subgoalLabel: pending.toolName,
                );

          // Advance the active subgoal that triggered the confirmation.
          final active = goalTree.nextActionable;
          if (active != null) {
            active.status = SubgoalStatus.done;
            active.resultRef =
                'confirmed:${pending.toolName}:${result.success}';
          }

          _memory.record(
            agentId: request.agentId,
            toolName: pending.toolName,
            args: pending.toolArgs,
            data: result.data,
            success: result.success,
            error: result.error,
          );

          final plan =
              (resume['plan'] as Map?)?.cast<String, dynamic>() ??
              {'steps': []};
          final previousResults =
              (resume['previous_results'] as List?)
                  ?.whereType<Map>()
                  .map((m) => m.cast<String, dynamic>())
                  .toList() ??
              <Map<String, dynamic>>[];
          previousResults.add({
            'step': resume['current_step'] ?? 1,
            'tool': pending.toolName,
            'result': result.data,
            'confirmed': true,
          });
          final availableTools =
              (resume['available_tools'] as List?)
                  ?.map((e) => e.toString())
                  .toList() ??
              const <String>[];
          final memorySnapshot = (resume['memory_snapshot'] as String?) ?? '';
          final autoApproveSensitive =
              resume['auto_approve_sensitive'] as bool? ?? false;
          final isWorkflowAutoExecute =
              resume['is_workflow_auto_execute'] as bool? ?? false;
          final currentStep = (resume['current_step'] as int? ?? 1) + 1;
          final userMessage =
              (resume['user_message'] as String?) ?? request.userMessage;

          final resumedRequest = AgentRuntimeRequest(
            agentId: request.agentId,
            agentName: request.agentName,
            userMessage: userMessage,
            recentMessages: request.recentMessages,
            source: request.source,
          );

          // If the tree is now complete, finish with a holistic recap.
          if (goalTree.isComplete) {
            final verificationBlocker = await _blockIfCompletionUnverified(
              request: resumedRequest,
              plan: plan,
              goalTree: goalTree,
              previousResults: previousResults,
              currentStep: currentStep,
              availableTools: availableTools,
              memorySnapshot: memorySnapshot,
              detectedLang: detectedLang,
              autoApproveSensitive: autoApproveSensitive,
              isWorkflowAutoExecute: isWorkflowAutoExecute,
              logger: logger,
              lastToolName: pending.toolName,
            );
            if (verificationBlocker != null) return verificationBlocker;

            final successMsg =
                _shouldAnswerFromToolResult(
                  toolName: pending.toolName,
                  userMessage: userMessage,
                  result: result,
                )
                ? await verbalizer.answerFromToolResult(
                    userMessage: userMessage,
                    tool: toolRequest,
                    result: result,
                    language: detectedLang,
                  )
                : await _finalForCompletedTree(
                    goalTree: goalTree,
                    fallbackTool: toolRequest,
                    fallbackResult: result,
                    verbalizer: verbalizer,
                    language: detectedLang,
                    targetGraph: (plan['runtime_target_graph'] as Map?)
                        ?.cast<String, dynamic>(),
                  );
            logger.logFinalResponse(successMsg);
            await workspaceLoader.updateHeartbeat(
              request.agentName.isNotEmpty
                  ? request.agentName
                  : request.agentId,
              state: 'done',
              task: pending.toolName,
              lastTool: pending.toolName,
              lastResult: 'success',
            );
            await _archiveLedgerForRequest(request, LedgerStatus.completed);
            return AgentRuntimeResponse(
              finalMessage: successMsg,
              success: true,
              state: AgentRuntimeState.done,
              events: logger.events,
              actions: result.actions,
            );
          }

          // Otherwise resume the execute loop where the gate fired.
          logger.logStateChange(
            AgentRuntimeState.selectingTool,
            'Resuming execute loop after confirmation '
            '(subgoals remaining: ${goalTree.subgoals.where((s) => !s.isTerminal).length})',
          );
          emit(logger.events.last);

          return _executeLoop(
            request: resumedRequest,
            plan: plan,
            goalTree: goalTree,
            executor: executor,
            verbalizer: verbalizer,
            detectedLang: detectedLang,
            availableTools: availableTools,
            logger: logger,
            emit: emit,
            memorySnapshot: memorySnapshot,
            autoApproveSensitive: autoApproveSensitive,
            isWorkflowAutoExecute: isWorkflowAutoExecute,
            initialPreviousResults: previousResults,
            initialStep: currentStep,
          );
        }

        // Legacy / single-target path: just announce success and finish.
        final successMsg =
            _shouldAnswerFromToolResult(
              toolName: pending.toolName,
              userMessage: request.userMessage,
              result: result,
            )
            ? await verbalizer.answerFromToolResult(
                userMessage: request.userMessage,
                tool: toolRequest,
                result: result,
                language: detectedLang,
              )
            : await verbalizer.success(
                tool: toolRequest,
                result: result,
                language: detectedLang,
              );
        logger.logFinalResponse(successMsg);
        await workspaceLoader.updateHeartbeat(
          request.agentName.isNotEmpty ? request.agentName : request.agentId,
          state: 'done',
          task: request.userMessage,
          lastTool: pending.toolName,
          lastResult: 'success',
        );
        return AgentRuntimeResponse(
          finalMessage: successMsg,
          success: true,
          state: AgentRuntimeState.done,
          events: logger.events,
          actions: result.actions,
        );
      }

      await workspaceLoader.updateHeartbeat(
        request.agentName.isNotEmpty ? request.agentName : request.agentId,
        state: state.name,
        task: request.userMessage,
        lastTool: pending.toolName,
        lastResult: 'failed',
        lastError: result.error,
      );

      // Failure path: let the reviewer LLM craft the human reply, but if it
      // fails fall back to the verbalizer abort message — never a raw error.
      state = AgentRuntimeState.reviewing;
      logger.logStateChange(state, 'Reviewing tool result');
      emit(logger.events.last);

      final review = await executor.review(
        result: result,
        plan: {
          'steps': [
            {
              'id': 1,
              'description': 'Execute confirmed tool',
              'tool': pending.toolName,
            },
          ],
        },
        currentStep: 1,
        userMessage: request.userMessage,
        logger: logger,
        language: detectedLang.label,
      );
      emit(logger.events.last);

      if (review != null) {
        final reviewNarrative = (review['narrative'] ?? '').toString();
        if (reviewNarrative.isNotEmpty) {
          logger.logNarrative('review', reviewNarrative);
          emit(logger.events.last);
        }
      }

      final reviewMessage = review?['final_response'] as String?;
      if (reviewMessage != null && reviewMessage.isNotEmpty) {
        await _finishTaskScopeForRequest(request, LedgerStatus.failed);
        logger.logFinalResponse(reviewMessage);
        return AgentRuntimeResponse(
          finalMessage: reviewMessage,
          success: false,
          state: AgentRuntimeState.done,
          events: logger.events,
        );
      }

      final fallbackMsg = await verbalizer.abort(
        reason: result.error ?? 'tool failed',
        language: detectedLang,
      );
      await _finishTaskScopeForRequest(request, LedgerStatus.failed);
      logger.logFinalResponse(fallbackMsg);
      return AgentRuntimeResponse(
        finalMessage: fallbackMsg,
        success: false,
        state: AgentRuntimeState.done,
        events: logger.events,
      );
    } catch (e) {
      logger.logError('Runtime exception', e);
      await _finishTaskScopeForRequest(request, LedgerStatus.failed);
      return _fail('Runtime error: $e', logger);
    }
  }

  Future<AgentRuntimeResponse> _executeLoop({
    required AgentRuntimeRequest request,
    required Map<String, dynamic> plan,
    required GoalTree goalTree,
    required Executor executor,
    required ToolVerbalizer verbalizer,
    required DetectedLanguage detectedLang,
    required List<String> availableTools,
    required RuntimeLogger logger,
    required void Function(RuntimeEvent) emit,
    required String memorySnapshot,
    bool autoApproveSensitive = false,
    bool isWorkflowAutoExecute = false,
    List<Map<String, dynamic>>? initialPreviousResults,
    int initialStep = 1,
  }) async {
    final previousResults = <Map<String, dynamic>>[...?initialPreviousResults];
    var currentStep = initialStep;
    var retryCount = 0;
    var rePlanned = false;
    final stuck = StuckDetector();

    // Adaptive budget: base + 2 steps per subgoal, hard-capped at maxSteps×3
    // for safety. Multi-target tasks need more headroom than the legacy 5.
    final adaptiveLimit = goalTree.isEmpty
        ? maxSteps
        : (maxSteps + goalTree.subgoals.length * 2).clamp(
            maxSteps,
            maxSteps * 3,
          );

    for (var i = 0; i < adaptiveLimit; i++) {
      var state = AgentRuntimeState.selectingTool;
      logger.logStateChange(state, 'Selecting tool (step $currentStep)');
      emit(logger.events.last);

      final selection = await executor.selectTool(
        plan: plan,
        currentStep: currentStep,
        previousResults: previousResults,
        availableTools: availableTools,
        logger: logger,
        recentToolMemory: memorySnapshot,
        isWorkflowAutoExecute: isWorkflowAutoExecute,
        goalTree: goalTree,
      );
      emit(logger.events.last);

      if (selection == null) {
        await _finishTaskScopeForRequest(request, LedgerStatus.failed);
        return _fail('Tool selection failed.', logger);
      }

      final selectNarrative = (selection['narrative'] ?? '').toString();
      if (selectNarrative.isNotEmpty) {
        logger.logNarrative('select_tool', selectNarrative);
        emit(logger.events.last);
      }

      final status = selection['status'] as String? ?? '';

      if (status == 'done') {
        final finalResponse =
            selection['final_response'] as String? ?? 'Task completed.';
        // Reviewer/selector wants to wrap up. Honor it only when the goal
        // tree agrees — otherwise it would short-circuit a multi-target task
        // (the original "buat 3 agen → 1 agen" bug).
        if (goalTree.isNotEmpty && !goalTree.isComplete) {
          final active = goalTree.nextActionable;
          if (active != null && _isAnswerOnlySubgoal(active)) {
            active.status = SubgoalStatus.done;
            active.notes = 'answered_user';
          }
        }
        if (goalTree.isNotEmpty && !goalTree.isComplete) {
          logger.logError(
            'Selector tried to finish early but goal tree is incomplete '
            '(${goalTree.subgoals.where((s) => !s.isTerminal).length} subgoals remaining). Continuing loop.',
          );
          previousResults.add({
            'step': currentStep,
            'note':
                'Selector returned status=done but subgoals remain. Forcing continue.',
          });
          currentStep++;
          continue;
        }

        final verificationBlocker = await _blockIfCompletionUnverified(
          request: request,
          plan: plan,
          goalTree: goalTree,
          previousResults: previousResults,
          currentStep: currentStep,
          availableTools: availableTools,
          memorySnapshot: memorySnapshot,
          detectedLang: detectedLang,
          autoApproveSensitive: autoApproveSensitive,
          isWorkflowAutoExecute: isWorkflowAutoExecute,
          logger: logger,
          lastToolName: previousResults.isEmpty
              ? null
              : previousResults.last['tool'] as String?,
        );
        if (verificationBlocker != null) return verificationBlocker;

        logger.logFinalResponse(finalResponse);
        await workspaceLoader.updateHeartbeat(
          request.agentName.isNotEmpty ? request.agentName : request.agentId,
          state: 'done',
          task: request.userMessage,
          lastResult: 'success',
        );
        return AgentRuntimeResponse(
          finalMessage: finalResponse,
          success: true,
          state: AgentRuntimeState.done,
          events: logger.events,
        );
      }

      if (status == 'ask_user') {
        return AgentRuntimeResponse(
          finalMessage:
              selection['question'] as String? ?? 'Need more information.',
          success: true,
          state: AgentRuntimeState.askingUser,
          events: logger.events,
        );
      }

      if (status == 'failed') {
        await _finishTaskScopeForRequest(request, LedgerStatus.failed);
        return _fail(
          selection['error'] as String? ?? 'Runtime failed.',
          logger,
        );
      }

      if (status == 'tool_required') {
        final toolJson = selection['tool'] as Map<String, dynamic>?;
        if (toolJson == null) {
          await _finishTaskScopeForRequest(request, LedgerStatus.failed);
          return _fail('Tool selection returned no tool data.', logger);
        }

        final toolRequest = ToolCallRequest.fromJson(toolJson);

        // Stuck detection: same tool+args repeated 3 turns in a row indicates
        // the agent is looping. Try a single re-plan, then abort gracefully
        // via verbalizer rather than hammering tokens forever.
        if (stuck.observe(toolName: toolRequest.name, args: toolRequest.args)) {
          if (!rePlanned) {
            rePlanned = true;
            stuck.reset();
            logger.logError(
              'Stuck loop detected (same call ×3). Forcing one re-plan.',
            );
            previousResults.add({
              'step': currentStep,
              'note':
                  'Detected stuck loop on ${toolRequest.name}. Reconsider approach for active subgoal.',
            });
            currentStep++;
            continue;
          }
          // Already re-planned and still stuck — abort with a polite,
          // localized message instead of swallowing more tokens.
          final abortMsg = await verbalizer.abort(
            reason: 'agent looped on ${toolRequest.name} after retry',
            language: detectedLang,
          );
          await _finishTaskScopeForRequest(request, LedgerStatus.failed);
          logger.logFinalResponse(abortMsg);
          return AgentRuntimeResponse(
            finalMessage: abortMsg,
            success: false,
            state: AgentRuntimeState.failed,
            events: logger.events,
          );
        }

        final validationError = toolRouter.validate(toolRequest);
        if (validationError != null) {
          logger.logError(validationError);
          await _finishTaskScopeForRequest(request, LedgerStatus.failed);
          return _fail(validationError, logger);
        }

        final definition = toolRouter.getDefinition(toolRequest.name)!;

        final permissionDenied = await toolRouter.permissionDeniedResult(
          toolRequest.name,
        );
        if (permissionDenied != null) {
          logger.logToolResult(permissionDenied);
          emit(logger.events.last);
          _memory.record(
            agentId: request.agentId,
            toolName: toolRequest.name,
            args: toolRequest.args,
            data: permissionDenied.data,
            success: false,
            error: permissionDenied.error,
          );
          await workspaceLoader.updateHeartbeat(
            request.agentName.isNotEmpty ? request.agentName : request.agentId,
            state: AgentRuntimeState.failed.name,
            task: request.userMessage,
            lastTool: toolRequest.name,
            lastResult: 'permission_denied',
            lastError: permissionDenied.error,
          );
          final finalResponse =
              _permissionDeniedResponseFor(permissionDenied) ??
              (permissionDenied.error ?? 'Permission denied.');
          await _finishTaskScopeForRequest(request, LedgerStatus.failed);
          logger.logFinalResponse(finalResponse);
          return AgentRuntimeResponse(
            finalMessage: finalResponse,
            success: false,
            state: AgentRuntimeState.failed,
            events: logger.events,
          );
        }

        // Pre-flight typo/existence check (deterministic backstop).
        // The reflector prompt is the primary path, but small models still
        // emit non-existent target names occasionally. Catching it here
        // prevents the user from confirming an action that will fail.
        final preflight = await _preflightTargetCheck(
          tool: toolRequest,
          definition: definition,
          verbalizer: verbalizer,
          language: detectedLang,
          userMessage: request.userMessage,
        );
        if (preflight != null) {
          logger.logFinalResponse(preflight);
          return AgentRuntimeResponse(
            finalMessage: preflight,
            success: true,
            state: AgentRuntimeState.askingUser,
            events: logger.events,
          );
        }

        // Check confirmation requirement from REGISTRY, then escalate when
        // the file op targets a peer agent's workspace. Workflow auto-execute
        // bypasses both: the user already approved at workflow creation time.
        final crossWs = await toolRouter.requiresCrossWorkspaceConfirmation(
          toolRequest,
        );
        final mustConfirm =
            (definition.requiresConfirmation || crossWs) &&
            !autoApproveSensitive;
        if (mustConfirm) {
          state = AgentRuntimeState.waitingConfirmation;
          logger.logStateChange(
            state,
            'Tool requires confirmation: ${toolRequest.name}',
          );
          emit(logger.events.last);

          // Generic verbalizer builds the confirmation message in the user's
          // detected language. No per-tool switch.
          final summary = await verbalizer.confirm(
            tool: toolRequest,
            definition: definition,
            language: detectedLang,
          );

          // Pre-verbalize the preview as well so future preview-only replies
          // can return instantly without an extra LLM call.
          final preview = await verbalizer.preview(
            tool: toolRequest,
            language: detectedLang,
          );

          // Snapshot enough state to resume the loop after the user confirms.
          // Without this, the bug surfaces as: "agent finishes the whole task
          // after only the first sensitive subgoal succeeded."
          //
          // The active subgoal is flipped to in_progress so the resumed run
          // knows to mark it done after the confirmed tool succeeds.
          Map<String, dynamic>? resumeContext;
          String? ledgerIdForPending;
          if (goalTree.isNotEmpty && !goalTree.isComplete) {
            final active = goalTree.nextActionable;
            if (active != null) {
              active.status = SubgoalStatus.inProgress;
            }
            // Multi-subgoal scope — persist a ledger so the task survives the
            // confirmation gate (and an app restart).
            if (goalTree.subgoals.length > 1) {
              final ledger = await _persistLedgerAtGate(
                request: request,
                plan: plan,
                goalTree: goalTree,
                previousResults: previousResults,
                currentStep: currentStep,
                availableTools: availableTools,
                memorySnapshot: memorySnapshot,
                detectedLang: detectedLang,
                autoApproveSensitive: autoApproveSensitive,
                isWorkflowAutoExecute: isWorkflowAutoExecute,
                pendingTool: toolRequest,
              );
              ledgerIdForPending = ledger.id;
            }
            resumeContext = {
              'ledger_id': ledgerIdForPending,
              'plan': plan,
              'goal_tree': goalTree.toJson(),
              'previous_results': previousResults,
              'current_step': currentStep,
              'available_tools': availableTools,
              'memory_snapshot': memorySnapshot,
              'auto_approve_sensitive': autoApproveSensitive,
              'is_workflow_auto_execute': isWorkflowAutoExecute,
              'language_code': detectedLang.code,
              'language_label': detectedLang.label,
              'language_script': detectedLang.script,
              'language_confidence': detectedLang.confidence,
              'user_message': request.userMessage,
            };
          }

          // Store as pending action — language is captured for follow-up turns.
          final pending = PendingAction(
            toolName: toolRequest.name,
            toolArgs: toolRequest.args,
            userFacingSummary: summary,
            userFacingPreview: preview,
            languageCode: detectedLang.code,
            resumeContext: resumeContext,
          );
          _pendingActions[request.agentId] = pending;

          await workspaceLoader.updateHeartbeat(
            request.agentName.isNotEmpty ? request.agentName : request.agentId,
            state: state.name,
            task: request.userMessage,
            lastTool: toolRequest.name,
          );

          return AgentRuntimeResponse(
            finalMessage: summary,
            success: true,
            state: AgentRuntimeState.waitingConfirmation,
            events: logger.events,
            pendingTool: toolRequest.name,
            pendingToolArgs: toolRequest.args,
          );
        }

        // Execute tool.
        state = AgentRuntimeState.executingTool;
        logger.logStateChange(state, 'Executing ${toolRequest.name}');
        emit(logger.events.last);
        logger.logToolCall(toolRequest);

        final result = autoApproveSensitive
            ? await toolRouter.forceExecute(toolRequest)
            : await toolRouter.execute(toolRequest);
        logger.logToolResult(result);
        emit(logger.events.last);

        _memory.record(
          agentId: request.agentId,
          toolName: toolRequest.name,
          args: toolRequest.args,
          data: result.data,
          success: result.success,
          error: result.error,
        );

        final permissionFinal = _permissionDeniedResponseFor(result);
        if (permissionFinal != null) {
          await _finishTaskScopeForRequest(request, LedgerStatus.failed);
          logger.logFinalResponse(permissionFinal);
          await workspaceLoader.updateHeartbeat(
            request.agentName.isNotEmpty ? request.agentName : request.agentId,
            state: 'failed',
            task: request.userMessage,
            lastTool: toolRequest.name,
            lastResult: 'permission_denied',
            lastError: result.error,
          );
          return AgentRuntimeResponse(
            finalMessage: permissionFinal,
            success: false,
            state: AgentRuntimeState.failed,
            events: logger.events,
          );
        }

        // Last planned step + success: short-circuit with verbalizer.success.
        // No per-tool switch; works for every tool generically.
        //
        // CRITICAL: when goalTree has multiple subgoals, the loop must
        // continue through the reviewer so subgoal status advances. Skipping
        // straight to verbalizer.success here was the "buat 3 agen → 1 agen"
        // bug — we'd return after the first successful tool while sg2/sg3
        // were still pending.
        final treeAllowsShortCircuit = goalTree.isEmpty || goalTree.isComplete;
        if (result.success &&
            _isLastPlannedStep(plan, currentStep) &&
            treeAllowsShortCircuit) {
          final verificationBlocker = await _blockIfCompletionUnverified(
            request: request,
            plan: plan,
            goalTree: goalTree,
            previousResults: previousResults,
            currentStep: currentStep,
            availableTools: availableTools,
            memorySnapshot: memorySnapshot,
            detectedLang: detectedLang,
            autoApproveSensitive: autoApproveSensitive,
            isWorkflowAutoExecute: isWorkflowAutoExecute,
            logger: logger,
            lastToolName: toolRequest.name,
          );
          if (verificationBlocker != null) return verificationBlocker;
          final localFinal =
              _shouldAnswerFromToolResult(
                toolName: toolRequest.name,
                userMessage: request.userMessage,
                result: result,
              )
              ? await verbalizer.answerFromToolResult(
                  userMessage: request.userMessage,
                  tool: toolRequest,
                  result: result,
                  language: detectedLang,
                )
              : await _finalForCompletedTree(
                  goalTree: goalTree,
                  fallbackTool: toolRequest,
                  fallbackResult: result,
                  verbalizer: verbalizer,
                  language: detectedLang,
                  targetGraph: (plan['runtime_target_graph'] as Map?)
                      ?.cast<String, dynamic>(),
                );
          logger.logFinalResponse(localFinal);
          await workspaceLoader.updateHeartbeat(
            request.agentName.isNotEmpty ? request.agentName : request.agentId,
            state: 'done',
            task: request.userMessage,
            lastTool: toolRequest.name,
            lastResult: 'success',
          );
          await _archiveLedgerForRequest(request, LedgerStatus.completed);
          return AgentRuntimeResponse(
            finalMessage: localFinal,
            success: true,
            state: AgentRuntimeState.done,
            events: logger.events,
            actions: result.actions,
          );
        }

        await workspaceLoader.updateHeartbeat(
          request.agentName.isNotEmpty ? request.agentName : request.agentId,
          state: state.name,
          task: request.userMessage,
          lastTool: toolRequest.name,
          lastResult: result.success ? 'success' : 'failed',
          lastError: result.error,
        );

        // Review result.
        state = AgentRuntimeState.reviewing;
        logger.logStateChange(state, 'Reviewing tool result');
        emit(logger.events.last);

        final review = await executor.review(
          result: result,
          plan: plan,
          currentStep: currentStep,
          userMessage: request.userMessage,
          logger: logger,
          language: detectedLang.label,
          goalTree: goalTree,
        );
        emit(logger.events.last);

        var reviewStatus = review?['status'] as String? ?? '';
        if (!result.success &&
            (reviewStatus == 'done' || reviewStatus == 'continue')) {
          reviewStatus = 'ask_user';
        }

        if (review != null) {
          final reviewNarrative = (review['narrative'] ?? '').toString();
          if (reviewNarrative.isNotEmpty) {
            logger.logNarrative('review', reviewNarrative);
            emit(logger.events.last);
          }
        }

        if (review != null) {
          // Apply the reviewer's subgoal_update so the tree advances even when
          // the reviewer chose status=continue. This is the lynchpin of the
          // multi-target fix.
          final update = review['subgoal_update'] as Map<String, dynamic>?;
          if (update != null) {
            var status = SubgoalStatusX.fromLabel(update['status'] as String?);
            if (!result.success && status == SubgoalStatus.done) {
              status = reviewStatus == 'failed'
                  ? SubgoalStatus.failed
                  : SubgoalStatus.inProgress;
            }
            final ok = goalTree.applyStatusUpdate(
              subgoalId: (update['id'] ?? '').toString(),
              status: status,
              resultRef: update['result_ref'] as String?,
              notes: update['notes'] as String?,
            );
            if (!ok) {
              // Fall back to advancing the active subgoal if the id was bogus,
              // so we don't softlock when the LLM hallucinates an id.
              final active = goalTree.nextActionable;
              if (active != null && result.success) {
                active.status = SubgoalStatus.done;
              }
            }
          } else if (result.success) {
            // No subgoal_update emitted but the tool succeeded — mark the
            // active subgoal done so progress is monotonic.
            final active = goalTree.nextActionable;
            if (active != null) active.status = SubgoalStatus.done;
          } else {
            final active = goalTree.nextActionable;
            if (active != null) active.status = SubgoalStatus.inProgress;
          }
        }

        if (review == null) {
          await _finishTaskScopeForRequest(request, LedgerStatus.failed);
          return _fail('Review phase failed.', logger);
        }

        if (reviewStatus == 'done') {
          // Same gate as the selector branch: the tree must agree.
          if (goalTree.isNotEmpty && !goalTree.isComplete) {
            logger.logError(
              'Reviewer tried to finish early. Goal tree still has '
              '${goalTree.subgoals.where((s) => !s.isTerminal).length} subgoal(s) outstanding. Continuing.',
            );
            previousResults.add({
              'step': currentStep,
              'tool': toolRequest.name,
              'result': result.data,
              'note':
                  'Reviewer status=done overridden because subgoals remain.',
            });
            currentStep++;
            retryCount = 0;
            continue;
          }

          final finalResponse =
              _shouldAnswerFromToolResult(
                toolName: toolRequest.name,
                userMessage: request.userMessage,
                result: result,
              )
              ? await verbalizer.answerFromToolResult(
                  userMessage: request.userMessage,
                  tool: toolRequest,
                  result: result,
                  language: detectedLang,
                )
              : review['final_response'] as String? ?? 'Task completed.';
          final verificationBlocker = await _blockIfCompletionUnverified(
            request: request,
            plan: plan,
            goalTree: goalTree,
            previousResults: previousResults,
            currentStep: currentStep,
            availableTools: availableTools,
            memorySnapshot: memorySnapshot,
            detectedLang: detectedLang,
            autoApproveSensitive: autoApproveSensitive,
            isWorkflowAutoExecute: isWorkflowAutoExecute,
            logger: logger,
            lastToolName: toolRequest.name,
          );
          if (verificationBlocker != null) return verificationBlocker;
          // For multi-subgoal tasks, override the reviewer's per-tool reply
          // with a holistic recap covering every completed subgoal.
          final completedFinal =
              goalTree.isNotEmpty &&
                  goalTree.subgoals
                          .where(
                            (s) =>
                                s.status == SubgoalStatus.done ||
                                s.status == SubgoalStatus.failed ||
                                s.status == SubgoalStatus.skipped,
                          )
                          .length >
                      1
              ? await _finalForCompletedTree(
                  goalTree: goalTree,
                  fallbackTool: toolRequest,
                  fallbackResult: result,
                  verbalizer: verbalizer,
                  language: detectedLang,
                  targetGraph: (plan['runtime_target_graph'] as Map?)
                      ?.cast<String, dynamic>(),
                )
              : finalResponse;
          logger.logFinalResponse(completedFinal);
          await workspaceLoader.updateHeartbeat(
            request.agentName.isNotEmpty ? request.agentName : request.agentId,
            state: 'done',
            task: request.userMessage,
            lastTool: toolRequest.name,
            lastResult: 'success',
          );
          await _archiveLedgerForRequest(request, LedgerStatus.completed);
          return AgentRuntimeResponse(
            finalMessage: completedFinal,
            success: true,
            state: AgentRuntimeState.done,
            events: logger.events,
            actions: result.success ? result.actions : const [],
          );
        }

        if (reviewStatus == 'ask_user') {
          final question =
              review['question'] as String? ??
              await _fallbackQuestionForToolFailure(
                result,
                detectedLang,
                verbalizer,
              );
          await _parkTaskForUserInput(
            request: request,
            plan: plan,
            goalTree: goalTree,
            previousResults: previousResults,
            currentStep: currentStep,
            availableTools: availableTools,
            memorySnapshot: memorySnapshot,
            detectedLang: detectedLang,
            autoApproveSensitive: autoApproveSensitive,
            isWorkflowAutoExecute: isWorkflowAutoExecute,
            questions: [question],
          );
          return AgentRuntimeResponse(
            finalMessage: question,
            success: true,
            state: AgentRuntimeState.askingUser,
            events: logger.events,
          );
        }

        if (reviewStatus == 'failed') {
          await _finishTaskScopeForRequest(request, LedgerStatus.failed);
          return _fail(
            review['error'] as String? ?? 'Unrecoverable error.',
            logger,
          );
        }

        if (reviewStatus == 'retry' && retryCount < 1) {
          retryCount++;
          previousResults.add({
            'step': currentStep,
            'tool': toolRequest.name,
            'result': result.data,
            'retried': true,
          });
          continue;
        }

        previousResults.add({
          'step': currentStep,
          'tool': toolRequest.name,
          'result': result.data,
        });
        currentStep++;
        retryCount = 0;
      }
    }

    await _finishTaskScopeForRequest(request, LedgerStatus.failed);
    return _fail(
      'Maximum runtime steps ($adaptiveLimit) reached without completion.',
      logger,
    );
  }

  /// Build a [GoalTree] from the planner output. Tolerates legacy
  /// `steps[]`-only plans by collapsing them into a single subgoal.
  GoalTree _buildGoalTree({
    required Map<String, dynamic> plan,
    required Map<String, dynamic> analysis,
    required String userMessage,
  }) {
    final mainGoal =
        (plan['main_goal'] as String?) ??
        (analysis['goal'] as String?) ??
        userMessage;

    final subgoalsJson = plan['subgoals'];
    if (subgoalsJson is List && subgoalsJson.isNotEmpty) {
      try {
        return GoalTree.fromJson({
          'main_goal': mainGoal,
          'completion_criteria': plan['completion_criteria'] ?? const [],
          'subgoals': subgoalsJson,
        });
      } catch (_) {
        // Fall through to legacy fallback.
      }
    }

    // Try analysis.subgoal_seeds (analyzer-side enumeration).
    final seeds = analysis['subgoal_seeds'];
    if (seeds is List && seeds.length > 1) {
      return GoalTree(
        mainGoal: mainGoal,
        subgoals: [
          for (var i = 0; i < seeds.length; i++)
            Subgoal(id: 'sg${i + 1}', label: seeds[i].toString()),
        ],
      );
    }

    // Single-subgoal fallback so the rest of the loop has consistent shape.
    return GoalTree.singleSubgoal(mainGoal: mainGoal, subgoalLabel: mainGoal);
  }

  /// Build the ecosystem snapshot for the current turn.
  ///
  /// Returns an empty snapshot when the engine was constructed without a
  /// builder/agent loader (e.g. unit tests). The reflector tolerates that.
  Future<EcosystemSnapshot> _buildSnapshot() async {
    final builder = snapshotBuilder;
    final loader = agentLoader;
    if (builder == null || loader == null) {
      return EcosystemSnapshot(
        agents: const [],
        workflows: const [],
        providers: const [],
        modules: const [],
        builtAt: DateTime.now(),
      );
    }
    try {
      return await builder.build(agents: loader());
    } catch (_) {
      return EcosystemSnapshot(
        agents: const [],
        workflows: const [],
        providers: const [],
        modules: const [],
        builtAt: DateTime.now(),
      );
    }
  }

  /// Resolve [ToolDefinition] objects for the given tool names. Names that
  /// aren't in the registry are silently dropped — the reflector treats the
  /// result as best-effort.
  List<ToolDefinition> _toolDefinitionsFor(Set<String> names) {
    final out = <ToolDefinition>[];
    for (final n in names) {
      final def = toolRouter.getDefinition(n);
      if (def != null) out.add(def);
    }
    return out;
  }

  /// Persist the current loop state to a [TaskLedger] when the confirmation
  /// gate fires for a multi-subgoal task. If an active ledger already exists
  /// for the (agentId, source) scope it is updated in place; otherwise a
  /// new ledger row is inserted.
  ///
  /// The ledger becomes the authoritative store for the task — `resumeContext`
  /// only needs to carry a pointer (`ledger_id`) afterwards.
  Future<TaskLedger> _persistLedgerAtGate({
    required AgentRuntimeRequest request,
    required Map<String, dynamic> plan,
    required GoalTree goalTree,
    required List<Map<String, dynamic>> previousResults,
    required int currentStep,
    required List<String> availableTools,
    required String memorySnapshot,
    required DetectedLanguage detectedLang,
    required bool autoApproveSensitive,
    required bool isWorkflowAutoExecute,
    ToolCallRequest? pendingTool,
  }) async {
    final source = request.source == RequestSource.workflow
        ? LedgerSource.workflow
        : LedgerSource.chat;

    final existing = await ledgerDb.findActive(
      agentId: request.agentId,
      source: source,
    );

    if (existing != null) {
      // Update in place — the loop is mid-flight, just sync state.
      existing.goalTree = goalTree;
      existing.previousResults = List.of(previousResults);
      existing.currentStep = currentStep;
      existing.plan = plan;
      existing.targetGraph =
          (plan['runtime_target_graph'] as Map?)?.cast<String, dynamic>() ??
          existing.targetGraph;
      existing.pendingToolName = pendingTool?.name;
      existing.pendingToolArgs = pendingTool?.args;
      return ledgerDb.upsert(existing);
    }

    final ledger = TaskLedger(
      id:
          'lg_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
          '_${request.agentId.hashCode.toUnsigned(16).toRadixString(16)}',
      agentId: request.agentId,
      source: source,
      sourceRef: source == LedgerSource.workflow ? request.userMessage : null,
      mainGoal: goalTree.mainGoal,
      languageCode: detectedLang.code,
      originalUserMessage: request.userMessage,
      goalTree: goalTree,
      completionCriteria: goalTree.completionCriteria,
      previousResults: List.of(previousResults),
      targetGraph:
          (plan['runtime_target_graph'] as Map?)?.cast<String, dynamic>() ??
          const {},
      currentStep: currentStep,
      availableTools: availableTools,
      memorySnapshot: memorySnapshot,
      autoApproveSensitive: autoApproveSensitive,
      isWorkflowAutoExecute: isWorkflowAutoExecute,
      plan: plan,
      pendingToolName: pendingTool?.name,
      pendingToolArgs: pendingTool?.args,
    );
    return ledgerDb.upsert(ledger);
  }

  Future<void> _parkTaskForUserInput({
    required AgentRuntimeRequest request,
    required Map<String, dynamic> plan,
    required GoalTree goalTree,
    required List<Map<String, dynamic>> previousResults,
    required int currentStep,
    required List<String> availableTools,
    required String memorySnapshot,
    required DetectedLanguage detectedLang,
    required bool autoApproveSensitive,
    required bool isWorkflowAutoExecute,
    required List<String> questions,
  }) async {
    final cleanQuestions = questions
        .map((q) => q.trim())
        .where((q) => q.isNotEmpty)
        .toList(growable: false);
    if (cleanQuestions.isEmpty) return;

    _pendingClarifications[request.agentId] = PendingClarification(
      originalMessage: request.userMessage,
      questions: cleanQuestions,
      createdAt: DateTime.now(),
    );

    if (goalTree.isNotEmpty && !goalTree.isComplete) {
      await _persistLedgerAtGate(
        request: request,
        plan: plan,
        goalTree: goalTree,
        previousResults: previousResults,
        currentStep: currentStep,
        availableTools: availableTools,
        memorySnapshot: memorySnapshot,
        detectedLang: detectedLang,
        autoApproveSensitive: autoApproveSensitive,
        isWorkflowAutoExecute: isWorkflowAutoExecute,
      );
    }
  }

  Future<String> _fallbackQuestionForToolFailure(
    ToolExecutionResult result,
    DetectedLanguage language,
    ToolVerbalizer verbalizer,
  ) async {
    // 1. Provider disambiguation — deterministic, no LLM needed.
    //    Structured data from system.agents.create.
    final providers = result.data?['providers'] as List?;
    if (providers != null && providers.isNotEmpty) {
      final names = providers
          .whereType<Map>()
          .map(
            (p) => (p['nickname'] ?? p['name'] ?? p['model'] ?? '').toString(),
          )
          .where((p) => p.trim().isNotEmpty)
          .join(', ');
      return await verbalizer.providerDisambiguation(
        availableProviders: names,
        language: language,
      );
    }

    // 2. All other failures: let the verbalizer craft a natural question
    //    in the user's detected language. Pass structured context so it
    //    can be specific instead of generic.
    final data = result.data;
    final error = (result.error ?? '').trim();
    String? availableNames;
    String? triedName;

    if (data != null &&
        data['available'] is List &&
        (data['available'] as List).isNotEmpty) {
      final available = data['available'] as List;
      availableNames = available
          .whereType<Map>()
          .map((m) => (m['name'] ?? '').toString())
          .where((n) => n.trim().isNotEmpty)
          .join(', ');
      final tried = data['tried'];
      triedName = tried is Map
          ? (tried['name'] ?? tried['id'] ?? '')?.toString()
          : null;
    }

    return await verbalizer.fallbackQuestion(
      error: error,
      availableNames: availableNames,
      triedName: triedName,
      language: language,
    );
  }

  Future<AgentRuntimeResponse?> _blockIfCompletionUnverified({
    required AgentRuntimeRequest request,
    required Map<String, dynamic> plan,
    required GoalTree goalTree,
    required List<Map<String, dynamic>> previousResults,
    required int currentStep,
    required List<String> availableTools,
    required String memorySnapshot,
    required DetectedLanguage detectedLang,
    required bool autoApproveSensitive,
    required bool isWorkflowAutoExecute,
    required RuntimeLogger logger,
    String? lastToolName,
  }) async {
    final verification = _verifyAgentRegistryCompletion(
      plan: plan,
      goalTree: goalTree,
      previousResults: previousResults,
      lastToolName: lastToolName,
      language: detectedLang,
    );
    if (verification == null || verification.ok) return null;

    for (final subgoal in goalTree.subgoals) {
      final expected = _expectedAgentNameForSubgoal(subgoal);
      if (expected != null &&
          verification.missingNames.any(
            (name) => name.toLowerCase() == expected.toLowerCase(),
          )) {
        subgoal.status = SubgoalStatus.inProgress;
        subgoal.notes = 'Verification failed: agent registry state mismatch.';
      }
    }

    await _parkTaskForUserInput(
      request: request,
      plan: plan,
      goalTree: goalTree,
      previousResults: previousResults,
      currentStep: currentStep,
      availableTools: availableTools,
      memorySnapshot: memorySnapshot,
      detectedLang: detectedLang,
      autoApproveSensitive: autoApproveSensitive,
      isWorkflowAutoExecute: isWorkflowAutoExecute,
      questions: [verification.question],
    );
    logger.logFinalResponse(verification.message);
    return AgentRuntimeResponse(
      finalMessage: verification.message,
      success: false,
      state: AgentRuntimeState.askingUser,
      events: logger.events,
    );
  }

  _CompletionVerification? _verifyAgentRegistryCompletion({
    required Map<String, dynamic> plan,
    required GoalTree goalTree,
    required List<Map<String, dynamic>> previousResults,
    required DetectedLanguage language,
    String? lastToolName,
  }) {
    final touchedAgentCreate =
        lastToolName == 'system.agents.create' ||
        previousResults.any((r) => r['tool'] == 'system.agents.create');
    final touchedAgentDelete =
        lastToolName == 'system.agents.delete' ||
        previousResults.any((r) => r['tool'] == 'system.agents.delete');
    if ((!touchedAgentCreate && !touchedAgentDelete) || goalTree.isEmpty) {
      return null;
    }

    final loadAgents = agentLoader;
    if (loadAgents == null) return null;
    final existing = loadAgents()
        .map((a) => a.name.trim().toLowerCase())
        .where((name) => name.isNotEmpty)
        .toSet();
    if (existing.isEmpty) return null;

    final targetGraph =
        (plan['runtime_target_graph'] as Map?)?.cast<String, dynamic>() ??
        const {};
    final graphTargets =
        (targetGraph['targets'] as List?)
            ?.whereType<Map>()
            .map((m) => m.cast<String, dynamic>())
            .toList() ??
        const <Map<String, dynamic>>[];

    final expectedCreates = graphTargets
        .where(
          (target) =>
              target['entity_type'] == 'agent' &&
              target['operation'] == 'create' &&
              target['status'] != 'skipped',
        )
        .map((target) => (target['entity_label'] ?? '').toString().trim())
        .where((name) => name.isNotEmpty)
        .toSet();
    final expectedDeletes = graphTargets
        .where(
          (target) =>
              target['entity_type'] == 'agent' &&
              target['operation'] == 'delete' &&
              target['status'] == 'eligible',
        )
        .map((target) => (target['entity_label'] ?? '').toString().trim())
        .where((name) => name.isNotEmpty)
        .toSet();

    final expectedFromTree = goalTree.subgoals
        .map(_expectedAgentNameForSubgoal)
        .whereType<String>()
        .where((name) => name.trim().isNotEmpty)
        .toSet();
    if (touchedAgentCreate && expectedCreates.isEmpty) {
      expectedCreates.addAll(expectedFromTree);
    }
    if (expectedCreates.isEmpty && expectedDeletes.isEmpty) return null;

    final missingCreates = expectedCreates
        .where((name) => !existing.contains(name.toLowerCase()))
        .toList(growable: false);
    final stillPresentDeletes = expectedDeletes
        .where((name) => existing.contains(name.toLowerCase()))
        .toList(growable: false);
    if (missingCreates.isEmpty && stillPresentDeletes.isEmpty) {
      return const _CompletionVerification(ok: true);
    }

    final mismatchNames = [...missingCreates, ...stillPresentDeletes];
    final missingText = missingCreates.join(', ');
    final stillPresentText = stillPresentDeletes.join(', ');
    if (language.code == 'id') {
      final detail = [
        if (missingCreates.isNotEmpty) '$missingText belum ada',
        if (stillPresentDeletes.isNotEmpty) '$stillPresentText masih ada',
      ].join(', dan ');
      return _CompletionVerification(
        ok: false,
        missingNames: mismatchNames,
        message:
            'Aku cek ulang daftar agen: $detail, jadi task ini belum aku anggap selesai. Mau aku lanjut bereskan bagian yang belum sesuai?',
        question: 'Lanjut bereskan bagian yang belum sesuai: $detail?',
      );
    }
    final detail = [
      if (missingCreates.isNotEmpty) '$missingText is still missing',
      if (stillPresentDeletes.isNotEmpty) '$stillPresentText is still present',
    ].join(', and ');
    return _CompletionVerification(
      ok: false,
      missingNames: mismatchNames,
      message:
          'I checked the agent list again: $detail, so I am not marking this task complete. Should I continue fixing the unfinished part?',
      question: 'Continue fixing the unfinished part: $detail?',
    );
  }

  String? _expectedAgentNameForSubgoal(Subgoal subgoal) {
    for (final key in const [
      'name',
      'agentName',
      'agent_name',
      'targetName',
      'target_name',
    ]) {
      final value = subgoal.requiredSlots[key];
      if (value is String && value.trim().isNotEmpty) {
        return value.trim();
      }
    }

    final quoted = RegExp(
      r'["“”]([^"“”]+)["“”]',
    ).firstMatch(subgoal.label)?.group(1)?.trim();
    if (quoted != null && quoted.isNotEmpty) return quoted;

    final match = RegExp(
      r'\b(?:agent|agen)\s+([A-Za-z0-9_-]{2,})\b',
      caseSensitive: false,
    ).firstMatch(subgoal.label);
    return match?.group(1)?.trim();
  }

  /// Auto-resume a [PendingAction] from a persisted ledger when the in-memory
  /// map for [agentId] is empty (e.g. after the app was killed mid-task).
  ///
  /// Only fires when the ledger was last persisted at a confirmation gate
  /// (i.e. it has both [TaskLedger.pendingToolName] and
  /// [TaskLedger.pendingToolArgs]). Lossy/early-stage ledgers stay dormant
  /// and the next user turn will plan from scratch.
  Future<void> _maybeRestorePendingFromLedger(String agentId) async {
    if (_pendingActions.containsKey(agentId)) return;
    final ledger = await ledgerDb.findActive(
      agentId: agentId,
      source: LedgerSource.chat,
    );
    if (ledger == null) return;
    final toolName = ledger.pendingToolName;
    final toolArgs = ledger.pendingToolArgs;
    if (toolName == null || toolArgs == null) return;

    _pendingActions[agentId] = PendingAction(
      toolName: toolName,
      toolArgs: toolArgs,
      userFacingSummary: 'Resuming the task from where we left off.',
      languageCode: ledger.languageCode,
      resumeContext: {
        'ledger_id': ledger.id,
        'plan': ledger.plan ?? const {'steps': []},
        'goal_tree': ledger.goalTree.toJson(),
        'previous_results': ledger.previousResults,
        'current_step': ledger.currentStep,
        'available_tools': ledger.availableTools,
        'memory_snapshot': ledger.memorySnapshot,
        'auto_approve_sensitive': ledger.autoApproveSensitive,
        'is_workflow_auto_execute': ledger.isWorkflowAutoExecute,
        'language_code': ledger.languageCode,
        'language_label': LanguageDetector.labelForCode(ledger.languageCode),
        'language_script': 'Latin',
        'language_confidence': 0.6,
        'user_message': ledger.originalUserMessage,
      },
    );
  }

  LedgerSource _ledgerSourceFor(RequestSource source) =>
      source == RequestSource.workflow
      ? LedgerSource.workflow
      : LedgerSource.chat;

  Future<void> _finishTaskScopeForRequest(
    AgentRuntimeRequest request,
    LedgerStatus terminal,
  ) {
    return _finishTaskScope(
      agentId: request.agentId,
      source: request.source,
      terminal: terminal,
    );
  }

  Future<void> _finishTaskScope({
    required String agentId,
    required RequestSource source,
    required LedgerStatus terminal,
  }) async {
    _pendingActions.remove(agentId);
    _pendingClarifications.remove(agentId);

    final active = await ledgerDb.findActive(
      agentId: agentId,
      source: _ledgerSourceFor(source),
    );
    if (active == null) return;
    if (terminal == LedgerStatus.failed) {
      await ledgerDb.delete(active.id);
    } else {
      await ledgerDb.archive(active.id, terminal);
    }
  }

  /// Archive a ledger as completed when the goal tree finishes successfully.
  /// No-op when no ledger exists for the (agentId, source) scope.
  Future<void> _archiveLedgerForRequest(
    AgentRuntimeRequest request,
    LedgerStatus terminal,
  ) async {
    final active = await ledgerDb.findActive(
      agentId: request.agentId,
      source: _ledgerSourceFor(request.source),
    );
    if (active == null) return;
    if (terminal == LedgerStatus.failed) {
      // Soft-delete failed ledgers so retry isn't polluted by stale state.
      await ledgerDb.delete(active.id);
    } else {
      await ledgerDb.archive(active.id, terminal);
    }
  }

  /// Build the final user-facing message when the goal tree completes.
  ///
  /// Multi-subgoal tasks get a holistic recap via [ToolVerbalizer.taskSummary]
  /// covering EVERY completed subgoal, not just the last tool call. Single-
  /// subgoal or empty trees fall back to the per-tool [ToolVerbalizer.success]
  /// path so simple "open whatsapp" interactions stay tight.
  Future<String> _finalForCompletedTree({
    required GoalTree goalTree,
    required ToolCallRequest fallbackTool,
    required ToolExecutionResult fallbackResult,
    required ToolVerbalizer verbalizer,
    required DetectedLanguage language,
    Map<String, dynamic>? targetGraph,
  }) {
    final completed = goalTree.subgoals
        .where(
          (s) =>
              s.status == SubgoalStatus.done ||
              s.status == SubgoalStatus.failed ||
              s.status == SubgoalStatus.skipped,
        )
        .toList();
    final skippedTargets =
        (targetGraph?['targets'] as List?)
            ?.whereType<Map>()
            .map((m) => m.cast<String, dynamic>())
            .where((target) => target['status'] == 'skipped')
            .map(
              (target) => <String, dynamic>{
                'label': target['entity_label'] ?? target['key'] ?? 'target',
                'status': 'skipped',
                'notes': target['reason'] ?? 'skipped by runtime policy',
              },
            )
            .toList() ??
        const <Map<String, dynamic>>[];
    final completedRows = [
      ...completed.map(
        (s) => <String, dynamic>{
          'label': s.label,
          'status': s.status.label,
          if (s.notes != null && s.notes!.isNotEmpty) 'notes': s.notes,
        },
      ),
      ...skippedTargets,
    ];

    if (goalTree.isNotEmpty && completedRows.length > 1) {
      return verbalizer.taskSummary(
        mainGoal: goalTree.mainGoal,
        completedSubgoals: completedRows,
        language: language,
      );
    }

    return verbalizer.success(
      tool: fallbackTool,
      result: fallbackResult,
      language: language,
    );
  }

  /// Pre-flight deterministic check that catches typos / non-existent targets
  /// before the confirmation gate fires.
  ///
  /// Inspects ToolDefinition runtime metadata and validates snapshot-backed
  /// targets through [SnapshotTargetResolver]. Returns:
  /// - null when the target resolves cleanly (or the tool is not entity-bound)
  /// - a localized clarify/block message otherwise
  ///
  /// Generic across tools — driven by arg key heuristics + snapshot lookups,
  /// no per-tool switch. Skipped silently when no snapshot is available.
  Future<String?> _preflightTargetCheck({
    required ToolCallRequest tool,
    required ToolDefinition definition,
    required ToolVerbalizer verbalizer,
    required DetectedLanguage language,
    required String userMessage,
  }) async {
    final operation = _operationForTool(definition, tool.name);
    final entityType = _entityTypeForTool(definition, tool.name);
    if (!_requiresExistingTargetPreflight(operation) && entityType != 'file') {
      return null;
    }

    final snapshot = await _buildSnapshot();
    if (snapshot.isEmpty) return null;

    final embeddedReferenceCheck = await _preflightEmbeddedSnapshotReferences(
      tool: tool,
      definition: definition,
      snapshot: snapshot,
      verbalizer: verbalizer,
      language: language,
      userMessage: userMessage,
    );
    if (embeddedReferenceCheck != null) return embeddedReferenceCheck;

    if (!_requiresExistingTargetPreflight(operation)) return null;
    if (!SnapshotTargetResolver.isSnapshotBacked(entityType)) return null;

    final labelSelector = _labelSelectorValue(tool, definition, entityType);
    if (labelSelector == null) return null;

    final match = SnapshotTargetResolver.resolve(
      snapshot: snapshot,
      entityType: entityType,
      entityLabel: labelSelector.value,
    );
    if (match.isExact) return null;

    return verbalizer.clarifyTarget(
      entityType: entityType,
      userTyped: labelSelector.value,
      suggestion: match.isAmbiguous ? match.label : null,
      available: match.suggestions,
      language: language,
    );
  }

  Future<String?> _preflightEmbeddedSnapshotReferences({
    required ToolCallRequest tool,
    required ToolDefinition definition,
    required EcosystemSnapshot snapshot,
    required ToolVerbalizer verbalizer,
    required DetectedLanguage language,
    required String userMessage,
  }) async {
    final entityType = _entityTypeForTool(definition, tool.name);
    if (entityType != 'file' || snapshot.agents.isEmpty) return null;

    for (final key in _selectorKeysFor(definition, entityType)) {
      final raw = tool.args[key];
      if (raw is! String || raw.trim().isEmpty) continue;
      final peerPath = TargetReferenceUtils.parsePeerAgentPath(raw);
      if (peerPath == null) continue;

      final typedName = TargetReferenceUtils.displayNameFromWorkspaceSegment(
        peerPath.agentSegment,
      );
      final candidates = SnapshotTargetResolver.candidates(
        snapshot,
        'agent',
      ).map((candidate) => candidate.label).toList();
      final match = SnapshotTargetResolver.resolve(
        snapshot: snapshot,
        entityType: 'agent',
        entityLabel: typedName,
      );

      if (match.isExact) {
        final userNamedExactAgent =
            TargetReferenceUtils.messageMentionsExactAgent(
              userMessage,
              match.label,
            );
        if (!userNamedExactAgent) {
          return verbalizer.clarifyTarget(
            entityType: 'agent',
            userTyped: typedName,
            suggestion: match.label,
            available: candidates,
            language: language,
          );
        }
        tool.args[key] = TargetReferenceUtils.canonicalPeerAgentPath(
          peerPath,
          match.label,
        );
        continue;
      }

      return verbalizer.clarifyTarget(
        entityType: 'agent',
        userTyped: typedName,
        suggestion: match.isAmbiguous ? match.label : null,
        available: match.suggestions.isNotEmpty
            ? match.suggestions
            : candidates,
        language: language,
      );
    }

    return null;
  }

  bool _requiresExistingTargetPreflight(String operation) {
    switch (operation) {
      case 'delete':
      case 'update':
      case 'rename':
      case 'toggle':
      case 'read':
      case 'get':
        return true;
      default:
        return false;
    }
  }

  String _operationForTool(ToolDefinition definition, String toolName) {
    if (definition.operation.isNotEmpty) return definition.operation;
    final name = toolName.toLowerCase();
    if (name.contains('.delete')) return 'delete';
    if (name.contains('.update')) return 'update';
    if (name.contains('.rename')) return 'rename';
    if (name.contains('.toggle')) return 'toggle';
    if (name.endsWith('.read')) return 'read';
    if (name.endsWith('.get')) return 'get';
    if (name.endsWith('.list')) return 'list';
    if (name.contains('.create')) return 'create';
    return '';
  }

  String _entityTypeForTool(ToolDefinition definition, String toolName) {
    if (definition.targetEntity.isNotEmpty) return definition.targetEntity;
    if (toolName.startsWith('system.agents.')) return 'agent';
    if (toolName.startsWith('workflow.')) return 'workflow';
    if (toolName.startsWith('system.providers.')) return 'provider';
    if (toolName.startsWith('system.modules.')) return 'module';
    return '';
  }

  _SelectorValue? _labelSelectorValue(
    ToolCallRequest tool,
    ToolDefinition definition,
    String entityType,
  ) {
    for (final key in _selectorKeysFor(definition, entityType)) {
      if (_isIdSelectorKey(key)) continue;
      final value = tool.args[key];
      if (value is String && value.trim().isNotEmpty) {
        return _SelectorValue(value.trim());
      }
    }
    return null;
  }

  List<String> _selectorKeysFor(ToolDefinition definition, String entityType) {
    if (definition.selectorArgs.isNotEmpty) return definition.selectorArgs;
    switch (entityType) {
      case 'agent':
        return const ['name', 'agentName', 'label', 'target'];
      case 'workflow':
        return const ['title', 'workflowName', 'label', 'target', 'id'];
      case 'provider':
        return const ['nickname', 'provider', 'providerName', 'label', 'id'];
      case 'module':
        return const ['id', 'module', 'moduleId', 'label'];
      case 'file':
        return const ['path', 'from', 'to'];
      default:
        return const ['name', 'title', 'label', 'target'];
    }
  }

  bool _isIdSelectorKey(String key) {
    final lower = key.toLowerCase();
    return lower == 'id' || lower.endsWith('id') || lower.endsWith('_id');
  }

  AgentRuntimeResponse _fail(String message, RuntimeLogger logger) {
    logger.logError(message);
    return AgentRuntimeResponse(
      finalMessage: message,
      success: false,
      state: AgentRuntimeState.failed,
      events: logger.events,
    );
  }

  bool _isLastPlannedStep(Map<String, dynamic> plan, int currentStep) {
    final steps = plan['steps'];
    if (steps is! List || steps.isEmpty) return true;
    return currentStep >= steps.length;
  }

  bool _shouldAnswerFromToolResult({
    required String toolName,
    required String userMessage,
    required ToolExecutionResult result,
  }) {
    if (!result.success || result.data == null || result.data!.isEmpty) {
      return false;
    }
    if (userMessage.trim().isEmpty) return false;
    return _isRetrievalTool(toolName);
  }

  bool _isRetrievalTool(String toolName) {
    final name = toolName.toLowerCase();
    if (name.endsWith('.read') ||
        name.endsWith('.list') ||
        name.endsWith('.search') ||
        name.endsWith('.summarize') ||
        name.endsWith('.classify') ||
        name.endsWith('.status') ||
        name.endsWith('.today') ||
        name.endsWith('.self')) {
      return true;
    }
    if (name == 'system.self' ||
        name == 'app.list_installed' ||
        name == 'notification.read_recent' ||
        name == 'system.agents.list' ||
        name == 'system.providers.list' ||
        name == 'system.modules.list' ||
        name == 'system.tools.list') {
      return true;
    }
    if (name.startsWith('device.') &&
        !name.endsWith('.set') &&
        !name.contains('reconnect')) {
      return true;
    }
    return false;
  }

  bool _isAnswerOnlySubgoal(Subgoal subgoal) {
    final op = _subgoalSlot(subgoal, const [
      '_operation',
      'operation',
      'action',
      'kind',
    ]).toLowerCase();
    if (const {
      'respond',
      'answer',
      'final_response',
      'synthesize',
      'summarize_for_user',
    }.contains(op)) {
      return true;
    }

    final tool = _subgoalSlot(subgoal, const ['tool', 'tool_name']);
    return tool.toLowerCase() == 'none';
  }

  String _subgoalSlot(Subgoal subgoal, List<String> keys) {
    for (final key in keys) {
      final value = subgoal.requiredSlots[key];
      if (value == null) continue;
      final text = value.toString().trim();
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  String? _permissionDeniedResponseFor(ToolExecutionResult result) {
    final data = result.data;
    if (data == null ||
        data['errorCode'] != ToolPermissionPolicy.permissionDeniedCode) {
      return null;
    }

    final isId = languageCode == 'id';
    final reason = data['reason'] as String? ?? '';
    final moduleName = (data['moduleName'] as String? ?? '').trim();
    final module = moduleName.isEmpty
        ? (isId ? 'modul terkait' : 'the required module')
        : moduleName;
    final action =
        ((isId ? data['actionLabelId'] : data['actionLabel']) as String? ?? '')
            .trim();
    final actionLabel = action.isEmpty
        ? (isId ? 'menjalankan aksi itu' : 'do that')
        : action;
    final setting =
        ((isId ? data['settingLabelId'] : data['settingLabel']) as String? ??
                '')
            .trim();

    if (reason == ToolPermissionBlockReason.settingDisabled.name &&
        setting.isNotEmpty) {
      return isId
          ? 'Saya belum bisa $actionLabel karena izin "$setting" di modul $module sedang nonaktif. Aktifkan dulu izin itu di halaman Modules, lalu coba lagi.'
          : 'I cannot $actionLabel because "$setting" is turned off in the $module module. Enable that permission in Modules first, then try again.';
    }

    return isId
        ? 'Saya belum bisa $actionLabel karena modul $module belum aktif. Aktifkan dulu modul itu di halaman Modules, lalu coba lagi.'
        : 'I cannot $actionLabel because the $module module is not active. Enable that module in Modules first, then try again.';
  }
}

class _SelectorValue {
  const _SelectorValue(this.value);

  final String value;
}

class _CompletionVerification {
  const _CompletionVerification({
    required this.ok,
    this.missingNames = const [],
    this.message = '',
    this.question = '',
  });

  final bool ok;
  final List<String> missingNames;
  final String message;
  final String question;
}

/// Riverpod provider for the runtime engine.
final agentRuntimeEngineProvider = Provider<AgentRuntimeEngine>((ref) {
  final languagePref = ref.watch(appLanguageProvider);
  return AgentRuntimeEngine(
    workspaceLoader: WorkspaceLoader(),
    toolRouter: ToolRouter(
      moduleRepository: ref.watch(moduleRepositoryProvider),
      agentRepository: ref.watch(agentRepositoryProvider),
      providerRepository: ref.watch(providerRepositoryProvider),
      saveAgent: ref.read(agentListProvider.notifier).save,
      deleteAgent: ref.read(agentListProvider.notifier).delete,
    ),
    contextBuilder: ContextBuilder(),
    languageCode: resolveLanguageCode(languagePref),
    snapshotBuilder: EcosystemSnapshotBuilder(
      moduleRepository: ref.watch(moduleRepositoryProvider),
      providerRepository: ref.watch(providerRepositoryProvider),
      workflowRepository: ref.watch(workflowRepositoryProvider),
    ),
    agentLoader: () => ref.read(agentListProvider),
  );
});
