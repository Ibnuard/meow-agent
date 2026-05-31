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
import 'language_registry.dart';
import 'pending_action.dart';
import 'pending_clarification.dart';
import 'planner.dart';
import 'completion_verifier.dart';
import 'confirmation_manager.dart';
import 'preflight_checker.dart';
import 'post_execute_validator.dart';
import 'prompt_constants.dart';
import 'recovery_coordinator.dart';
import 'reflector.dart';
import 'runtime_logger.dart';
import 'runtime_memory.dart';
import 'runtime_models.dart';
import 'target_resolution.dart';
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
    OpenAiCompatibleClient? llmClient,
    Future<EcosystemSnapshot> Function()? snapshotOverride,
  }) : ledgerDb = ledgerDb ?? TaskLedgerDatabase(),
       _client = llmClient ?? OpenAiCompatibleClient(),
       _snapshotOverride = snapshotOverride {
    _preflight = PreflightChecker(
      snapshotBuilder: _snapshotOverride ?? () => _buildSnapshot(),
    );
    _completionVerifier = CompletionVerifier(
      agentLoader: agentLoader,
    );
    _confirmation = ConfirmationManager(
      ledgerDb: this.ledgerDb,
      languageCode: languageCode,
      llmClient: _client,
      onExecutePendingTool: ({
        required AgentRuntimeRequest request,
        required PendingAction pending,
        required Executor executor,
        required ToolVerbalizer verbalizer,
        required DetectedLanguage detectedLang,
        required RuntimeLogger logger,
        required void Function(RuntimeEvent) emit,
      }) => _executePendingTool(
        request: request,
        pending: pending,
        executor: executor,
        verbalizer: verbalizer,
        detectedLang: detectedLang,
        logger: logger,
        emit: emit,
      ),
      onFinishTaskScope: (request, terminal) =>
          _finishTaskScopeForRequest(request, terminal),
    );
  }

  final WorkspaceLoader workspaceLoader;
  final ToolRouter toolRouter;
  final ContextBuilder contextBuilder;
  final String languageCode;

  /// Optional ecosystem snapshot builder. When null, reflection runs without
  /// snapshot context (still useful for slot extraction).
  final EcosystemSnapshotBuilder? snapshotBuilder;

  /// Loader for the current agent registry. Optional â€” reflection still works
  /// without it but loses cross-reference detection.
  final List<AgentModel> Function()? agentLoader;

  /// Persistent ledger store for multi-step tasks. Single-target work keeps
  /// using [PendingAction] in-memory; multi-target work creates a ledger
  /// row that survives app restarts and confirmation gates.
  final TaskLedgerDatabase ledgerDb;

  /// Shared LLM client. Reused across all turns of this engine instance so
  /// the underlying Dio's connection pool can keep keep-alive sockets warm.
  /// Injectable (defaults to a real client) so tests can script phase responses.
  final OpenAiCompatibleClient _client;

  /// Optional test/override hook for the ecosystem snapshot. When set, it
  /// fully replaces [snapshotBuilder]/[agentLoader] snapshot construction.
  final Future<EcosystemSnapshot> Function()? _snapshotOverride;

  late final PreflightChecker _preflight;
  late final CompletionVerifier _completionVerifier;
  late final ConfirmationManager _confirmation;

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
  /// Owned by [ConfirmationManager]; kept here as a convenience getter for
  /// engine methods that reference the map directly.
  Map<String, PendingAction> get _pendingActions => _confirmation.pendingActions;

  /// Agents whose in-flight task has been cancelled by the user.
  /// Checked cooperatively inside [_executeLoop] to bail out early.
  final Set<String> _cancelledAgents = {};

  /// Pending clarification per agent.
  /// Owned by [ConfirmationManager]; kept here as a convenience getter for
  /// engine methods that reference the map directly.
  Map<String, PendingClarification> get _pendingClarifications =>
      _confirmation.pendingClarifications;

  /// Per-agent scratchpad: remembers recent tool calls + structured results.
  /// Persists across turns so the planner can reference prior tool output
  /// (e.g. noteId from notes.search when user later says "hapus yang itu").
  final RuntimeMemory _memory = RuntimeMemory();

  /// Per-turn user-message language detector. Drives every user-facing string.
  final LanguageDetector _languageDetector = LanguageDetector();

  /// Get pending action for an agent.
  PendingAction? getPendingAction(String agentId) =>
      _confirmation.getPending(agentId);

  /// Clear pending action for an agent.
  void clearPendingAction(String agentId) =>
      _confirmation.clearPending(agentId);

  /// Clear pending clarification for an agent.
  void clearPendingClarification(String agentId) =>
      _confirmation.clearClarification(agentId);

  /// Abort the current chat task scope for an agent.
  ///
  /// Used by the UI reject path: clearing the visible confirmation is not
  /// enough, because a persisted ledger can otherwise rehydrate the same
  /// pending tool on the next user turn.
  Future<void> abortActiveTask(
    String agentId, {
    RequestSource source = RequestSource.chat,
  }) async {
    _cancelledAgents.add(agentId);
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
    // Clear any prior cancellation flag for this agent.
    _cancelledAgents.remove(request.agentId);
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

    // Bootstrap language detection for THIS turn (script-based, no LLM).
    // For non-Latin scripts this is already authoritative; for Latin scripts
    // it is a provisional value (the app-setting fallback) that the analyzer's
    // `detected_language` refines below. Drives every user-facing string built
    // by the verbalizer.
    var detectedLang = _languageDetector.detect(
      userMessage: request.userMessage,
      fallbackCode: languageCode,
    );
    logger.logStateChange(
      AgentRuntimeState.analyzing,
      'Language bootstrap: ${detectedLang.code} '
      '(${detectedLang.script}, conf ${detectedLang.confidence.toStringAsFixed(2)})',
    );
    emit(logger.events.last);

    final verbalizer = ToolVerbalizer(client: client, config: llmConfig);
    verbalizer.resetTurn();

    try {
      // Resume from a persisted ledger if the in-memory pending was lost
      // (e.g. app was killed). Best-effort â€” unable-to-resume cases just
      // proceed normally and the next turn will plan from scratch.
      try {
        await _confirmation.maybeRestoreFromLedger(request.agentId);
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

        final pendingResponse = await _confirmation.handleDecision(
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
      // Workflow runs are owned by the WorkflowRunner, not the engine. A
      // workflow step must never resume from a workflow-scoped ledger â€”
      // otherwise two steps sharing an agent collide on the same
      // (agentId, workflow) row and bleed state across steps. Chat keeps the
      // resume lookup.
      final activeLedger = request.source == RequestSource.workflow
          ? null
          : await ledgerDb.findActive(
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

      // Refine the turn language from the analyzer's authoritative
      // classification. The LLM natively knows the user's language, so this
      // corrects the Latin-script bootstrap (which only had the app-setting
      // fallback). Non-Latin scripts already detected with high confidence are
      // left alone unless the analyzer clearly disagrees. This is what makes
      // the engine language-generic without per-language word lists.
      final analyzerLangCode = (analysis['detected_language'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      if (analyzerLangCode.isNotEmpty &&
          analyzerLangCode != detectedLang.code &&
          (!detectedLang.isHighConfidence || detectedLang.script == 'Latin')) {
        final refined = DetectedLanguage.fromAnalyzerCode(analyzerLangCode);
        logger.logStateChange(
          AgentRuntimeState.analyzing,
          'Language refined by analyzer: ${detectedLang.code} '
          'â†’ ${refined.code} (${refined.label})',
        );
        emit(logger.events.last);
        detectedLang = refined;
      }

      // Narrow the downstream tool surface from the analyzer's tool_groups
      // classification (language-agnostic â€” replaces keyword matching). The
      // analyzer saw the full slim catalog; now reflect/plan and the skip
      // conditions operate on the model-chosen groups. Skipped while an active
      // task context exists (the broad catalog is intentionally used there so a
      // new in-flight task in any domain stays reachable).
      if (activeTaskContext.isEmpty) {
        final groupsHint = (analysis['tool_groups'] as List?)
            ?.map((e) => e.toString())
            .toList();
        final narrowed = ToolCatalog.fromGroups(groupsHint);
        final narrowedAvailable = toolRouter.buildToolDescriptions(
          narrowed.toolNames,
        );
        if (narrowedAvailable.isNotEmpty) {
          toolSelection = narrowed;
          analyzerTools = toolRouter.buildAnalyzerToolDescriptions(
            narrowed.toolNames,
          );
          availableTools = narrowedAvailable;
          logger.logStateChange(
            AgentRuntimeState.analyzing,
            'Tool surface narrowed from analyzer tool_groups: '
            '${narrowed.reason} (${availableTools.length} tools, '
            'confidence ${narrowed.confidence.toStringAsFixed(2)})',
          );
          emit(logger.events.last);
        }
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
          activeTaskContext = '';

          // Re-narrow tools from the analyzer's tool_groups now that the
          // active-task context is cleared. Without this the downstream phases
          // see the full catalog, the reflector has no authoritative shortlist,
          // and stale conversation history bleeds into the reflect prompt â€”
          // causing it to produce a goal tree from a prior turn.
          final groupsHint = (analysis['tool_groups'] as List?)
              ?.map((e) => e.toString())
              .toList();
          final narrowed = ToolCatalog.fromGroups(groupsHint);
          final narrowedAvailable = toolRouter.buildToolDescriptions(
            narrowed.toolNames,
          );
          if (narrowedAvailable.isNotEmpty) {
            toolSelection = narrowed;
            analyzerTools = toolRouter.buildAnalyzerToolDescriptions(
              narrowed.toolNames,
            );
            availableTools = narrowedAvailable;
          } else {
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
            'new_task classification. Tools re-narrowed to '
            '${availableTools.length} from analyzer tool_groups. '
            'Heads-up surfaced.',
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
          final pendingResponse = await _confirmation.handleDecision(
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

      // 2.5 Reflection (deep-thinking phase).
      // Builds an ecosystem snapshot, asks the LLM to decide a strategy
      // (direct_execute / clarify / auto_resolve / block), and short-circuits
      // when the strategy demands user input or refusal.
      //
      // Stage 2: reflection is SKIPPED for trivial, high-confidence,
      // single-tool, safe turns. For those, the analyzer already has every
      // signal reflection would echo (no missing info, single tool group, not
      // bulk, not destructive), and the live snapshot shows no cross-entity
      // impact to reason about. Skipping removes one full LLM round-trip per
      // simple turn. The two safety valves â€” a non-safe/destructive intent OR
      // an ecosystem with cross-references â€” force reflection back on, so
      // anything that could surprise the user still gets the deep-thinking pass.
      ReflectionOutput? reflection;
      TargetResolutionGraph? targetGraph;
      final analyzerSaysToolsForReflect = analysis['requires_tools'] == true;

      // Snapshot is opt-in via the engine constructor. When the loader is
      // missing (tests, sandbox), this is empty and isRelevantForReflection
      // is false. Built once here and reused by the reflect call below.
      final reflectSnapshot = analyzerSaysToolsForReflect
          ? await _buildSnapshot()
          : EcosystemSnapshot(
              agents: const [],
              workflows: const [],
              providers: const [],
              modules: const [],
              builtAt: DateTime.fromMillisecondsSinceEpoch(0),
            );

      final canSkipReflect =
          analyzerSaysToolsForReflect &&
          !isWorkflowAutoExecute &&
          toolSelection.isHighConfidence &&
          toolSelection.groups.length == 1 &&
          missingInfo.isEmpty &&
          analysis['bulk_selector'] != true &&
          !_isDestructiveIntent(analysis) &&
          !reflectSnapshot.isRelevantForReflection;

      final shouldReflect =
          analyzerSaysToolsForReflect &&
          !isWorkflowAutoExecute &&
          !canSkipReflect;
      if (shouldReflect) {
        state = AgentRuntimeState.analyzing;
        logger.logStateChange(state, 'Reflecting on impact and slot needs');
        emit(logger.events.last);

        final snapshot = reflectSnapshot;

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

        // Strategy: clarify â€” ask the user one short combined question.
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

        // Strategy: block â€” polite refusal with reason.
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
        // Strategy: auto_resolve and direct_execute â€” continue to planning.
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
            'Identity context (from SOUL.md â€” user-editable):\n${workspace.soul}';
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
        // Inject world-model awareness so the model knows it is Meow Agent
        // (not a generic LLM) and has accurate knowledge of its own schema.
        final worldModelBlock =
            '\n\nMEOW AGENT WORLD MODEL:\n'
            'You are an Android-native AI agent, NOT a generic LLM or '
            'terminal-based assistant. Your workspace is a sandbox at '
            'Documents/MeowAgent/, rooted at your agent folder.\n'
            '${PromptConstants.systemMarkdownMap}';
        final baseSystem =
            '${_directResponseRulesFor(languageLabel: detectedLang.label, isWorkflowAutoExecute: isWorkflowAutoExecute, userNotIntroduced: userNotIntroduced)}\n\n$identityBlock$worldModelBlock$toolMemoryBlock';
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
      // CRITICAL: never take the fast path when:
      // 1. The analyzer enumerated multiple subgoal_seeds (explicit "create
      //    3 agents X, Y, Z" pattern), OR
      // 2. The reflector â€” including the deterministic bulk expander â€”
      //    produced a goal tree or target list with more than one entry
      //    (e.g. "delete all workflows" was fanned out from snapshot).
      //
      // A 1-step synthetic plan would short-circuit the loop before the
      // remaining subgoals ever ran (the "buat 3 agen â†’ 1 agen" bug, and
      // the "set semua workflow â†’ 1 update" bug).
      final seeds = analysis['subgoal_seeds'];
      final hasMultiSeed = seeds is List && seeds.length > 1;
      final analyzerBulk = analysis['bulk_selector'] == true;
      final reflectorMultiSubgoal =
          reflection != null && reflection.goalTree.subgoals.length > 1;
      final reflectorMultiTarget =
          reflection != null && reflection.targets.length > 1;
      final hasMultiTarget =
          hasMultiSeed ||
          analyzerBulk ||
          reflectorMultiSubgoal ||
          reflectorMultiTarget;
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
          // Pre-loop recovery: retry once with the full tool catalog before
          // giving up. Mirrors the in-loop rethink behavior â€” broaden the
          // tool set when the original selection didn't yield a plan.
          logger.logError(
            'Planner returned null on first attempt; retrying with broadened tools.',
          );
          final broadenedAnalyzer = toolRouter
              .buildAllAnalyzerToolDescriptions();
          plan = await planner.plan(
            analysis: analysis,
            availableTools: broadenedAnalyzer.isNotEmpty
                ? broadenedAnalyzer
                : toolRouter.buildAllToolDescriptions(),
            logger: logger,
          );
          emit(logger.events.last);
        }

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
      // Reflection's goal tree wins when available â€” it has the most accurate
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

      // 4. Execute loop with recovery + post-execute verification.
      final recovery = RecoveryCoordinator();
      final validator = PostExecuteValidator(
        snapshotBuilder: () async => _buildSnapshot(),
      );

      // Capture a non-nullable snapshot of analysis for the rethink closure.
      // The null check above guarantees analysis is non-null here, but
      // Dart's flow analysis cannot carry that promotion into the closure
      // body, so we promote explicitly.
      final capturedAnalysis = Map<String, dynamic>.from(analysis);

      Future<({Map<String, dynamic> plan, GoalTree goalTree})?>
      rethink() async {
        try {
          final freshSnapshot = await _buildSnapshot();
          final freshAnalysis = Map<String, dynamic>.from(capturedAnalysis);
          final priorContext = recovery.toReflectionContextList();
          if (priorContext.isNotEmpty) {
            freshAnalysis['prior_attempts'] = priorContext;
          }

          // On recovery, broaden the tool set. The original selection might
          // have missed the right tool category; giving the planner the full
          // catalog lets it pivot to a different approach.
          final broadenedTools = toolRouter.buildAllToolDescriptions();
          final broadenedAnalyzerTools = toolRouter
              .buildAllAnalyzerToolDescriptions();
          freshAnalysis['available_tools_broadened'] = true;

          final reReflection = await reflector.reflect(
            userMessage: effectiveUserMessage,
            analysis: freshAnalysis,
            snapshot: freshSnapshot,
            availableTools: _toolDefinitionsFor(
              toolRouter.registeredTools.toSet(),
            ),
            language: detectedLang,
            logger: logger,
            recentMessages: recentMsgs,
          );
          final newPlan = await planner.plan(
            analysis: freshAnalysis,
            availableTools: broadenedAnalyzerTools.isNotEmpty
                ? broadenedAnalyzerTools
                : broadenedTools,
            logger: logger,
          );
          if (newPlan == null) return null;

          final newTree = reReflection.goalTree.isNotEmpty
              ? reReflection.goalTree
              : _buildGoalTree(
                  plan: newPlan,
                  analysis: freshAnalysis,
                  userMessage: effectiveUserMessage,
                );
          return (plan: newPlan, goalTree: newTree);
        } catch (e) {
          logger.logError('Recovery rethink failed', e);
          return null;
        }
      }

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
        recovery: recovery,
        postExecuteValidator: validator,
        rethink: rethink,
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
  ///
  /// Delegates to [ConfirmationManager.executeConfirmed] which creates the
  /// executor/verbalizer, builds the pending action, and calls back into
  /// [_executePendingTool] for the actual execution.
  Future<AgentRuntimeResponse> executeConfirmed(
    AgentRuntimeRequest request, {
    required ProviderConfig provider,
    required String toolName,
    required Map<String, dynamic> toolArgs,
    RuntimeEventCallback? onEvent,
  }) {
    return _confirmation.executeConfirmed(
      request,
      provider: provider,
      toolName: toolName,
      toolArgs: toolArgs,
      onEvent: onEvent,
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
      // detected language. Generic across all tools â€” no per-tool switch.
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
            final verificationBlocker = await _completionVerifier.blockIfUnverified(
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
              parkTask: (questions) => _parkTaskForUserInput(
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
                questions: questions,
              ),
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
      // fails fall back to the verbalizer abort message â€” never a raw error.
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
    RecoveryCoordinator? recovery,
    PostExecuteValidator? postExecuteValidator,
    Future<({Map<String, dynamic> plan, GoalTree goalTree})?> Function()?
    rethink,
    bool autoApproveSensitive = false,
    bool isWorkflowAutoExecute = false,
    List<Map<String, dynamic>>? initialPreviousResults,
    int initialStep = 1,
    int nullSelectionRecoveryCount = 0,
  }) async {
    final previousResults = <Map<String, dynamic>>[...?initialPreviousResults];
    var currentStep = initialStep;
    var retryCount = 0;
    var rePlanned = false;
    final stuck = StuckDetector();

    // Idempotency tracking for delivery/side-effect tools. A delivery to the
    // SAME destination (e.g. chat.send to the same agent) must not fire twice
    // in one task run. This guards against plans that conflate "compose" and
    // "send" into separate subgoals, which made the loop re-pick chat.send
    // after it already succeeded and deliver a duplicate message.
    final deliveredKeys = <String>{};
    ToolCallRequest? lastDeliveryTool;
    ToolExecutionResult? lastDeliveryResult;

    // Conversation history snapshot (latest 20, chronological). Carries the
    // previous workflow step's output as the most recent assistant turn. Fed
    // to the selector + reviewer so tool arguments (e.g. chat.send content)
    // and synthesized summaries are grounded on real data, not hallucinated.
    final loopRecentMsgs = () {
      final src = request.recentMessages;
      final latest = src.length > 20 ? src.sublist(src.length - 20) : src;
      return latest.map((m) => {'role': m.role, 'content': m.content}).toList();
    }();

    // Adaptive budget: base + 2 steps per subgoal, hard-capped at maxStepsÃ—3
    // for safety. Multi-target tasks need more headroom than the legacy 5.
    final adaptiveLimit = goalTree.isEmpty
        ? maxSteps
        : (maxSteps + goalTree.subgoals.length * 2).clamp(
            maxSteps,
            maxSteps * 3,
          );

    for (var i = 0; i < adaptiveLimit; i++) {
      // Cooperative cancellation check.
      if (_cancelledAgents.contains(request.agentId)) {
        _cancelledAgents.remove(request.agentId);
        return AgentRuntimeResponse(
          finalMessage: '',
          success: false,
          state: AgentRuntimeState.failed,
        );
      }

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
        recentMessages: loopRecentMsgs,
      );
      emit(logger.events.last);

      if (selection == null) {
        // Hard-fail if we've already attempted a null-selection recovery
        // once. Otherwise we recurse forever in the
        // "no tool found â†’ rethink â†’ no tool found" loop.
        if (nullSelectionRecoveryCount >= 1) {
          logger.logNarrative(
            'recovery',
            'Repeated null tool selection. Aborting to prevent infinite loop.',
          );
          await _finishTaskScopeForRequest(request, LedgerStatus.failed);
          return _fail(_capabilityNotFoundMessage(detectedLang), logger);
        }
        final recoveryDecision = await _maybeRecover(
          recovery: recovery,
          rethink: rethink,
          reason: 'selector_null',
          stageHint: 'select_tool',
          logger: logger,
        );
        if (recoveryDecision != null) {
          return _executeLoop(
            request: request,
            plan: recoveryDecision.plan,
            goalTree: recoveryDecision.goalTree,
            executor: executor,
            verbalizer: verbalizer,
            detectedLang: detectedLang,
            availableTools: availableTools,
            logger: logger,
            emit: emit,
            memorySnapshot: memorySnapshot,
            recovery: recovery,
            postExecuteValidator: postExecuteValidator,
            rethink: rethink,
            autoApproveSensitive: autoApproveSensitive,
            isWorkflowAutoExecute: isWorkflowAutoExecute,
            nullSelectionRecoveryCount: nullSelectionRecoveryCount + 1,
          );
        }
        await _finishTaskScopeForRequest(request, LedgerStatus.failed);
        return _fail(
          recovery?.giveUpMessage(detectedLang) ??
              _capabilityNotFoundMessage(detectedLang),
          logger,
        );
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
        // tree agrees â€” otherwise it would short-circuit a multi-target task
        // (the original "buat 3 agen â†’ 1 agen" bug).
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

        final verificationBlocker = await _completionVerifier.blockIfUnverified(
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
          parkTask: (questions) => _parkTaskForUserInput(
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
            questions: questions,
          ),
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
        final recoveryDecision = await _maybeRecover(
          recovery: recovery,
          rethink: rethink,
          reason: 'selector_failed',
          stageHint: 'select_tool',
          errorSummary: selection['error']?.toString() ?? '',
          logger: logger,
        );
        if (recoveryDecision != null) {
          return _executeLoop(
            request: request,
            plan: recoveryDecision.plan,
            goalTree: recoveryDecision.goalTree,
            executor: executor,
            verbalizer: verbalizer,
            detectedLang: detectedLang,
            availableTools: availableTools,
            logger: logger,
            emit: emit,
            memorySnapshot: memorySnapshot,
            recovery: recovery,
            postExecuteValidator: postExecuteValidator,
            rethink: rethink,
            autoApproveSensitive: autoApproveSensitive,
            isWorkflowAutoExecute: isWorkflowAutoExecute,
          );
        }
        await _finishTaskScopeForRequest(request, LedgerStatus.failed);
        return _fail(
          recovery?.giveUpMessage(detectedLang) ??
              (selection['error'] as String? ?? 'Runtime failed.'),
          logger,
        );
      }

      if (status == 'tool_required') {
        final toolJson = selection['tool'] as Map<String, dynamic>?;
        if (toolJson == null) {
          final recoveryDecision = await _maybeRecover(
            recovery: recovery,
            rethink: rethink,
            reason: 'selector_missing_tool',
            stageHint: 'select_tool',
            logger: logger,
          );
          if (recoveryDecision != null) {
            return _executeLoop(
              request: request,
              plan: recoveryDecision.plan,
              goalTree: recoveryDecision.goalTree,
              executor: executor,
              verbalizer: verbalizer,
              detectedLang: detectedLang,
              availableTools: availableTools,
              logger: logger,
              emit: emit,
              memorySnapshot: memorySnapshot,
              recovery: recovery,
              postExecuteValidator: postExecuteValidator,
              rethink: rethink,
              autoApproveSensitive: autoApproveSensitive,
              isWorkflowAutoExecute: isWorkflowAutoExecute,
            );
          }
          await _finishTaskScopeForRequest(request, LedgerStatus.failed);
          return _fail(
            recovery?.giveUpMessage(detectedLang) ??
                'Tool selection returned no tool data.',
            logger,
          );
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
              'Stuck loop detected (same call Ã—3). Forcing one re-plan.',
            );
            previousResults.add({
              'step': currentStep,
              'note':
                  'Detected stuck loop on ${toolRequest.name}. Reconsider approach for active subgoal.',
            });
            currentStep++;
            continue;
          }
          // Already re-planned and still stuck â€” try recovery before giving
          // up. The recovery flow re-reflects with the failure context AND
          // broadens the tool set, which often unsticks loops caused by a
          // missing-tool blind spot.
          final recoveryDecision = await _maybeRecover(
            recovery: recovery,
            rethink: rethink,
            failedTool: toolRequest,
            reason: 'stuck_loop',
            logger: logger,
          );
          if (recoveryDecision != null) {
            stuck.reset();
            rePlanned = false;
            return _executeLoop(
              request: request,
              plan: recoveryDecision.plan,
              goalTree: recoveryDecision.goalTree,
              executor: executor,
              verbalizer: verbalizer,
              detectedLang: detectedLang,
              availableTools: availableTools,
              logger: logger,
              emit: emit,
              memorySnapshot: memorySnapshot,
              recovery: recovery,
              postExecuteValidator: postExecuteValidator,
              rethink: rethink,
              autoApproveSensitive: autoApproveSensitive,
              isWorkflowAutoExecute: isWorkflowAutoExecute,
            );
          }
          // No recovery possible â€” abort with a localized message.
          final abortMsg =
              recovery?.giveUpMessage(detectedLang) ??
              await verbalizer.abort(
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
        final preflight = await _preflight.check(
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
          // Workflow runs never park for confirmation. If "Allow sensitive
          // actions" is off and a step reaches a sensitive tool, fail closed
          // with a distinct state so the runner can destroy the chain and tell
          // the user exactly which step needs permission. No pending action,
          // no zombie task.
          if (request.source == RequestSource.workflow) {
            logger.logStateChange(
              AgentRuntimeState.blockedSensitive,
              'Sensitive action blocked in workflow (allow-sensitive off): '
              '${toolRequest.name}',
            );
            emit(logger.events.last);
            await _finishTaskScopeForRequest(request, LedgerStatus.failed);
            return AgentRuntimeResponse(
              finalMessage: '',
              success: false,
              state: AgentRuntimeState.blockedSensitive,
              events: logger.events,
              pendingTool: toolRequest.name,
              pendingToolArgs: toolRequest.args,
            );
          }
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
            // Multi-subgoal scope â€” persist a ledger so the task survives the
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

          // Store as pending action â€” language is captured for follow-up turns.
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

        // Duplicate-delivery guard. If this is a delivery tool targeting a
        // destination we've already delivered to in this run, suppress the
        // re-send. Plans that split "compose" and "send" into separate
        // subgoals otherwise re-pick chat.send and spam the user with a
        // second copy of the same message.
        final deliveryKey = _deliveryDestinationKey(toolRequest);
        if (deliveryKey != null && deliveredKeys.contains(deliveryKey)) {
          logger.logStateChange(
            state,
            'Duplicate delivery suppressed: ${toolRequest.name} to an '
            'already-delivered destination ($deliveryKey).',
          );
          emit(logger.events.last);
          // Advance the active subgoal so the tree doesn't softlock on a
          // "send" subgoal that is effectively already satisfied.
          if (goalTree.isNotEmpty) {
            final active = goalTree.nextActionable;
            if (active != null) active.status = SubgoalStatus.done;
          }
          if (goalTree.isEmpty || goalTree.isComplete) {
            final priorTool = lastDeliveryTool ?? toolRequest;
            final priorResult =
                lastDeliveryResult ??
                ToolExecutionResult(success: true, toolName: toolRequest.name);
            final finalMsg = await verbalizer.success(
              tool: priorTool,
              result: priorResult,
              language: detectedLang,
            );
            logger.logFinalResponse(finalMsg);
            await workspaceLoader.updateHeartbeat(
              request.agentName.isNotEmpty
                  ? request.agentName
                  : request.agentId,
              state: 'done',
              task: request.userMessage,
              lastTool: priorTool.name,
              lastResult: 'success',
            );
            await _archiveLedgerForRequest(request, LedgerStatus.completed);
            return AgentRuntimeResponse(
              finalMessage: finalMsg,
              success: true,
              state: AgentRuntimeState.done,
              events: logger.events,
              actions: priorResult.actions,
            );
          }
          previousResults.add({
            'step': currentStep,
            'tool': toolRequest.name,
            'note': 'Duplicate delivery to $deliveryKey suppressed.',
          });
          currentStep++;
          retryCount = 0;
          continue;
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

        // Record a successful delivery so a later re-pick of the same
        // destination is recognized as a duplicate (see guard above).
        if (deliveryKey != null && result.success) {
          deliveredKeys.add(deliveryKey);
          lastDeliveryTool = toolRequest;
          lastDeliveryResult = result;
        }

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

        // Post-execute verification: confirm mutating tools actually landed
        // in the snapshot. Replaces the agent-only check with a generic
        // metadata-driven gate. Skipped silently when the tool has no
        // verification probe (retrieval tools, snapshot-less environments).
        if (postExecuteValidator != null && result.success) {
          final toolDef = toolRouter.getDefinition(toolRequest.name);
          if (toolDef != null) {
            final verification = await postExecuteValidator.verify(
              tool: toolRequest,
              definition: toolDef,
              result: result,
            );
            if (verification.isUnverified) {
              logger.logError(
                'Post-execute verification failed: ${verification.reason} '
                '(entity=${verification.expectedEntity}, type=${verification.entityType})',
              );
              final recoveryDecision = await _maybeRecover(
                recovery: recovery,
                rethink: rethink,
                failedTool: toolRequest,
                reason: 'verification_unverified',
                logger: logger,
                unverifiedEntity: verification.expectedEntity,
                unverifiedEntityType: verification.entityType,
              );
              if (recoveryDecision != null) {
                return _executeLoop(
                  request: request,
                  plan: recoveryDecision.plan,
                  goalTree: recoveryDecision.goalTree,
                  executor: executor,
                  verbalizer: verbalizer,
                  detectedLang: detectedLang,
                  availableTools: availableTools,
                  logger: logger,
                  emit: emit,
                  memorySnapshot: memorySnapshot,
                  recovery: recovery,
                  postExecuteValidator: postExecuteValidator,
                  rethink: rethink,
                  autoApproveSensitive: autoApproveSensitive,
                  isWorkflowAutoExecute: isWorkflowAutoExecute,
                );
              }
              await _finishTaskScopeForRequest(request, LedgerStatus.failed);
              final unverifiedMessage = verification.userFacingMessage(
                detectedLang,
              );
              logger.logFinalResponse(unverifiedMessage);
              return AgentRuntimeResponse(
                finalMessage: unverifiedMessage,
                success: false,
                state: AgentRuntimeState.failed,
                events: logger.events,
              );
            }
          }
        }

        // Last planned step + success: short-circuit with verbalizer.success.
        // No per-tool switch; works for every tool generically.
        //
        // CRITICAL: when goalTree has multiple subgoals, the loop must
        // continue through the reviewer so subgoal status advances. Skipping
        // straight to verbalizer.success here was the "buat 3 agen â†’ 1 agen"
        // bug â€” we'd return after the first successful tool while sg2/sg3
        // were still pending.
        //
        // EARLY-COMPLETION (Stage 1): a successful RETRIEVAL tool whose result
        // IS the answer can finalize without the redundant `review` round-trip
        // that caused the "back-and-forth reflecting" the user reported. This
        // only fires when the retrieval's subgoal is the SOLE remaining
        // non-terminal one â€” so multi-target tasks (sg2/sg3 still pending) and
        // multi-tool flows (e.g. app.resolve â†’ app.open, where app.resolve is
        // NOT a retrieval) keep going through review exactly as before. We mark
        // the active subgoal done first so the completion verifier sees a
        // consistent tree.
        final shortCircuitActive = goalTree.nextActionable;
        final retrievalCompletesTree =
            result.success &&
            shortCircuitActive != null &&
            _isRetrievalTool(toolRequest.name) &&
            !goalTree.subgoals.any(
              (s) => !s.isTerminal && s.id != shortCircuitActive.id,
            );
        final wouldCompleteTree =
            goalTree.isEmpty || goalTree.isComplete || retrievalCompletesTree;
        if (result.success &&
            _isLastPlannedStep(plan, currentStep) &&
            wouldCompleteTree) {
          if (retrievalCompletesTree) {
            shortCircuitActive.status = SubgoalStatus.done;
          }
          final verificationBlocker = await _completionVerifier.blockIfUnverified(
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
            parkTask: (questions) => _parkTaskForUserInput(
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
              questions: questions,
            ),
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
          recentMessages: loopRecentMsgs,
        );
        emit(logger.events.last);

        var reviewStatus = review?['status'] as String? ?? '';
        if (!result.success &&
            (reviewStatus == 'done' || reviewStatus == 'continue')) {
          reviewStatus = 'ask_user';
        }

        // Empty-result loop guard.
        //
        // If the tool succeeded but returned zero matches AND the reviewer
        // wants to continue/retry the same kind of lookup, force-finalize.
        // This prevents the LLM from re-calling search/list/read tools with
        // slightly different args hoping for a different answer when the
        // honest answer is "no results".
        if (result.success &&
            _isEffectivelyEmpty(result.data) &&
            (reviewStatus == 'continue' || reviewStatus == 'retry')) {
          final priorEmpties = previousResults.where((p) {
            final tool = p['tool'] as String?;
            final data = p['result'];
            return tool == toolRequest.name &&
                data is Map<String, dynamic> &&
                _isEffectivelyEmpty(data);
          }).length;
          if (priorEmpties >= 1 || _isReadOnlyLookup(toolRequest.name)) {
            logger.logStateChange(
              state,
              'Empty-result loop guard: forcing done (tool=${toolRequest.name})',
            );
            reviewStatus = 'done';
            // Inject a synthesized final_response so downstream synthesis path
            // doesn't fall back to "Maximum runtime steps reached".
            review?['status'] = 'done';
            review?['final_response'] ??= _emptyResultMessage(
              detectedLang.code,
              toolRequest.name,
            );
          }
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
            // No subgoal_update emitted but the tool succeeded â€” mark the
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
          final verificationBlocker = await _completionVerifier.blockIfUnverified(
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
            parkTask: (questions) => _parkTaskForUserInput(
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
              questions: questions,
            ),
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
          final recoveryDecision = await _maybeRecover(
            recovery: recovery,
            rethink: rethink,
            failedTool: toolRequest,
            reason: 'tool_failed',
            errorSummary: review['error']?.toString() ?? '',
            logger: logger,
          );
          if (recoveryDecision != null) {
            return _executeLoop(
              request: request,
              plan: recoveryDecision.plan,
              goalTree: recoveryDecision.goalTree,
              executor: executor,
              verbalizer: verbalizer,
              detectedLang: detectedLang,
              availableTools: availableTools,
              logger: logger,
              emit: emit,
              memorySnapshot: memorySnapshot,
              recovery: recovery,
              postExecuteValidator: postExecuteValidator,
              rethink: rethink,
              autoApproveSensitive: autoApproveSensitive,
              isWorkflowAutoExecute: isWorkflowAutoExecute,
            );
          }
          await _finishTaskScopeForRequest(request, LedgerStatus.failed);
          final giveUp =
              recovery?.giveUpMessage(detectedLang) ??
              (review['error'] as String? ?? 'Unrecoverable error.');
          return _fail(giveUp, logger);
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

  /// Records a failure with the [RecoveryCoordinator] and, if budget allows,
  /// invokes the [rethink] closure to obtain a fresh plan + goal tree.
  ///
  /// Returns `null` when:
  /// - no recovery coordinator/rethink closure was wired (legacy callers)
  /// - the coordinator decided to give up (budget exhausted, structural fail)
  /// - rethink failed to produce a new plan
  ///
  /// The caller is expected to fall back to its previous "give up" branch
  /// in those cases.
  Future<({Map<String, dynamic> plan, GoalTree goalTree})?> _maybeRecover({
    required RecoveryCoordinator? recovery,
    required Future<({Map<String, dynamic> plan, GoalTree goalTree})?>
    Function()?
    rethink,
    required String reason,
    required RuntimeLogger logger,
    ToolCallRequest? failedTool,
    String stageHint = '',
    String errorSummary = '',
    String unverifiedEntity = '',
    String unverifiedEntityType = '',
  }) async {
    if (recovery == null || rethink == null) return null;

    final toolMarker = failedTool?.name ?? stageHint;
    final argsSummary = failedTool == null
        ? errorSummary
        : _summarizeArgs(failedTool.args);

    recovery.recordAttemptFailure(
      RecoveryAttempt(
        reason: reason,
        failedToolName: toolMarker,
        failedArgsSummary: argsSummary,
        unverifiedEntity: unverifiedEntity,
        unverifiedEntityType: unverifiedEntityType,
      ),
    );

    final decision = recovery.evaluate(
      snapshotMaybeStale: reason == 'verification_unverified',
    );
    if (decision != RecoveryDecision.rethinkAndReplan) {
      logger.logError(
        'Recovery decision=${decision.name} after $reason '
        '(attempts=${recovery.attemptCount}/${recovery.maxAttempts})',
      );
      return null;
    }

    logger.logStateChange(
      AgentRuntimeState.analyzing,
      'Recovery: re-reflecting with prior failure context '
      '(attempt ${recovery.attemptCount}/${recovery.maxAttempts}, reason=$reason)',
    );

    final replan = await rethink();
    if (replan == null) {
      logger.logError('Recovery: rethink returned no new plan; giving up.');
      return null;
    }
    logger.logLlmDecision('recovery.replan', {
      'attempt': recovery.attemptCount,
      'reason': reason,
      'subgoals': replan.goalTree.subgoals.length,
    });
    return replan;
  }

  String _summarizeArgs(Map<String, dynamic> args) {
    if (args.isEmpty) return '';
    final parts = <String>[];
    args.forEach((key, value) {
      final v = value?.toString() ?? '';
      final truncated = v.length > 24 ? '${v.substring(0, 24)}â€¦' : v;
      parts.add('$key=$truncated');
    });
    return parts.take(4).join(', ');
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
    final override = _snapshotOverride;
    if (override != null) return override();
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
  /// aren't in the registry are silently dropped â€” the reflector treats the
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
  /// The ledger becomes the authoritative store for the task â€” `resumeContext`
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
      // Update in place â€” the loop is mid-flight, just sync state.
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
    // 1. Provider disambiguation â€” deterministic, no LLM needed.
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

    // Workflow run state lives in the WorkflowRunner's run ledger, not here.
    if (source == RequestSource.workflow) return;

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
    // Workflow runs do not use the engine's resume ledger.
    if (request.source == RequestSource.workflow) return;
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

  AgentRuntimeResponse _fail(String message, RuntimeLogger logger) {
    logger.logError(message);
    return AgentRuntimeResponse(
      finalMessage: message,
      success: false,
      state: AgentRuntimeState.failed,
      events: logger.events,
    );
  }

  /// User-facing message when no tool exists for the requested action.
  /// Used after the runtime exhausts recovery attempts on null tool selection.
  String _capabilityNotFoundMessage(DetectedLanguage lang) {
    final code = lang.code.toLowerCase();
    if (code == 'id' || code.startsWith('id_')) {
      return 'Maaf, aku belum punya kemampuan untuk melakukan itu. '
          'Tidak ada tool yang sesuai untuk permintaan tersebut.';
    }
    return 'Sorry, I don\'t have the capability to do that. '
        'No tool is available for this request.';
  }

  /// True when a tool's data payload represents an empty / zero-match outcome.
  ///
  /// Recognises common shapes used across the codebase:
  /// - `{count: 0}`
  /// - empty values under any of: results, items, events, notes, files,
  ///   matches, apps, recent, list, data, slots
  static bool _isEffectivelyEmpty(Map<String, dynamic>? data) {
    if (data == null || data.isEmpty) return true;
    final count = data['count'];
    if (count is num && count == 0) return true;
    const listKeys = [
      'results',
      'items',
      'events',
      'notes',
      'files',
      'matches',
      'apps',
      'recent',
      'list',
      'data',
      'slots',
      'conflicts',
      'tree',
    ];
    var sawList = false;
    for (final k in listKeys) {
      final v = data[k];
      if (v is List) {
        sawList = true;
        if (v.isNotEmpty) return false;
      } else if (v is Map) {
        sawList = true;
        if (v.isNotEmpty) return false;
      }
    }
    return sawList;
  }

  /// True when the tool is a read-only lookup. For these tools, an empty
  /// result IS the answer â€” there's no point retrying with different args.
  static bool _isReadOnlyLookup(String toolName) {
    return toolName.endsWith('.search') ||
        toolName.endsWith('.list') ||
        toolName.endsWith('.list_recent') ||
        toolName.endsWith('.read') ||
        toolName.endsWith('.read_recent') ||
        toolName.endsWith('.tree') ||
        toolName.endsWith('.metadata') ||
        toolName.endsWith('.upcoming') ||
        toolName.endsWith('.today') ||
        toolName.endsWith('.conflicts') ||
        toolName.endsWith('.free_slot') ||
        toolName.endsWith('.status') ||
        toolName.endsWith('.summary') ||
        toolName.endsWith('.classify') ||
        toolName.endsWith('.summarize');
  }

  /// Returns a stable destination key for delivery tools whose duplicate
  /// execution within a SINGLE run is almost always a bug (e.g. sending the
  /// same chat message twice). Returns null for tools where a repeat may be
  /// legitimate, so the duplicate-delivery guard stays surgical.
  ///
  /// The key is destination-scoped (not content-scoped): re-sending to the
  /// same chat with slightly reworded content is still a duplicate. This is
  /// what catches the "compose + send" plans that re-pick chat.send after it
  /// already succeeded.
  static String? _deliveryDestinationKey(ToolCallRequest tool) {
    switch (tool.name) {
      case 'chat.send':
        final agentId = (tool.args['agentId'] ?? '').toString().trim();
        return 'chat.send|${agentId.isEmpty ? 'self' : agentId}';
      case 'notification.create_local':
        return 'notification.create_local';
      default:
        return null;
    }
  }

  /// Localized "no results" reply when the empty-result loop guard fires.
  String _emptyResultMessage(String langCode, String toolName) {
    final code = langCode.toLowerCase();
    final isFiles = toolName.startsWith('files.');
    final isNotes = toolName.startsWith('notes.');
    final isCal = toolName.startsWith('calendar.');
    if (code == 'id' || code.startsWith('id_')) {
      if (isFiles) return 'Tidak ada file yang cocok dengan kriteria itu.';
      if (isNotes) return 'Tidak ada catatan yang cocok dengan kriteria itu.';
      if (isCal) return 'Tidak ada acara yang cocok dengan kriteria itu.';
      return 'Tidak ada hasil yang cocok.';
    }
    if (isFiles) return 'No files match that criteria.';
    if (isNotes) return 'No notes match that criteria.';
    if (isCal) return 'No events match that criteria.';
    return 'No results match.';
  }

  bool _isLastPlannedStep(Map<String, dynamic> plan, int currentStep) {
    final steps = plan['steps'];
    if (steps is List && steps.isNotEmpty) {
      return currentStep >= steps.length;
    }
    // Planner emits subgoals format (v2). Each tool execution advances one
    // subgoal, so we're at the last step when currentStep >= subgoal count.
    final subgoals = plan['subgoals'];
    if (subgoals is List && subgoals.isNotEmpty) {
      return currentStep >= subgoals.length;
    }
    // Neither format present â€” treat as single-step to avoid blocking.
    return true;
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

  /// True when the analyzer's intent is destructive/side-effecting enough that
  /// the deep-thinking reflection pass must run (impact + slot analysis), even
  /// for a high-confidence single-tool turn. Reads the analyzer's `risk` and
  /// `intent`/`goal` operation hints â€” language-agnostic, no keyword lists.
  bool _isDestructiveIntent(Map<String, dynamic> analysis) {
    final risk = (analysis['risk'] ?? '').toString().toLowerCase();
    if (risk == 'sensitive' || risk == 'dangerous') return true;
    // Operation hint: the analyzer may surface a verb in intent/goal. We only
    // look for structured operation enums the reflector also uses, never
    // natural-language phrasing, so this stays language-generic.
    final intent = (analysis['intent'] ?? '').toString().toLowerCase();
    const destructiveOps = {
      'delete',
      'remove',
      'update',
      'rename',
      'toggle',
      'overwrite',
      'move',
    };
    for (final op in destructiveOps) {
      if (intent.contains(op)) return true;
    }
    return false;
  }

  bool _isRetrievalTool(String toolName) {
    // Authoritative source: ToolDefinition metadata. Falls back to a name
    // heuristic for tools that haven't been explicitly flagged yet.
    final def = toolRouter.getDefinition(toolName);
    if (def != null && def.isRetrieval) return true;
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

    // The user's effective language for THIS engine instance. The runtime is
    // constructed per turn so this is already the right setting/detected lang.
    final code = languageCode;
    final reason = data['reason'] as String? ?? '';
    final moduleName = (data['moduleName'] as String? ?? '').trim();
    final module = moduleName.isEmpty
        ? LanguageRegistry.phrase('permission_module_default', code)
        : moduleName;

    // Action and setting labels: single canonical English form. LanguageRegistry
    // wraps them in localized sentences per the user's language.
    final action =
        (data['actionLabel'] as String? ?? '').trim();
    final actionLabel = action.isEmpty
        ? LanguageRegistry.phrase('permission_action_default', code)
        : action;

    final setting =
        (data['settingLabel'] as String? ?? '').trim();

    if (reason == ToolPermissionBlockReason.settingDisabled.name &&
        setting.isNotEmpty) {
      return LanguageRegistry.phrase('permission_denied', code, {
        'action': actionLabel,
        'module': module,
        'setting': setting,
      });
    }

    return LanguageRegistry.phrase('permission_denied_no_setting', code, {
      'action': actionLabel,
      'module': module,
    });
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
