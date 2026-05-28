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
import 'entity_resolver.dart';
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
      // Check if there's a pending action for this agent.
      final pending = _pendingActions[request.agentId];
      if (pending != null) {
        // Tier-1: deterministic ID/EN keyword check.
        var decision = ConfirmationChecker.check(request.userMessage);

        // Tier-2: LLM classifier when tier-1 unclear OR user language not
        // covered by tier-1 keyword maps. Keeps multilingual support working
        // without maintaining keyword sets per locale.
        final pendingLang = pending.languageCode;
        final coveredByTier1 =
            pendingLang == 'id' || pendingLang == 'en' ||
            detectedLang.code == 'id' || detectedLang.code == 'en';
        if (decision == ConfirmationDecision.unclear || !coveredByTier1) {
          final classifier = ConfirmationClassifier(
            client: client,
            config: llmConfig,
          );
          decision = await classifier.classify(
            userMessage: request.userMessage,
            pendingSummary: pending.userFacingSummary,
            languageCode: pendingLang,
          );
        }

        logger.logStateChange(
          AgentRuntimeState.analyzing,
          'Pending action detected: ${pending.toolName}, decision: ${decision.name}',
        );
        emit(logger.events.last);

        switch (decision) {
          case ConfirmationDecision.confirmed:
            // Execute the pending tool.
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
            _pendingActions.remove(request.agentId);
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
            // Don't execute. Generate preview lazily via verbalizer.
            _pendingActions.remove(request.agentId);
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
            // Let LLM decide with full context including pending action.
            break;
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
      final userNotIntroduced =
          WorkspaceLoader.isUserNameMissing(workspace.soul);
      // Tool list comes from the ToolRouter registry (system source of truth),
      // NOT from user-editable SKILLS.md template.
      final toolSelection = ToolCatalog.select(
        userMessage: request.userMessage,
        pendingAction: pending,
        isWorkflowAutoExecute: isWorkflowAutoExecute,
      );
      // Analyzer only needs name + description to classify intent.
      // Planner/selector/review need the full schema (risk, args, confirmation).
      var analyzerTools = toolRouter.buildAnalyzerToolDescriptions(
        toolSelection.toolNames,
      );
      var availableTools = toolRouter.buildToolDescriptions(
        toolSelection.toolNames,
      );
      if (availableTools.isEmpty) {
        analyzerTools = toolRouter.buildAllAnalyzerToolDescriptions();
        availableTools = toolRouter.buildAllToolDescriptions();
      }
      logger.logStateChange(
        AgentRuntimeState.analyzing,
        'Tool context: ${toolSelection.reason} '
        '(${availableTools.length} tools, confidence ${toolSelection.confidence.toStringAsFixed(2)})',
      );
      emit(logger.events.last);

      // Build recent messages for context (latest 20, chronological order).
      final sourceMessages = request.recentMessages;
      final latestMessages = sourceMessages.length > 20
          ? sourceMessages.sublist(sourceMessages.length - 20)
          : sourceMessages;
      final recentMsgs = latestMessages
          .map((m) => {'role': m.role, 'content': m.content})
          .toList();

      // If previous turn asked for missing info, merge this reply with the
      // original request before analysis. This prevents short follow-up answers
      // from being treated as standalone requests.
      final pendingClarification = _pendingClarifications[request.agentId];
      final effectiveUserMessage =
          pendingClarification != null && !pendingClarification.isExpired
          ? pendingClarification.mergedWith(request.userMessage)
          : request.userMessage;
      if (pendingClarification != null && pendingClarification.isExpired) {
        _pendingClarifications.remove(request.agentId);
      }

      // 2. Analyze.
      var state = AgentRuntimeState.analyzing;
      logger.logStateChange(state, 'Analyzing user intent');
      emit(logger.events.last);
      await workspaceLoader.updateHeartbeat(
        wsName,
        state: state.name,
        task: effectiveUserMessage,
      );

      final analysis = await planner.analyze(
        userMessage: effectiveUserMessage,
        workspace: workspace,
        availableTools: analyzerTools,
        logger: logger,
        recentMessages: recentMsgs,
        pendingAction: pending,
        recentToolMemory: _memory.formatForPrompt(request.agentId),
        isWorkflowAutoExecute: isWorkflowAutoExecute,
      );
      emit(logger.events.last);

      if (analysis == null) {
        return _fail('Failed to analyze request.', logger);
      }

      final analyzeNarrative = (analysis['narrative'] ?? '').toString();
      if (analyzeNarrative.isNotEmpty) {
        logger.logNarrative('analyze', analyzeNarrative);
        emit(logger.events.last);
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
        logger.logLlmDecision('reflect', reflection.toJson());
        emit(logger.events.last);

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
        final baseSystem = '${_directResponseRulesFor(
              languageLabel: detectedLang.label,
              isWorkflowAutoExecute: isWorkflowAutoExecute,
              userNotIntroduced: userNotIntroduced,
            )}\n\n$identityBlock';
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
              userMessage: request.userMessage,
            );
      logger.logLlmDecision('plan.goal_tree', goalTree.toJson());

      // 4. Execute loop.
      return _executeLoop(
        request: request,
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

          // If the tree is now complete, finish with a holistic recap.
          if (goalTree.isComplete) {
            final successMsg = await _finalForCompletedTree(
              goalTree: goalTree,
              fallbackTool: toolRequest,
              fallbackResult: result,
              verbalizer: verbalizer,
              language: detectedLang,
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
          final plan = (resume['plan'] as Map?)?.cast<String, dynamic>() ??
              {'steps': []};
          final previousResults = (resume['previous_results'] as List?)
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
          final availableTools = (resume['available_tools'] as List?)
                  ?.map((e) => e.toString())
                  .toList() ??
              const <String>[];
          final memorySnapshot =
              (resume['memory_snapshot'] as String?) ?? '';
          final autoApproveSensitive =
              resume['auto_approve_sensitive'] as bool? ?? false;
          final isWorkflowAutoExecute =
              resume['is_workflow_auto_execute'] as bool? ?? false;
          final currentStep = (resume['current_step'] as int? ?? 1) + 1;
          final userMessage =
              (resume['user_message'] as String?) ?? request.userMessage;

          // Reconstruct the request so memory + heartbeats keep the original
          // task context intact during the resumed loop.
          final resumedRequest = AgentRuntimeRequest(
            agentId: request.agentId,
            agentName: request.agentName,
            userMessage: userMessage,
            recentMessages: request.recentMessages,
            source: request.source,
          );

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
        final successMsg = await verbalizer.success(
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
      logger.logFinalResponse(fallbackMsg);
      return AgentRuntimeResponse(
        finalMessage: fallbackMsg,
        success: false,
        state: AgentRuntimeState.done,
        events: logger.events,
      );
    } catch (e) {
      logger.logError('Runtime exception', e);
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
    final previousResults = <Map<String, dynamic>>[
      ...?initialPreviousResults,
    ];
    var currentStep = initialStep;
    var retryCount = 0;
    var rePlanned = false;
    final stuck = StuckDetector();

    // Adaptive budget: base + 2 steps per subgoal, hard-capped at maxSteps×3
    // for safety. Multi-target tasks need more headroom than the legacy 5.
    final adaptiveLimit = goalTree.isEmpty
        ? maxSteps
        : (maxSteps + goalTree.subgoals.length * 2)
            .clamp(maxSteps, maxSteps * 3);

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
        return _fail('Tool selection failed.', logger);
      }

      final selectNarrative = (selection['narrative'] ?? '').toString();
      if (selectNarrative.isNotEmpty) {
        logger.logNarrative('select_tool', selectNarrative);
        emit(logger.events.last);
      }

      final status = selection['status'] as String? ?? '';

      if (status == 'done') {
        // Reviewer/selector wants to wrap up. Honor it only when the goal
        // tree agrees — otherwise it would short-circuit a multi-target task
        // (the original "buat 3 agen → 1 agen" bug).
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

        final finalResponse =
            selection['final_response'] as String? ?? 'Task completed.';

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
        return _fail(
          selection['error'] as String? ?? 'Runtime failed.',
          logger,
        );
      }

      if (status == 'tool_required') {
        final toolJson = selection['tool'] as Map<String, dynamic>?;
        if (toolJson == null) {
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

        // Check confirmation requirement from REGISTRY.
        // Skip the gate when the caller (e.g., a sensitive workflow) opted in.
        if (definition.requiresConfirmation && !autoApproveSensitive) {
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
              );
              ledgerIdForPending = ledger.id;
            }
            resumeContext = {
              'ledger_id': ?ledgerIdForPending,
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
        final treeAllowsShortCircuit =
            goalTree.isEmpty || goalTree.isComplete;
        if (result.success &&
            _isLastPlannedStep(plan, currentStep) &&
            treeAllowsShortCircuit) {
          final localFinal = await _finalForCompletedTree(
            goalTree: goalTree,
            fallbackTool: toolRequest,
            fallbackResult: result,
            verbalizer: verbalizer,
            language: detectedLang,
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
            final ok = goalTree.applyStatusUpdate(
              subgoalId: (update['id'] ?? '').toString(),
              status: SubgoalStatusX.fromLabel(update['status'] as String?),
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
          }
        }

        if (review == null) {
          return _fail('Review phase failed.', logger);
        }

        final reviewStatus = review['status'] as String? ?? '';

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
              'note': 'Reviewer status=done overridden because subgoals remain.',
            });
            currentStep++;
            retryCount = 0;
            continue;
          }

          final finalResponse =
              review['final_response'] as String? ?? 'Task completed.';
          // For multi-subgoal tasks, override the reviewer's per-tool reply
          // with a holistic recap covering every completed subgoal.
          final completedFinal = goalTree.isNotEmpty &&
                  goalTree.subgoals
                          .where((s) =>
                              s.status == SubgoalStatus.done ||
                              s.status == SubgoalStatus.failed ||
                              s.status == SubgoalStatus.skipped)
                          .length >
                      1
              ? await _finalForCompletedTree(
                  goalTree: goalTree,
                  fallbackTool: toolRequest,
                  fallbackResult: result,
                  verbalizer: verbalizer,
                  language: detectedLang,
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
          return AgentRuntimeResponse(
            finalMessage: review['question'] as String? ?? 'Need more info.',
            success: true,
            state: AgentRuntimeState.askingUser,
            events: logger.events,
          );
        }

        if (reviewStatus == 'failed') {
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
    final mainGoal = (plan['main_goal'] as String?) ??
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
            Subgoal(
              id: 'sg${i + 1}',
              label: seeds[i].toString(),
            ),
        ],
      );
    }

    // Single-subgoal fallback so the rest of the loop has consistent shape.
    return GoalTree.singleSubgoal(
      mainGoal: mainGoal,
      subgoalLabel: mainGoal,
    );
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
      return ledgerDb.upsert(existing);
    }

    final ledger = TaskLedger(
      id: 'lg_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
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
      currentStep: currentStep,
      availableTools: availableTools,
      memorySnapshot: memorySnapshot,
      autoApproveSensitive: autoApproveSensitive,
      isWorkflowAutoExecute: isWorkflowAutoExecute,
    );
    return ledgerDb.upsert(ledger);
  }

  /// Archive a ledger as completed when the goal tree finishes successfully.
  /// No-op when no ledger exists for the (agentId, source) scope.
  Future<void> _archiveLedgerForRequest(
    AgentRuntimeRequest request,
    LedgerStatus terminal,
  ) async {
    final source = request.source == RequestSource.workflow
        ? LedgerSource.workflow
        : LedgerSource.chat;
    final active = await ledgerDb.findActive(
      agentId: request.agentId,
      source: source,
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
  }) {
    final completed = goalTree.subgoals
        .where((s) =>
            s.status == SubgoalStatus.done ||
            s.status == SubgoalStatus.failed ||
            s.status == SubgoalStatus.skipped)
        .toList();

    if (goalTree.isNotEmpty && completed.length > 1) {
      return verbalizer.taskSummary(
        mainGoal: goalTree.mainGoal,
        completedSubgoals: completed
            .map((s) => <String, dynamic>{
                  'label': s.label,
                  'status': s.status.label,
                  if (s.notes != null && s.notes!.isNotEmpty) 'notes': s.notes,
                })
            .toList(),
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
  /// Inspects the tool's args for fields that look like an entity reference
  /// (`name`, `agentName`, `workflowId`, etc.) and runs them through the
  /// ecosystem snapshot via [EntityResolver]. Returns:
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
  }) async {
    // Only check existing-target operations. Heuristic on tool name suffix
    // catches the common cases (delete/update/rename/toggle/get).
    final name = tool.name.toLowerCase();
    final isExistingTargetOp = name.contains('.delete') ||
        name.contains('.update') ||
        name.contains('.rename') ||
        name.contains('.toggle') ||
        name.endsWith('.read') ||
        name.endsWith('.get');
    if (!isExistingTargetOp) return null;

    final snapshot = await _buildSnapshot();
    if (snapshot.isEmpty) return null;

    // Try the obvious arg keys first. Order matters — id > explicit name.
    final candidates = _candidatesForTool(name, snapshot);
    if (candidates.isEmpty) return null;

    final argKeys = const [
      'name',
      'agentName',
      'workflowName',
      'title',
      'label',
      'id',
      'agentId',
      'workflowId',
    ];
    String? userTyped;
    for (final k in argKeys) {
      final v = tool.args[k];
      if (v is String && v.trim().isNotEmpty) {
        userTyped = v.trim();
        break;
      }
    }
    if (userTyped == null) return null;

    final match = EntityResolver.resolve(userTyped, candidates);
    if (match.isExact) return null;

    final entityType = _entityTypeForTool(name);
    return verbalizer.clarifyTarget(
      entityType: entityType,
      userTyped: userTyped,
      suggestion: match.isNear ? match.matched : null,
      available: match.suggestions,
      language: language,
    );
  }

  /// Maps a tool name to the snapshot section it operates on.
  List<String> _candidatesForTool(String toolName, EcosystemSnapshot snapshot) {
    if (toolName.startsWith('system.agents.')) {
      return [for (final a in snapshot.agents) a.name];
    }
    if (toolName.startsWith('workflow.')) {
      return [for (final w in snapshot.workflows) w.title];
    }
    if (toolName.startsWith('system.providers.')) {
      return [for (final p in snapshot.providers) p.nickname];
    }
    if (toolName.startsWith('system.modules.')) {
      return [for (final m in snapshot.modules) m.id];
    }
    return const [];
  }

  String _entityTypeForTool(String toolName) {
    if (toolName.startsWith('system.agents.')) return 'agent';
    if (toolName.startsWith('workflow.')) return 'workflow';
    if (toolName.startsWith('system.providers.')) return 'provider';
    if (toolName.startsWith('system.modules.')) return 'module';
    return 'item';
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
