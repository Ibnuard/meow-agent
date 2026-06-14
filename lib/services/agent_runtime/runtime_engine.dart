import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/storage/core_storage_providers.dart';
import '../../features/modules/data/module_repository.dart';
import '../../core/storage/app_settings_repository.dart';
import '../../core/storage/module_entry_repository.dart';
import '../../features/agents/data/agent_repository.dart';
import '../../features/settings/data/app_language_provider.dart';
import '../../features/providers/data/provider_config.dart';
import '../../features/providers/data/provider_repository.dart';
import '../../features/settings/data/llm_provider_config.dart';
import '../llm/openai_compatible_client.dart';
import '../llm/llm_error_mapper.dart';
import '../app_agent/app_agent_overlay_service.dart';
import 'context_builder.dart';
import 'ecosystem_snapshot.dart';
import 'executor.dart';
import 'goal_tree.dart';
import 'language_detector.dart';
import 'narrative_narrator.dart';

import 'pending_action.dart';
import 'pending_clarification.dart';
import 'planner.dart';
import 'completion_verifier.dart';
import 'confirmation_manager.dart';
import 'preflight_checker.dart';
import 'task_scope_manager.dart';
import 'execute_loop_runner.dart';
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

import 'tool_router.dart';
import 'tool_verbalizer.dart';
import 'workspace_context_builder.dart';
import 'workspace_folder_service.dart';
import '../../features/agents/data/agent_model.dart';
import '../../features/modules/workflows/workflow_repository.dart';

/// Callback for real-time event streaming.
typedef RuntimeEventCallback = void Function(RuntimeEvent event);

/// The main agentic runtime engine.
/// Stateful: maintains pending actions per agent.
class AgentRuntimeEngine {
  AgentRuntimeEngine({
    required this.workspaceFolder,
    required this.toolRouter,
    required this.contextBuilder,
    required this.languageCode,
    this.snapshotBuilder,
    this.agentLoader,
    this.soulRepo,
    this.memoryRepo,
    this.eventRepo,
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
      snapshotBuilder: _snapshotOverride ?? () => _buildSnapshot(),
    );
    _taskScope = TaskScopeManager(ledgerDb: this.ledgerDb);
    _confirmation = ConfirmationManager(
      ledgerDb: this.ledgerDb,
      languageCode: languageCode,
      llmClient: _client,
      onExecutePendingTool:
          ({
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
          _taskScope.finishScopeForRequest(request, terminal),
    );
    _taskScope.attachConfirmation(_confirmation);
    _loopRunner = ExecuteLoopRunner(
      toolRouter: toolRouter,
      taskScope: _taskScope,
      preflight: _preflight,
      completionVerifier: _completionVerifier,
      memory: _memory,
      languageCode: languageCode,
    );
    _loopRunner.attachPendingActionsCallback((agentId, pending) {
      _pendingActions[agentId] = pending;
    });
  }

  final WorkspaceFolderService workspaceFolder;
  final ToolRouter toolRouter;
  final ContextBuilder contextBuilder;
  final String languageCode;
  final EcosystemSnapshotBuilder? snapshotBuilder;
  final List<AgentModel> Function()? agentLoader;
  final AgentSoulRepository? soulRepo;
  final AgentMemoryRepository? memoryRepo;
  final AgentEventRepository? eventRepo;
  final TaskLedgerDatabase ledgerDb;
  final OpenAiCompatibleClient _client;
  final Future<EcosystemSnapshot> Function()? _snapshotOverride;
  late final PreflightChecker _preflight;
  late final CompletionVerifier _completionVerifier;
  late final TaskScopeManager _taskScope;
  late final ConfirmationManager _confirmation;
  late final ExecuteLoopRunner _loopRunner;
  late final WorkspaceContextBuilder _contextBuilder = WorkspaceContextBuilder(
    soulRepo: soulRepo,
    memoryRepo: memoryRepo,
  );
  static const int maxSteps = 5;
  final RuntimeMemory _memory = RuntimeMemory();
  final LanguageDetector _languageDetector = LanguageDetector();

  // ── Helpers ──

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

  /// Build an [AgentWorkspace] from SQLite-backed repos.
  /// Delegates to [WorkspaceContextBuilder] for the actual formatting.
  Future<AgentWorkspace> _buildWorkspace(
    String agentName,
    String agentId,
  ) async {
    return _contextBuilder.build(agentName, agentId);
  }

  /// True if the user hasn't introduced themselves yet. Drives the
  /// introduction gate. Phase 7: reads `agent_soul.user_name` directly.
  /// Treats null, empty, and bracketed placeholders ("[Your Name]") as missing.
  bool _isUserNameMissing(AgentSoul? soul) {
    return WorkspaceContextBuilder.isUserNameMissing(soul);
  }

  /// Best-effort activity event logger. Inserts a row into `agent_events`
  /// when the optional repo is wired; silently no-ops otherwise. Failures
  /// never propagate — telemetry must not break a turn.
  Future<void> _logEvent({
    required String agentId,
    required String eventType,
    String? state,
    String? task,
    String? lastTool,
    String? lastResult,
  }) async {
    final repo = eventRepo;
    if (repo == null || agentId.isEmpty) return;
    try {
      await repo.log(
        agentId: agentId,
        eventType: eventType,
        state: state,
        task: task,
        lastTool: lastTool,
        lastResult: lastResult,
      );
    } catch (_) {
      // Telemetry is fire-and-forget.
    }
  }


  Map<String, PendingAction> get _pendingActions =>
      _confirmation.pendingActions;
  Map<String, PendingClarification> get _pendingClarifications =>
      _confirmation.pendingClarifications;

  PendingAction? getPendingAction(String agentId) =>
      _confirmation.getPending(agentId);
  void clearPendingAction(String agentId) =>
      _confirmation.clearPending(agentId);
  void clearPendingClarification(String agentId) =>
      _confirmation.clearClarification(agentId);
  Future<void> abortActiveTask(
    String agentId, {
    RequestSource source = RequestSource.chat,
  }) => _taskScope.abortActive(agentId, source: source);

  /// Hard-wipe ALL runtime state for an agent: every persisted ledger (any
  /// status), the pending confirmation, the pending clarification, the
  /// in-memory tool scratchpad, and the cancellation flag.
  ///
  /// This is the single source of truth behind `/clear`, `/reset`, and
  /// `/resume`. Without it, a stale ledger or memory entry survives the command
  /// and the engine rehydrates a "ghost" task on the next message — the exact
  /// behavior users hit when a cleared chat suddenly resumed an old automation.
  Future<void> resetAgentState(String agentId) async {
    _taskScope.cancel(agentId);
    _confirmation.clearPending(agentId);
    _confirmation.clearClarification(agentId);
    _memory.clear(agentId);
    await ledgerDb.deleteAllForAgent(agentId);
  }

  // ═══════════════════════════════════════════════════════════════
  // run() — the main entry point
  // ═══════════════════════════════════════════════════════════════

  Future<AgentRuntimeResponse> run(
    AgentRuntimeRequest request, {
    required ProviderConfig provider,
    RuntimeEventCallback? onEvent,
    bool autoApproveSensitive = false,
  }) async {
    _taskScope.clearCancellation(request.agentId);
    final logger = RuntimeLogger();
    void emit(RuntimeEvent event) {
      onEvent?.call(event);
    }

    final llmConfig = LlmProviderConfig(
      baseUrl: provider.baseUrl,
      apiKey: provider.apiKey,
      model: provider.model,
      supportsFunctionCalling: provider.supportsFunctionCallingFor(
        provider.model,
      ),
    );
    final client = _client;
    final planner = Planner(
      client: client,
      config: llmConfig,
      languageCode: languageCode,
    );
    final executor = Executor(client: client, config: llmConfig);
    final reflector = Reflector(client: client, config: llmConfig);
    final isWorkflowAutoExecute =
        request.source == RequestSource.workflow && autoApproveSensitive;
    var detectedLang = _languageDetector.detect(
      userMessage: request.userMessage,
      fallbackCode: languageCode,
    );
    logger.logStateChange(
      AgentRuntimeState.analyzing,
      'Language bootstrap: ${detectedLang.code} (${detectedLang.script}, conf ${detectedLang.confidence.toStringAsFixed(2)})',
    );
    emit(logger.events.last);
    final verbalizer = ToolVerbalizer(client: client, config: llmConfig);
    verbalizer.resetTurn();
    try {
      try {
        await _confirmation.maybeRestoreFromLedger(request.agentId);
      } catch (e) {
        logger.logError('Ledger auto-resume failed; continuing fresh', e);
      }
      var pending = _pendingActions[request.agentId];
      var pendingDecision = ConfirmationDecision.none;
      if (pending != null) {
        pendingDecision = ConfirmationChecker.check(request.userMessage);
        logger.logStateChange(
          AgentRuntimeState.analyzing,
          'Pending action detected: ${pending.toolName}, deterministic decision: ${pendingDecision.name}',
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
        if (pendingResponse != null) return pendingResponse;
      }
      final wsName = request.agentName.isNotEmpty
          ? request.agentName
          : request.agentId;
      toolRouter.agentName = wsName;
      toolRouter.agentId = request.agentId;
      toolRouter.attachments = request.attachments;

      // Vision probe: only when the user actually attached an image. The
      // probe is cached per (provider, model) for the session on success,
      // so capable models pay the round-trip exactly once. Failures are not
      // cached — transient errors get a fresh chance on the next turn.
      final hasImageAttachment = request.attachments.any((a) {
        final dot = a.name.lastIndexOf('.');
        if (dot < 0) return false;
        final ext = a.name.substring(dot).toLowerCase();
        return const {
          '.png',
          '.jpg',
          '.jpeg',
          '.webp',
          '.gif',
          '.bmp',
          '.heic',
        }.contains(ext);
      });
      if (hasImageAttachment) {
        // Default to vision-capable for any model with image attachments.
        // The vast majority of modern models (GPT-4o/4.1, Claude 3+, Gemini)
        // support vision. If a model truly doesn't, the API will reject the
        // request with a 4xx and we surface that error naturally — better UX
        // than a probe that costs latency on every image message and silently
        // blocks the user when the probe itself fails (rate limits, transient
        // network issues, model variations like "scarlet" instead of "red").
        toolRouter.modelSupportsVision = true;
      } else {
        toolRouter.modelSupportsVision = true;
      }
      toolRouter.currentUserMessage = request.userMessage;
      toolRouter.describeImage =
          ({required AttachedFile image, required String prompt}) async {
            final bytes = await File(image.path).readAsBytes();
            final mime = _mimeTypeForImage(image.name);
            final dataUrl = 'data:$mime;base64,${base64Encode(bytes)}';
            return client.chatWithImage(
              config: llmConfig,
              prompt: prompt,
              imageDataUrl: dataUrl,
              phase: 'attachment_vision',
            );
          };
      await workspaceFolder.ensureFolder(wsName);
      // Phase 7: identity lives in agent_soul. Check the DB row directly to
      // decide whether the introduction gate should fire.
      final activeSoul = await soulRepo?.get(request.agentId);
      final workspace = await _buildWorkspace(wsName, request.agentId);
      final userNotIntroduced = _isUserNameMissing(activeSoul);
      // Drop transient provider-error messages from history before slicing —
      // they describe past connection state, not real conversational context.
      // Without this filter the LLM sees its own "I can't connect" reply from
      // a prior failed turn and parrots that narrative even after the
      // connection has recovered. See LlmErrorMapper.providerErrorSentinel.
      final sourceMessages = request.recentMessages
          .where((m) => !LlmErrorMapper.isProviderErrorMessage(m.content))
          .toList();
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
      final activeLedger = await ledgerDb.findActive(
        agentId: request.agentId,
        source: request.source == RequestSource.workflow
            ? LedgerSource.workflow
            : LedgerSource.chat,
      );
      String activeTaskContext = '';
      if (activeLedger != null) {
        activeTaskContext = activeLedger.describeForUser();
      } else if (pending != null) {
        activeTaskContext =
            'pending confirmation: ${pending.debugDescriptor}; summary: ${pending.userFacingSummary}';
      } else if (pendingClarification != null) {
        activeTaskContext =
            'pending clarification for: ${pendingClarification.originalMessage} (questions: ${pendingClarification.questions.join('; ')})';
      }
      final mergedUserMessage = pendingClarification != null
          ? pendingClarification.mergedWith(request.userMessage)
          : request.userMessage;
      // Inject attachment context for the LLM.
      final attachmentContext = _buildAttachmentContext(request.attachments);
      final userMessageWithAttachments = attachmentContext != null
          ? '$attachmentContext\n\nUser message: ${request.userMessage}'
          : request.userMessage;
      var effectiveUserMessage = activeTaskContext.isNotEmpty
          ? (attachmentContext != null
                ? '$attachmentContext\n\nUser message: ${request.userMessage}'
                : request.userMessage)
          : (pendingClarification != null
                ? mergedUserMessage
                : userMessageWithAttachments);
      var toolSelection = ToolCatalog.select(
        userMessage: request.userMessage,
        pendingAction: pending,
        isWorkflowAutoExecute: isWorkflowAutoExecute,
      );
      // Phase 2: ALWAYS start with the narrowed tool selection — even when
      // there is an active task context. The active task description is still
      // passed to the analyzer so it can classify task_relation, but the tool
      // surface stays focused. For continuation/revision the engine will expand
      // the tool set AFTER classification (below). This prevents the LLM from
      // hallucinating or picking irrelevant tools (e.g. app_agent) just because
      // a previous ledger exists on a simple "open app" request.
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
        'Tool context: ${toolSelection.reason}${activeTaskContext.isNotEmpty ? ' [active-task ctx]' : ''} (${availableTools.length} tools, confidence ${toolSelection.confidence.toStringAsFixed(2)})',
      );
      emit(logger.events.last);
      var state = AgentRuntimeState.analyzing;
      logger.logStateChange(state, 'Analyzing user intent');
      emit(logger.events.last);
      _logEvent(
        agentId: request.agentId,
        eventType: 'state_change',
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
        agentName: wsName,
        agentId: request.agentId,
      );
      emit(logger.events.last);
      if (analysis == null) {
        await _taskScope.finishScopeForRequest(request, LedgerStatus.failed);
        return _loopRunner.fail('Failed to analyze request.', logger);
      }
      final analyzeNarrative = (analysis['narrative'] ?? '').toString();
      // Gate: if missing_info is non-empty, the runtime will ask a clarifying
      // question. Override optimistic LLM narrative with deterministic phrase.
      final earlyMissingInfo = (analysis['missing_info'] as List?) ?? const [];
      final gatedAnalyzeNarrative = earlyMissingInfo.isNotEmpty
          ? NarrativeNarrator.narrate('asking', detectedLang.code)
          : analyzeNarrative;
      if (gatedAnalyzeNarrative != analyzeNarrative) {
        logger.logDivergence('narrative_gate_override', {
          'phase': 'analyze',
          'reason': 'missing_info_present',
          'missing_count': earlyMissingInfo.length,
        });
      }
      if (gatedAnalyzeNarrative.isNotEmpty) {
        logger.logNarrative('analyze', gatedAnalyzeNarrative);
        emit(logger.events.last);
      }
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
          'Language refined by analyzer: ${detectedLang.code} → ${refined.code} (${refined.label})',
        );
        emit(logger.events.last);
        detectedLang = refined;
      }
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
            'Tool surface narrowed from analyzer tool_groups: ${narrowed.reason} (${availableTools.length} tools, confidence ${narrowed.confidence.toStringAsFixed(2)})',
          );
          emit(logger.events.last);
        }
      }
      // Metadata-driven tool exclusion (e.g. notification-triggered workflows
      // exclude notification reading tools since data is already inline).
      final excludeTools = (request.metadata['exclude_tools'] as List?)
          ?.map((e) => e.toString())
          .toSet();
      if (excludeTools != null && excludeTools.isNotEmpty) {
        bool shouldExclude(String desc) {
          for (final ex in excludeTools) {
            if (desc.startsWith('- $ex:') || desc.startsWith('- $ex ')) {
              return true;
            }
          }
          return false;
        }

        availableTools = availableTools
            .where((t) => !shouldExclude(t))
            .toList();
        analyzerTools = analyzerTools.where((t) => !shouldExclude(t)).toList();
      }
      var relation = (analysis['task_relation'] as String? ?? 'none').trim();
      if (activeTaskContext.isNotEmpty) {
        if (relation == 'none' &&
            pendingDecision != ConfirmationDecision.confirmed &&
            pendingDecision != ConfirmationDecision.rejected &&
            pendingDecision != ConfirmationDecision.previewOnly &&
            analysis['requires_tools'] == true) {
          relation = 'new_task';
        }
        // For continuation/revision the agent is resuming a persisted multi-step
        // task — expand to all tools since the ledger may require any tool group.
        if (relation == 'continuation' || relation == 'revision') {
          analyzerTools = toolRouter.buildAllAnalyzerToolDescriptions();
          availableTools = toolRouter.buildAllToolDescriptions();
          logger.logStateChange(
            AgentRuntimeState.analyzing,
            'Tool surface expanded to all tools for $relation of active task (${availableTools.length} tools)',
          );
          emit(logger.events.last);
        }
        if (relation == 'new_task') {
          final previousGoal =
              activeLedger?.mainGoal ??
              pending?.userFacingSummary ??
              pendingClarification?.originalMessage ??
              'the previous task';
          await _taskScope.finishScopeForRequest(request, LedgerStatus.aborted);
          pending = null;
          pendingDecision = ConfirmationDecision.none;
          pendingClarification = null;
          effectiveUserMessage = userMessageWithAttachments;
          activeTaskContext = '';
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
            'Active task scope archived (aborted) due to new_task classification. Tools re-narrowed to ${availableTools.length} from analyzer tool_groups. Heads-up surfaced.',
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
            agentName: wsName,
            agentId: request.agentId,
          );
          emit(logger.events.last);
          if (analysis == null) {
            await _taskScope.finishScopeForRequest(
              request,
              LedgerStatus.failed,
            );
            return _loopRunner.fail(
              'Failed to analyze clarified request.',
              logger,
            );
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
            'Pending action LLM decision after relation gate: ${pendingDecision.name}',
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
          if (pendingResponse != null) return pendingResponse;
        }
      }
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
      ReflectionOutput? reflection;
      TargetResolutionGraph? targetGraph;
      final analyzerSaysToolsForReflect = analysis['requires_tools'] == true;

      // Pre-check: if the task looks simple enough to fast-path, defer the
      // expensive snapshot build. An empty snapshot makes
      // isRelevantForReflection = false, which satisfies canSkipReflect's
      // last condition without actual I/O.
      final likelyFastPath =
          analyzerSaysToolsForReflect &&
          !isWorkflowAutoExecute &&
          toolSelection.isHighConfidence &&
          toolSelection.groups.length == 1 &&
          missingInfo.isEmpty &&
          analysis['bulk_selector'] != true &&
          !_isDestructiveIntent(analysis);
      final reflectSnapshot = (analyzerSaysToolsForReflect && !likelyFastPath)
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
          final gatedReflect = NarrativeNarrator.gate(
            llmNarrative: reflection.narrative,
            decision: reflection.strategy.name,
            languageCode: detectedLang.code,
          );
          if (gatedReflect != reflection.narrative) {
            logger.logDivergence('narrative_gate_override', {
              'phase': 'reflect',
              'decision': reflection.strategy.name,
            });
          }
          logger.logNarrative('reflect', gatedReflect);
          emit(logger.events.last);
        }
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
      }
      final analyzerSaysTools = analysis['requires_tools'] == true;
      final requiresTools = analyzerSaysTools || isWorkflowAutoExecute;
      if (!requiresTools) {
        state = AgentRuntimeState.done;
        logger.logStateChange(state, 'Direct response (no tools needed)');
        emit(logger.events.last);
        final selfIdentity = PromptConstants.selfIdentity(
          agentName: wsName,
          agentId: request.agentId,
        );
        final identityBlock =
            'Identity context (user profile stored in database):\n${workspace.soul}';
        final recentToolMemory = _memory.formatForPrompt(request.agentId);
        final toolMemoryBlock = recentToolMemory.isEmpty
            ? ''
            : '\n\nRECENT TOOL RESULTS (source of truth):\n$recentToolMemory\n\nUse successful retrieval results (read/list/search/status) to answer follow-up questions. Never treat failed tool results or prior progress/narrative messages as evidence. If the relevant result failed or is missing, say you cannot verify it yet and ask for the exact target or next step.';
        final worldModelBlock =
            '\n\nMEOW AGENT WORLD MODEL:\nYou are an Android-native AI agent, NOT a generic LLM or terminal-based assistant. Your workspace is a sandbox at Documents/MeowAgent/, rooted at your agent folder.\n${PromptConstants.systemMarkdownMap}';
        const capabilityDirectGuard =
            '\n\nCAPABILITY ANSWER GUARD:\nIf the user asks what you can do, what tools you have, or what capabilities are available, answer ONLY from a fresh system.tools.list retrieval result in RECENT TOOL RESULTS. If that result is not present, say you need to check the current tool list first. Never list generic assistant abilities or actions not backed by registered tools.';
        final baseSystem =
            '${_directResponseRulesFor(languageLabel: detectedLang.label, isWorkflowAutoExecute: isWorkflowAutoExecute, userNotIntroduced: userNotIntroduced)}\n\n$selfIdentity\n\n$identityBlock$worldModelBlock$toolMemoryBlock$capabilityDirectGuard';
        final systemContent = pending != null
            ? '$baseSystem\n\nPENDING ACTION (user was asked to confirm):\nTool: ${pending.toolName}\nArgs: ${pending.toolArgs}\nSummary: ${pending.userFacingSummary}\nIf user asks about the result or preview, show them what the result would be.'
            : baseSystem;

        // Build image data URLs for any image attachments. The model receives
        // them inline in the user message so it can see and reason about them
        // directly without invoking a tool. Non-image attachments still go
        // through tools (read_text, etc.) when the analyzer routes that way.
        final imageDataUrls = await _buildImageDataUrls(request.attachments);

        final directResponse = await client.chat(
          config: llmConfig,
          phase: 'direct',
          messages: [
            {'role': 'system', 'content': systemContent},
            ...recentMsgs,
            {'role': 'user', 'content': effectiveUserMessage},
          ],
          imageDataUrls: imageDataUrls,
        );
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
      final seeds = analysis['subgoal_seeds'];
      final hasMultiSeed = seeds is List && seeds.length > 1;
      final analyzerBulk = analysis['bulk_selector'] == true;
      final reflectorMultiSubgoal =
          reflection != null && reflection.goalTree.subgoals.length > 1;
      final reflectorMultiTarget =
          reflection != null && reflection.targets.length > 1;
      final resolvedMultiTarget =
          targetGraph != null && targetGraph.eligibleTargets.length > 1;
      final hasMultiTarget =
          hasMultiSeed ||
          analyzerBulk ||
          reflectorMultiSubgoal ||
          reflectorMultiTarget ||
          resolvedMultiTarget;
      final canSkipPlanner =
          pending == null &&
          !isWorkflowAutoExecute &&
          toolSelection.isHighConfidence &&
          toolSelection.groups.length == 1 &&
          missingInfo.isEmpty &&
          !hasMultiTarget;
      // Fast-path: skip both reflect and plan, hard-cap loop at 2 iterations.
      // If exhausted, runtime falls back to normal mode automatically.
      final isFastPath = canSkipPlanner && canSkipReflect;
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
        _logEvent(
          agentId: request.agentId,
          eventType: 'state_change',
          state: state.name,
          task: request.userMessage,
        );
        // Build resolved target labels for the planner so it can emit
        // per-entity subgoals for bulk/fan-out operations.
        final resolvedLabels = targetGraph != null && targetGraph.isNotEmpty
            ? targetGraph.eligibleTargets
                  .map(
                    (t) =>
                        '${t.operation} ${t.entityType}: ${t.entityLabel}'
                        '${t.entityId.isNotEmpty ? ' (id: ${t.entityId})' : ''}',
                  )
                  .toList(growable: false)
            : <String>[];
        plan = await planner.plan(
          analysis: analysis,
          availableTools: availableTools,
          logger: logger,
          resolvedTargetLabels: resolvedLabels,
        );
        emit(logger.events.last);
        if (plan == null) {
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
            resolvedTargetLabels: resolvedLabels,
          );
          emit(logger.events.last);
        }
        if (plan == null) {
          await _taskScope.finishScopeForRequest(request, LedgerStatus.failed);
          return _loopRunner.fail('Failed to create execution plan.', logger);
        }
        final planNarrative = (plan['narrative'] ?? '').toString();
        if (planNarrative.isNotEmpty) {
          logger.logNarrative('plan', planNarrative);
          emit(logger.events.last);
        }
      }
      final plannerGoalTree = _buildGoalTree(
        plan: plan,
        analysis: analysis,
        userMessage: effectiveUserMessage,
        resolvedTargets: targetGraph?.targets,
      );
      // Planner is the single source of goal-tree authority. The reflector no
      // longer dictates the tree — TargetResolver still feeds resolved
      // per-entity targets into the planner (via resolvedTargetLabels) AND into
      // _buildGoalTree's fan-out fallback, so bulk operations keep their full
      // breakdown without the reflector owning the tree.
      final goalTree = plannerGoalTree.isNotEmpty
          ? plannerGoalTree
          : GoalTree(mainGoal: effectiveUserMessage);
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
              attachments: request.attachments,
            );
      final recovery = RecoveryCoordinator();
      final validator = PostExecuteValidator(
        snapshotBuilder: () async => _buildSnapshot(),
      );
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
          // Resolve targets from the fresh reflection so the planner LLM and
          // the goal-tree fan-out fallback both see the snapshot-matched
          // entities.
          final reTargetResolution = TargetResolver.resolveReflection(
            reflection: reReflection,
            snapshot: freshSnapshot,
            request: request,
            language: detectedLang,
          );
          final reTargetGraph = reTargetResolution.graph;
          final reResolvedLabels = reTargetGraph.isNotEmpty
              ? reTargetGraph.eligibleTargets
                    .map(
                      (t) =>
                          '${t.operation} ${t.entityType}: ${t.entityLabel}'
                          '${t.entityId.isNotEmpty ? ' (id: ${t.entityId})' : ''}',
                    )
                    .toList(growable: false)
              : <String>[];
          final newPlan = await planner.plan(
            analysis: freshAnalysis,
            availableTools: broadenedAnalyzerTools.isNotEmpty
                ? broadenedAnalyzerTools
                : broadenedTools,
            logger: logger,
            resolvedTargetLabels: reResolvedLabels,
          );
          if (newPlan == null) return null;
          if (reTargetGraph.isNotEmpty) {
            newPlan['runtime_target_graph'] = reTargetGraph.toJson();
          }
          // Planner is the single source of authority — ignore reReflection's
          // goal tree; rebuild from the planner output and resolved targets.
          final newTree = _buildGoalTree(
            plan: newPlan,
            analysis: freshAnalysis,
            userMessage: effectiveUserMessage,
            resolvedTargets: reTargetGraph.targets,
          );
          return (plan: newPlan, goalTree: newTree);
        } catch (e) {
          logger.logError('Recovery rethink failed', e);
          return null;
        }
      }

      final loopResponse = await _loopRunner.run(
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
        fastPath: isFastPath,
      );

      // Fast-path exhausted: retry in normal mode with the same plan/tree.
      if (loopResponse.state == AgentRuntimeState.fastPathExhausted) {
        logger.logDivergence('fast_path_exhausted', {
          'fallback_mode': 'normal',
          'subgoals': goalTree.subgoals.length,
        });
        logger.logStateChange(
          AgentRuntimeState.analyzing,
          'Fast-path exhausted, retrying in normal mode',
        );
        emit(logger.events.last);
        return _loopRunner.run(
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
          fastPath: false,
        );
      }

      return loopResponse;
    } catch (e) {
      logger.logError('Runtime exception', e);
      await _taskScope.finishScopeForRequest(request, LedgerStatus.failed);
      return _loopRunner.fail(
        LlmErrorMapper.friendlyMessage(e, languageCode),
        logger,
      );
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // executeConfirmed
  // ═══════════════════════════════════════════════════════════════

  Future<AgentRuntimeResponse> executeConfirmed(
    AgentRuntimeRequest request, {
    required ProviderConfig provider,
    required String toolName,
    required Map<String, dynamic> toolArgs,
    bool alwaysApprove = false,
    RuntimeEventCallback? onEvent,
  }) {
    return _confirmation.executeConfirmed(
      request,
      provider: provider,
      toolName: toolName,
      toolArgs: toolArgs,
      alwaysApprove: alwaysApprove,
      onEvent: onEvent,
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // _executePendingTool
  // ═══════════════════════════════════════════════════════════════

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
      final permissionFinal = _loopRunner.permissionDeniedResponseFor(result);
      if (permissionFinal != null) {
        final actions = _loopRunner.permissionDeniedActionsFor(result);
        await _taskScope.finishScopeForRequest(request, LedgerStatus.failed);
        logger.logFinalResponse(permissionFinal);
        return AgentRuntimeResponse(
          finalMessage: permissionFinal,
          success: false,
          state: AgentRuntimeState.failed,
          events: logger.events,
          actions: actions,
        );
      }
      if (result.success) {
        final resume = pending.resumeContext;
        if (resume != null) {
          final treeJson = resume['goal_tree'] as Map<String, dynamic>?;
          final goalTree = treeJson != null
              ? GoalTree.fromJson(treeJson)
              : GoalTree.singleSubgoal(
                  mainGoal: pending.toolName,
                  subgoalLabel: pending.toolName,
                );
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
          if (goalTree.isComplete) {
            final verificationBlocker = await _completionVerifier
                .blockIfUnverified(
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
                  parkTask: (questions) => _taskScope.parkForUserInput(
                    request: resumedRequest,
                    plan: plan,
                    goalTree: goalTree,
                    previousResults: previousResults,
                    currentStep: currentStep,
                    availableTools: availableTools,
                    memorySnapshot: memorySnapshot,
                    detectedLangCode: detectedLang.code,
                    autoApproveSensitive: autoApproveSensitive,
                    isWorkflowAutoExecute: isWorkflowAutoExecute,
                    questions: questions,
                  ),
                  lastToolName: pending.toolName,
                );
            if (verificationBlocker != null) return verificationBlocker;
            final successMsg =
                _loopRunner.shouldAnswerFromToolResult(
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
                : await _loopRunner.finalForCompletedTree(
                    goalTree: goalTree,
                    fallbackTool: toolRequest,
                    fallbackResult: result,
                    verbalizer: verbalizer,
                    language: detectedLang,
                    targetGraph: (plan['runtime_target_graph'] as Map?)
                        ?.cast<String, dynamic>(),
                  );
            logger.logFinalResponse(successMsg);
            await _taskScope.archiveLedgerForRequest(
              request,
              LedgerStatus.completed,
            );
            _logEvent(
              agentId: request.agentId,
              eventType: 'turn_complete',
              state: AgentRuntimeState.done.name,
              task: request.userMessage,
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
          logger.logStateChange(
            AgentRuntimeState.selectingTool,
            'Resuming execute loop after confirmation (subgoals remaining: ${goalTree.subgoals.where((s) => !s.isTerminal).length})',
          );
          emit(logger.events.last);
          // Show the agentic overlay immediately after a confirmed app.open
          // when the plan has subsequent app_agent.* work. Without this, the
          // user sees LinkedIn open with no overlay — the overlay would only
          // appear once the next app_agent.* tool fires, causing a jarring
          // gap where it looks like "agentic mode didn't start".
          if ((pending.toolName == 'app.open' ||
                  pending.toolName == 'app.resolve') &&
              _loopRunner.planRequiresAppAgent(goalTree)) {
            AppAgentOverlayService.show(
              operation: 'open',
              narrative: '',
            );
          }
          return _loopRunner.run(
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
        final successMsg =
            _loopRunner.shouldAnswerFromToolResult(
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
        return AgentRuntimeResponse(
          finalMessage: successMsg,
          success: true,
          state: AgentRuntimeState.done,
          events: logger.events,
          actions: result.actions,
        );
      }
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
        await _taskScope.finishScopeForRequest(request, LedgerStatus.failed);
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
      await _taskScope.finishScopeForRequest(request, LedgerStatus.failed);
      logger.logFinalResponse(fallbackMsg);
      return AgentRuntimeResponse(
        finalMessage: fallbackMsg,
        success: false,
        state: AgentRuntimeState.done,
        events: logger.events,
      );
    } catch (e) {
      logger.logError('Runtime exception', e);
      await _taskScope.finishScopeForRequest(request, LedgerStatus.failed);
      return _loopRunner.fail(
        LlmErrorMapper.friendlyMessage(e, languageCode),
        logger,
      );
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // Goal tree / snapshot / tool defs
  // ═══════════════════════════════════════════════════════════════

  GoalTree _buildGoalTree({
    required Map<String, dynamic> plan,
    required Map<String, dynamic> analysis,
    required String userMessage,
    List<ResolvedTarget>? resolvedTargets,
  }) {
    final mainGoal =
        (plan['main_goal'] as String?) ??
        (analysis['goal'] as String?) ??
        userMessage;
    // Highest priority: the planner LLM's own subgoals (it now receives the
    // resolved targets as authoritative input, so its breakdown reflects them).
    final subgoalsJson = plan['subgoals'];
    if (subgoalsJson is List && subgoalsJson.isNotEmpty) {
      try {
        return GoalTree.fromJson({
          'main_goal': mainGoal,
          'completion_criteria': plan['completion_criteria'] ?? const [],
          'subgoals': subgoalsJson,
        });
      } catch (_) {}
    }
    // Fallback when the planner LLM was skipped/failed but the resolver fanned
    // out concrete per-entity targets: synthesize one subgoal per eligible
    // target so bulk operations keep their full breakdown.
    final eligibleTargets = resolvedTargets
        ?.where((t) => t.isEligible)
        .toList(growable: false);
    if (eligibleTargets != null && eligibleTargets.length > 1) {
      return GoalTree(
        mainGoal: mainGoal,
        subgoals: [
          for (final t in eligibleTargets)
            Subgoal(
              id: t.subgoalId.isNotEmpty ? t.subgoalId : 'sg_${t.entityId}',
              label: t.entityLabel.isNotEmpty
                  ? '${t.operation} ${t.entityType} ${t.entityLabel}'
                  : t.operation,
              requiredSlots: {
                if (t.entityId.isNotEmpty) 'entity_id': t.entityId,
                if (t.entityLabel.isNotEmpty) 'entity_label': t.entityLabel,
                'name': t.entityLabel,
              },
            ),
        ],
      );
    }
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
    return GoalTree.singleSubgoal(mainGoal: mainGoal, subgoalLabel: mainGoal);
  }

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

  List<ToolDefinition> _toolDefinitionsFor(Set<String> names) {
    final out = <ToolDefinition>[];
    for (final n in names) {
      final def = toolRouter.getDefinition(n);
      if (def != null) out.add(def);
    }
    return out;
  }

  // ═══════════════════════════════════════════════════════════════
  // _isDestructiveIntent — stays on engine (used in run(), not loop)
  // ═══════════════════════════════════════════════════════════════

  bool _isDestructiveIntent(Map<String, dynamic> analysis) {
    final risk = (analysis['risk'] ?? '').toString().toLowerCase();
    if (risk == 'sensitive' || risk == 'dangerous') return true;
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

  /// Build a metadata-only context string describing attached files.
  /// Contents are intentionally read only through attachment.* tools.
  String? _buildAttachmentContext(List<AttachedFile> attachments) {
    if (attachments.isEmpty) return null;
    const imageExts = {
      '.png',
      '.jpg',
      '.jpeg',
      '.webp',
      '.gif',
      '.bmp',
      '.heic',
    };
    bool isImage(String name) {
      final dot = name.lastIndexOf('.');
      if (dot < 0) return false;
      return imageExts.contains(name.substring(dot).toLowerCase());
    }

    final hasImage = attachments.any((a) => isImage(a.name));
    final buf = StringBuffer()
      ..writeln('[ATTACHED FILES — CURRENT TURN]')
      ..writeln(
        'The user attached ${attachments.length} file(s) to THIS message (current turn).',
      );

    if (hasImage) {
      buf.writeln(
        'IMPORTANT: Image files are present in the current turn. You MUST use '
        'attachment.describe_image to inspect them — this tool can describe, '
        'read text (OCR), identify objects, recognize colors, count, extract '
        'information, or answer ANY visual question. Pass the user\'s exact '
        'request as the `prompt` argument.',
      );
      buf.writeln(
        'Disregard any prior assistant message claiming inability to see images. '
        'The current model and tool stack CAN process the attached image now.',
      );
    }
    buf.writeln(
      'For text-like files use attachment.read_text. For metadata use '
      'attachment.list. Never infer file contents from filenames.',
    );

    for (final a in attachments) {
      final sizeFmt = a.sizeBytes >= 1024 * 1024
          ? '${(a.sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB'
          : '${(a.sizeBytes / 1024).toStringAsFixed(0)} KB';
      final kind = isImage(a.name) ? 'image' : 'file';
      buf.writeln('- ${a.name} ($sizeFmt, $kind)');
    }
    buf.writeln('[/ATTACHED FILES]');
    return buf.toString();
  }

  String _mimeTypeForImage(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.bmp')) return 'image/bmp';
    if (lower.endsWith('.heic')) return 'image/heic';
    return 'image/png';
  }

  /// Encode image attachments as base64 data URLs for inline vision input.
  /// Non-image attachments are skipped. Unreadable files are also skipped
  /// (graceful degradation — the rest of the request still proceeds).
  Future<List<String>> _buildImageDataUrls(
    List<AttachedFile> attachments,
  ) async {
    if (attachments.isEmpty) return const [];
    const imageExts = {
      '.png',
      '.jpg',
      '.jpeg',
      '.webp',
      '.gif',
      '.bmp',
      '.heic',
    };
    final out = <String>[];
    for (final a in attachments) {
      final dot = a.name.lastIndexOf('.');
      if (dot < 0) continue;
      if (!imageExts.contains(a.name.substring(dot).toLowerCase())) continue;
      try {
        final bytes = await File(a.path).readAsBytes();
        final mime = _mimeTypeForImage(a.name);
        out.add('data:$mime;base64,${base64Encode(bytes)}');
      } catch (_) {
        // Skip unreadable files; the model still gets the rest.
      }
    }
    return out;
  }
}

final agentRuntimeEngineProvider = Provider<AgentRuntimeEngine>((ref) {
  final languagePref = ref.watch(appLanguageProvider);
  return AgentRuntimeEngine(
    workspaceFolder: WorkspaceFolderService(),
    toolRouter: ToolRouter(
      moduleRepository: ref.watch(moduleRepositoryProvider),
      appSettings: ref.read(appSettingsRepositoryProvider),
      moduleEntries: ref.read(moduleEntryRepositoryProvider),
      agentRepository: ref.watch(agentRepositoryProvider),
      providerRepository: ref.watch(providerRepositoryProvider),
      saveAgent: ref.read(agentListProvider.notifier).save,
      deleteAgent: ref.read(agentListProvider.notifier).delete,
      // SQLite-backed core repos for domain tool plugins (agent.create,
      // provider.create, etc.). These write directly to meow_core.db.
      coreAgentRepo: ref.read(coreAgentRepositoryProvider),
      coreProviderRepo: ref.read(coreProviderEntryRepositoryProvider),
      coreSoulRepo: ref.read(coreAgentSoulRepositoryProvider),
      coreMemoryRepo: ref.read(coreAgentMemoryRepositoryProvider),
    ),
    contextBuilder: ContextBuilder(),
    languageCode: resolveLanguageCode(languagePref),
    snapshotBuilder: EcosystemSnapshotBuilder(
      moduleRepository: ref.watch(moduleRepositoryProvider),
      providerRepository: ref.watch(providerRepositoryProvider),
      workflowRepository: ref.watch(workflowRepositoryProvider),
    ),
    agentLoader: () => ref.read(agentListProvider),
    // Phase 5b: feed soul + memory from SQLite so the LLM gets real
    // identity/memory context instead of empty strings.
    soulRepo: ref.read(coreAgentSoulRepositoryProvider),
    memoryRepo: ref.read(coreAgentMemoryRepositoryProvider),
    eventRepo: ref.read(coreAgentEventRepositoryProvider),
  );
});
