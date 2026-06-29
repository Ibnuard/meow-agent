import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/storage/core_storage_providers.dart';
import '../../core/storage/secure_storage_service.dart';
import '../../core/storage/agent_skills_repository.dart';
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
import 'context_builder.dart';
import 'classify_phase.dart';
import 'classifier.dart';
import 'ecosystem_snapshot.dart';
import 'executor.dart';
import 'goal_tree.dart';
import 'history_slicer.dart';
import 'json_utils.dart';
import 'language_detector.dart';
import 'memory_extractor.dart';
import 'narrative_narrator.dart';
import 'prompt_templates.dart';

import 'pending_action.dart';
import 'pending_clarification.dart';
import 'completion_verifier.dart';
import 'confirmation_manager.dart';
import 'predefined_skills/predefined_skills.dart';
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

/// Entity types whose targets are resolved against the live ecosystem snapshot.
/// Only these may be passed to the planner as authoritative "resolved target"


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
    this.skillsRepo,
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
  final AgentSkillsRepository? skillsRepo;
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
    skillsRepo: skillsRepo,
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
  ///
  /// [userMessage] (optional) drives keyword-based memory recall — only
  /// memory entries relevant to the current turn are surfaced into the
  /// prompt. When null, the latest N entries are used (legacy behavior).
  Future<AgentWorkspace> _buildWorkspace(
    String agentName,
    String agentId, {
    String? userMessage,
    List<AgentSkill>? preFilteredSkills,
  }) async {
    return _contextBuilder.build(
      agentName,
      agentId,
      userMessage: userMessage,
      preFilteredSkills: preFilteredSkills,
    );
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

  /// Best-effort implicit memory extraction after successful tool work.
  /// Failure is ignored; memory must never block the visible user response.
  Future<void> _maybeExtractMemory({
    required AgentRuntimeRequest request,
    required OpenAiCompatibleClient client,
    required LlmProviderConfig config,
    required RuntimeLogger logger,
  }) async {
    final repo = memoryRepo;
    if (repo == null || request.agentId.isEmpty) return;
    final toolResults = logger.events
        .where((e) => e.type == 'tool_result' && e.data?['success'] == true)
        .map((e) => {'tool': e.data?['tool'], 'result': e.data?['data']})
        .toList(growable: false);
    if (toolResults.isEmpty) return;

    try {
      await MemoryExtractor(
        client: client,
        config: config,
        memoryRepo: repo,
      ).extractAfterTask(
        agentId: request.agentId,
        userMessage: request.userMessage,
        toolResults: toolResults,
        logger: logger,
      );
    } catch (_) {
      // Fire-and-forget.
    }
  }

  /// Best-effort idle session summarization.
  ///
  /// There is no background scheduler in the runtime engine, so "idle" is
  /// detected on the next turn: if the previous agent event is older than the
  /// idle threshold, summarize the recent chat slice into a `session` memory.
  Future<void> _maybeSummarizeIdleSession({
    required AgentRuntimeRequest request,
    required OpenAiCompatibleClient client,
    required LlmProviderConfig config,
  }) async {
    final memories = memoryRepo;
    final events = eventRepo;
    if (memories == null || events == null || request.agentId.isEmpty) return;
    final contextMessages = request.recentMessages
        .where((message) => message.includeInRuntimeContext)
        .toList(growable: false);
    if (contextMessages.length < 4) return;

    try {
      final recentEvents = await events.recent(request.agentId, limit: 1);
      if (recentEvents.isNotEmpty) {
        final gap = DateTime.now().difference(recentEvents.first.createdAt);
        if (gap < const Duration(minutes: 5)) return;
      }

      final recentSession = await memories.byCategory(
        request.agentId,
        'session',
        limit: 1,
      );
      if (recentSession.isNotEmpty) {
        final age = DateTime.now().difference(recentSession.first.createdAt);
        if (age < const Duration(minutes: 30)) return;
      }

      final transcript = contextMessages
          .take(20)
          .map((m) => '${m.role}: ${m.content}')
          .join('\n');
      if (transcript.trim().isEmpty) return;

      final response = await client.chat(
        config: config,
        phase: 'session_summary',
        messages: [
          {'role': 'system', 'content': PromptConstants.sessionSummarySystem},
          {
            'role': 'user',
            'content': PromptConstants.sessionSummaryUser(transcript),
          },
        ],
      );
      final parsed = JsonUtils.tryParseObject(response);
      final summary = (parsed?['summary'] ?? '').toString().trim();
      if (summary.isEmpty || summary.length < 20) return;
      await memories.append(
        agentId: request.agentId,
        content: summary,
        category: 'session',
      );
    } catch (_) {
      // Fire-and-forget.
    }
  }

  Map<String, PendingAction> get _pendingActions =>
      _confirmation.pendingActions;
  Map<String, PendingClarification> get _pendingClarifications =>
      _confirmation.pendingClarifications;

  Future<List<Map<String, dynamic>>> _buildToolPreflight({
    required Set<String> toolNames,
  }) async {
    final items = <Map<String, dynamic>>[];
    final names = toolNames.toList()..sort();
    for (final name in names) {
      final def = toolRouter.getDefinition(name);
      if (def == null || def.hiddenFromModel) continue;
      final denied = await toolRouter.permissionDeniedResult(name);
      items.add({
        'tool': name,
        'risk': def.risk,
        'requiresConfirmation': def.requiresConfirmation,
        'operation': def.operation,
        'targetEntity': def.targetEntity,
        'permission': denied == null ? 'allowed' : 'blocked',
        if (denied?.data != null) 'block': denied!.data,
      });
    }
    return items;
  }

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

  /// Whether a confirmed "lanjut"/"continue" on a parked ledger should RESTART
  /// the task from its original goal rather than replay the single parked tool.
  ///
  /// App-launch tasks operate on LIVE device state (the foreground app). When a
  /// task parks for a permission, the user physically leaves the target app to
  /// flip the toggle, so any captured foreground state and the parked tool's
  /// args are now stale. Restarting from `ledger.originalUserMessage` re-issues
  /// `app.open` deterministically and drives the real goal again.
  bool _resumeRequiresRestart(TaskLedger ledger) {
    const liveStateTools = {'app.open', 'app.resolve', 'device.foreground_app'};
    final parked = ledger.pendingToolName ?? '';
    return liveStateTools.contains(parked);
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
    final cancelToken = CancelToken();
    _taskScope.registerCancelToken(request.agentId, cancelToken);
    final logger = RuntimeLogger();
    void emit(RuntimeEvent event) {
      onEvent?.call(event);
    }

    var effectiveLang = 'en';
    AgentSoul? activeSoul;
    try {
      activeSoul = await soulRepo?.get(request.agentId);
      if (activeSoul?.preferredLanguage?.trim().isNotEmpty == true) {
        effectiveLang = activeSoul!.preferredLanguage!.trim();
      }
    } catch (e) {
      logger.logError('Failed to load agent soul early', e);
    }

    // Initialize prompt caching for this conversation turn. All LLM calls
    // within this turn (analyze, reflect, plan, execute, verbalize) share
    // the same cache key so the provider can reuse the prefix.
    // See REVIEWED.md Level 1: Provider Prompt Caching.
    OpenAiCompatibleClient.initSession(
      '${request.agentId}:${request.source.name}:${DateTime.now().millisecondsSinceEpoch ~/ 60000}',
    );

    final llmConfig = LlmProviderConfig(
      baseUrl: provider.baseUrl,
      apiKey: provider.apiKey,
      model: provider.model,
      supportsFunctionCalling: provider.supportsFunctionCallingFor(
        provider.model,
      ),
      supportsPromptCaching: true,
    );
    final client = _client;
    unawaited(
      _maybeSummarizeIdleSession(
        request: request,
        client: client,
        config: llmConfig,
      ),
    );
    final executor = Executor(
      client: client,
      config: llmConfig,
      cancelToken: cancelToken,
    );
    final classifyPhase = ClassifyPhase(
      classifier: Classifier(
        client: client,
        config: llmConfig,
        cancelToken: cancelToken,
      ),
    );
    final isWorkflowAutoExecute =
        request.source == RequestSource.workflow && autoApproveSensitive;
    var detectedLang = _languageDetector.detect(
      userMessage: request.userMessage,
      fallbackCode: effectiveLang,
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
      // When set, a confirmed resume chose to RESTART an app-automation task
      // from its original goal rather than replay the stale parked tool. Applied
      // to effectiveUserMessage further down (its declaration site).
      String? restartFromOriginalMessage;
      if (pending != null) {
        pendingDecision = ConfirmationChecker.check(request.userMessage);
        logger.logStateChange(
          AgentRuntimeState.analyzing,
          'Pending action detected: ${pending.toolName}, deterministic decision: ${pendingDecision.name}',
        );
        emit(logger.events.last);
        // RESTART-ON-RESUME: for app-automation tasks the parked tool + captured
        // screen/foreground state are stale (the user left the target app to
        // grant a permission). Re-run the original goal from scratch instead of
        // firing the fragment — the fresh plan re-issues app.open deterministically.
        var didRestart = false;
        if (pendingDecision == ConfirmationDecision.confirmed) {
          final restartLedger = await ledgerDb.findActive(
            agentId: request.agentId,
            source: LedgerSource.chat,
            // SAME 6h guard as the other resume paths — do not widen.
            maxAge: const Duration(hours: 6),
          );
          if (restartLedger != null &&
              _resumeRequiresRestart(restartLedger) &&
              restartLedger.originalUserMessage.trim().isNotEmpty) {
            _confirmation.clearPending(request.agentId);
            pending = null;
            pendingDecision = ConfirmationDecision.none;
            restartFromOriginalMessage = restartLedger.originalUserMessage;
            didRestart = true;
            logger.logStateChange(
              AgentRuntimeState.analyzing,
              'Restarting app-automation task from original goal after permission grant '
              '(stale parked tool dropped).',
            );
            emit(logger.events.last);
          }
        }
        if (!didRestart) {
          final pendingResponse = await _confirmation.handleDecision(
            request: request,
            pending: pending!,
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
      // Slice conversation history for the prompt. HistorySlicer pins the
      // original user goal at the front so it is never lost behind the recent
      // window — this prevents goal drift on complex multi-step tasks where
      // many tool results would otherwise push the request out of context.
      // Provider-error sentinel messages are stripped inside the slicer.
      final recentMsgs = HistorySlicer.slice(messages: request.recentMessages);
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
        // Age guard: a task parked for hours must not silently re-anchor an
        // unrelated new turn. Workflows run unattended on a schedule, so the
        // guard only applies to interactive chat ledgers.
        maxAge: request.source == RequestSource.workflow
            ? null
            : const Duration(hours: 6),
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



      await workspaceFolder.ensureFolder(wsName);

      // activeSoul is loaded early at the start of run()
      final allActiveSkills = skillsRepo != null
          ? await skillsRepo!.getActiveSkillsForAgent(request.agentId)
          : const <AgentSkill>[];

      // P2: Keyword-based skill filtering — no LLM call needed.
      // Uses the same tokenization pattern as memory recall.
      final filteredSkills = WorkspaceContextBuilder.selectRelevantSkills(
        activeSkills: allActiveSkills,
        userMessage: request.userMessage,
      );
      if (filteredSkills.length != allActiveSkills.length) {
        logger.logStateChange(
          AgentRuntimeState.analyzing,
          'Keyword-filtered skills: ${filteredSkills.length}/${allActiveSkills.length} active',
        );
      }

      final workspace = await _buildWorkspace(
        wsName,
        request.agentId,
        userMessage: request.userMessage,
        preFilteredSkills: filteredSkills,
      );
      // Build stable context prefix once for this turn — all phases
      // (analyze, reflect, plan, selectTool, review) share it for caching.
      // See REVIEWED.md Level 2: Stable Prompt Prefix.
      final stableContext = PromptTemplates.buildStableContext(
        soul: workspace.soul,
        skills: workspace.skills,
        agentName: wsName,
        agentId: request.agentId,
      );
      final userNotIntroduced = _isUserNameMissing(activeSoul);
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
      // App-automation restart-on-resume: re-plan from the ORIGINAL goal (e.g.
      // "buka facebook, cek 2 post, summarize"), not the bare "lanjutkan" turn,
      // so analyze/plan/loop rebuild the real task and re-open the app.
      if (restartFromOriginalMessage != null) {
        effectiveUserMessage = restartFromOriginalMessage;
      }
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
      var analyzerTools = <String>[];
      var availableTools = <String>[];
      logger.logStateChange(
        AgentRuntimeState.analyzing,
        'Skill context: compact predefined skill index${activeTaskContext.isNotEmpty ? ' [active-task ctx]' : ''}',
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
      // Build snapshot early — classify (merged analyze+reflect+plan) needs it.
      final classifySnapshot = await _buildSnapshot();
      // Merged L3 call: routing + intent + strategy + goal tree in ONE LLM
      // round-trip. Replaces the old 3-phase analyze→reflect→plan sequence.
      // See codebase_analysis.md P0/L3.
      final classifyResult = await classifyPhase.run(
        userMessage: effectiveUserMessage,
        workspace: workspace,
        snapshot: classifySnapshot,
        availableTools: _toolDefinitionsFor(toolRouter.registeredTools.toSet()),
        language: detectedLang,
        logger: logger,
        stableContext: stableContext,
        recentMessages: recentMsgs,
        pendingAction: pending,
        recentToolMemory: _memory.formatForPrompt(request.agentId),
        isWorkflowAutoExecute: isWorkflowAutoExecute,
        activeTaskContext: activeTaskContext,
        agentName: wsName,
        agentId: request.agentId,
      );
      // Handle chat route from the merged call.
      if (classifyResult.isChatRoute && classifyResult.directResponse.isNotEmpty) {
        logger.logStateChange(AgentRuntimeState.done, 'Chat response');
        emit(logger.events.last);
        logger.logFinalResponse(classifyResult.directResponse);
        return AgentRuntimeResponse(
          finalMessage: classifyResult.directResponse,
          success: true,
          state: AgentRuntimeState.done,
          events: logger.events,
        );
      }
      // Extract analysis-level fields for downstream deterministic logic.
      var analysis = classifyResult.analysis;
      emit(logger.events.last);
      final analysisEvidenceRef = 'runtime_event:${logger.events.last.id}';
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
      if (earlyMissingInfo.isEmpty && gatedAnalyzeNarrative.isNotEmpty) {
        if (logger.logStreamBubble(
          kind: 'analysis_summary',
          phase: 'analyze',
          message: gatedAnalyzeNarrative,
          evidenceRefs: [analysisEvidenceRef],
          contextPolicy: 'exclude',
        )) {
          emit(logger.events.last);
        }
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
      final analyzerRequiresTools = analysis['requires_tools'] == true;
      if (activeTaskContext.isEmpty && analyzerRequiresTools) {
        final narrowed = _toolSelectionFromAnalysis(analysis);
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
            'Tool surface narrowed from analyzer: ${narrowed.reason} (${availableTools.length} tools, confidence ${narrowed.confidence.toStringAsFixed(2)})',
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
            pendingDecision != ConfirmationDecision.previewOnly) {
          // The analyzer classified the new message as unrelated to the active
          // task ("none"). Regardless of whether it needs tools, that means the
          // prior task must NOT stay in focus — promote to new_task so the
          // stale scope is archived and activeTaskContext is dropped from every
          // downstream prompt. (Previously this only fired when
          // requires_tools==true, leaving a no-tools follow-up anchored to the
          // old goal — a context-bleed channel.)
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
          if (analysis['requires_tools'] == true) {
            final narrowed = _toolSelectionFromAnalysis(analysis);
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
          }
          final headsUp = await verbalizer.taskAborted(
            previousMainGoal: previousGoal,
            language: detectedLang,
          );
          logger.logStateChange(
            AgentRuntimeState.analyzing,
            'Active task scope archived (aborted) due to new_task classification. Tools re-narrowed to ${availableTools.length} from analyzer hints. Heads-up surfaced.',
          );
          emit(logger.events.last);
          if (logger.logNarrative('relation', headsUp)) {
            emit(logger.events.last);
          }
        } else if (pendingClarification != null &&
            effectiveUserMessage != mergedUserMessage) {
          effectiveUserMessage = mergedUserMessage;
          final reClarifyResult = await classifyPhase.run(
            userMessage: effectiveUserMessage,
            workspace: workspace,
            snapshot: classifySnapshot,
            availableTools: _toolDefinitionsFor(toolRouter.registeredTools.toSet()),
            language: detectedLang,
            logger: logger,
            stableContext: stableContext,
            recentMessages: recentMsgs,
            pendingAction: pending,
            recentToolMemory: _memory.formatForPrompt(request.agentId),
            isWorkflowAutoExecute: isWorkflowAutoExecute,
            activeTaskContext: activeTaskContext,
            agentName: wsName,
            agentId: request.agentId,
          );
          analysis = reClarifyResult.analysis;
          emit(logger.events.last);
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
        if (logger.logStreamBubble(
          kind: 'decision_question',
          phase: 'analyze',
          message: question,
          evidenceRefs: [analysisEvidenceRef],
          contextPolicy: 'include',
        )) {
          emit(logger.events.last);
        }
        logger.logFinalResponse(question);
        return AgentRuntimeResponse(
          finalMessage: question,
          success: true,
          state: state,
          events: logger.events,
        );
      }
      _pendingClarifications.remove(request.agentId);
      if (analysis['requires_tools'] == true) {
        final toolPreflight = await _buildToolPreflight(
          toolNames: toolSelection.toolNames,
        );
        if (toolPreflight.isNotEmpty) {
          logger.logLlmDecision('tool_preflight', {
            'candidate_count': toolPreflight.length,
            'candidates': toolPreflight,
          });
          emit(logger.events.last);
          final allowedCount = toolPreflight
              .where((tool) => tool['permission'] == 'allowed')
              .length;
          logger.logStateChange(
            AgentRuntimeState.planning,
            'Tool plan preflight: $allowedCount/${toolPreflight.length} candidate tools currently allowed',
          );
          emit(logger.events.last);
        }
      }
      ReflectionOutput? reflection;
      TargetResolutionGraph? targetGraph;
      var pendingNextNarrative = (analysis['next_narrative'] ?? '')
          .toString()
          .trim();
      String takeNextNarrative(String fallbackPhase) {
        final llmNarrative = pendingNextNarrative;
        pendingNextNarrative = '';
        return llmNarrative.isNotEmpty
            ? llmNarrative
            : NarrativeNarrator.narrateNext(fallbackPhase, detectedLang.code);
      }

      final analyzerSaysToolsForReflect = analysis['requires_tools'] == true;
      if (analyzerSaysToolsForReflect && !isWorkflowAutoExecute) {
        if (logger.logPreActionNarrative(
          'reflecting',
          takeNextNarrative('reflecting'),
        )) {
          emit(logger.events.last);
        }
      }
      // Reflection already came from the merged classify call — no separate
      // LLM round-trip needed. Just run deterministic target resolution.
      final shouldReflect =
          analyzerSaysToolsForReflect && !isWorkflowAutoExecute;
      if (shouldReflect) {
        state = AgentRuntimeState.analyzing;
        logger.logStateChange(state, 'Reflecting on impact and slot needs');
        emit(logger.events.last);
        final snapshot = classifySnapshot;
        reflection = classifyResult.reflection;
        final targetResolution = TargetResolver.resolveReflection(
          reflection: reflection,
          snapshot: snapshot,
          request: request,
          language: detectedLang,
        );
        reflection = targetResolution.reflection;
        targetGraph = targetResolution.graph;
        pendingNextNarrative = reflection.nextNarrative.trim();
        logger.logLlmDecision('reflect', reflection.toJson());
        emit(logger.events.last);
        final reflectionEvidenceRefs = <String>[
          'runtime_event:${logger.events.last.id}',
          if (snapshot.builtAt.millisecondsSinceEpoch > 0)
            'snapshot:${snapshot.builtAt.toIso8601String()}',
          ...reflection.impacts
              .where((impact) => impact.entityId.isNotEmpty)
              .map(
                (impact) =>
                    '${impact.entityType}:${impact.entityId}:${impact.relation}',
              ),
        ];
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
          if (!reflection.degraded &&
              logger.logStreamBubble(
                kind: reflection.impacts.isEmpty
                    ? 'decision_summary'
                    : 'impact',
                phase: 'reflect',
                message: gatedReflect,
                evidenceRefs: reflectionEvidenceRefs,
                contextPolicy: reflection.impacts.isEmpty
                    ? 'exclude'
                    : 'include',
              )) {
            emit(logger.events.last);
          }
        }
        if (reflection.strategy == ReflectionStrategy.clarify &&
            reflection.clarifyQuestions.isNotEmpty) {
          final question = reflection.clarifyQuestions.first;
          _pendingClarifications[request.agentId] = PendingClarification(
            originalMessage: request.userMessage,
            questions: reflection.clarifyQuestions,
            createdAt: DateTime.now(),
          );
          if (logger.logStreamBubble(
            kind: 'decision_question',
            phase: 'reflect',
            message: question,
            evidenceRefs: reflectionEvidenceRefs,
            contextPolicy: 'include',
          )) {
            emit(logger.events.last);
          }
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
        if (logger.logPreActionNarrative(
          'composing',
          takeNextNarrative('composing'),
        )) {
          emit(logger.events.last);
        }

        final analyzerDirectResponse = (analysis['direct_response'] ?? '')
            .toString()
            .trim();
        String directResponse;
        if (analyzerDirectResponse.isNotEmpty) {
          directResponse = analyzerDirectResponse;
          logger.logStateChange(
            state,
            'Direct response retrieved from analyzer',
          );
          emit(logger.events.last);
        } else {
          final selfIdentity = PromptConstants.selfIdentity(
            agentName: wsName,
            agentId: request.agentId,
          );
          final identityBlock =
              'Identity context (user profile stored in database):\n${workspace.soul}'
              '${workspace.skills.isEmpty ? '' : '\n\n${workspace.skills}'}';
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

          directResponse = await client.chat(
            config: llmConfig,
            phase: 'direct',
            messages: [
              {'role': 'system', 'content': systemContent},
              ...recentMsgs,
              {'role': 'user', 'content': effectiveUserMessage},
            ],
            imageDataUrls: imageDataUrls,
          );
        }
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
      // Accuracy-first runtime: interactive tool tasks always pass through the
      // planner so the ledger has explicit subgoals, slots, completion
      // criteria, and a reviewable plan. Function-calling fast-path remains
      // disabled from this entry point; it is only kept inside the loop runner
      // for callers that explicitly opt into it later.
      const isFastPath = false;
      state = AgentRuntimeState.planning;
      logger.logStateChange(state, 'Creating execution plan');
      emit(logger.events.last);
      if (logger.logPreActionNarrative(
        'planning',
        takeNextNarrative('planning'),
      )) {
        emit(logger.events.last);
      }
      _logEvent(
        agentId: request.agentId,
        eventType: 'state_change',
        state: state.name,
        task: request.userMessage,
      );
      // Build resolved target labels for the planner so it can emit
      // per-entity subgoals for bulk/fan-out operations.
      //
      // ONLY snapshot-backed entity types (agent/workflow/provider/module)
      // are passed as authoritative resolved labels. Those are genuinely
      // matched against live state, so they cannot carry prior-turn bleed.
      //
      // App/message/screen/etc. targets are NOT snapshot-validated — the
      // reflector can (and did, in a context-bleed case) copy a PRIOR task's
      // app target ("open LinkedIn") into a brand-new task ("open Facebook")
      // because the prior turn is still in recentMessages. Feeding those as
      // "use verbatim" labels forces the planner to build the wrong goal.
      // Plan already came from the merged classify call — no separate
      // LLM round-trip needed.
      var plan = classifyResult.plan;
      if (plan['subgoals'] == null || (plan['subgoals'] as List?)?.isEmpty == true) {
        // Fallback: classify didn't emit subgoals, synthesize from analysis.
        logger.logError(
          'Classify returned empty plan; synthesizing fallback from analysis.',
        );
        plan = _fallbackPlanFromAnalysis(
          analysis: analysis,
          userMessage: effectiveUserMessage,
        );
      }
      _attachSelectedSkillContext(plan, analysis);
      final planEvidenceRef = 'runtime_event:${logger.events.last.id}';
      final planNarrative = (plan['narrative'] ?? '').toString();
      final planLabels = (plan['subgoals'] as List? ?? const [])
          .whereType<Map>()
          .map((subgoal) => (subgoal['label'] ?? '').toString().trim())
          .where((label) => label.isNotEmpty)
          .toList(growable: false);
      final planBubble = [
        if (planNarrative.trim().isNotEmpty) planNarrative.trim(),
        if (planLabels.length > 1)
          planLabels.map((label) => '• $label').join('\n'),
      ].join('\n\n');
      if (planBubble.isNotEmpty) {
        if (logger.logStreamBubble(
          kind: 'plan_summary',
          phase: 'plan',
          message: planBubble,
          evidenceRefs: [planEvidenceRef],
          contextPolicy: 'exclude',
        )) {
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
      Future<({Map<String, dynamic> plan, GoalTree goalTree, List<String> requiredCapabilities})?>
      rethink() async {
        try {
          // Rebuild the ecosystem snapshot fresh — tools executed since the
          // initial classify may have mutated state (created tables, mini
          // apps, providers, etc.). Reusing the pre-mutation snapshot would
          // make the rethink re-plan against stale entities and re-attempt
          // already-satisfied subgoals.
          final freshSnapshot = await _buildSnapshot();
          final freshAnalysis = Map<String, dynamic>.from(capturedAnalysis);
          final priorContext = recovery.toReflectionContextList();
          if (priorContext.isNotEmpty) {
            freshAnalysis['prior_attempts'] = priorContext;
          }
          freshAnalysis['available_tools_broadened'] = true;
          // Recovery: re-run the merged classify with the fresh analysis
          // context (prior attempts injected) to get a new reflection + plan
          // in a single LLM call.
          final reClassify = await classifyPhase.run(
            userMessage: effectiveUserMessage,
            workspace: workspace,
            snapshot: freshSnapshot,
            availableTools: _toolDefinitionsFor(
              toolRouter.registeredTools.toSet(),
            ),
            language: detectedLang,
            logger: logger,
            stableContext: stableContext,
            recentMessages: recentMsgs,
            recentToolMemory: _memory.formatForPrompt(request.agentId),
            isWorkflowAutoExecute: isWorkflowAutoExecute,
            activeTaskContext: activeTaskContext,
            agentName: wsName,
            agentId: request.agentId,
          );
          final reReflection = reClassify.reflection;
          final newPlan = reClassify.plan;
          // Resolve targets from the fresh reflection so the goal-tree
          // fan-out fallback sees snapshot-matched entities.
          final reTargetResolution = TargetResolver.resolveReflection(
            reflection: reReflection,
            snapshot: freshSnapshot,
            request: request,
            language: detectedLang,
          );
          final reTargetGraph = reTargetResolution.graph;
          if (reTargetGraph.isNotEmpty) {
            newPlan['runtime_target_graph'] = reTargetGraph.toJson();
          }
          _attachSelectedSkillContext(newPlan, freshAnalysis);
          // Rebuild goal tree from the planner output and resolved targets.
          final newTree = _buildGoalTree(
            plan: newPlan,
            analysis: freshAnalysis,
            userMessage: effectiveUserMessage,
            resolvedTargets: reTargetGraph.targets,
          );
          return (plan: newPlan, goalTree: newTree, requiredCapabilities: reClassify.requiredCapabilities);
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
        stableContext: stableContext,
        requiredCapabilities: classifyResult.requiredCapabilities,
      );

      await _maybeExtractMemory(
        request: loopRequest,
        client: client,
        config: llmConfig,
        logger: logger,
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
          initialPreviousResults: loopResponse.previousResults,
          initialStep: loopResponse.nextStep ?? 1,
          stableContext: stableContext,
        );
      }

      return loopResponse;
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        // User cancelled mid-call. The chat manager already posted the
        // cancellation message and cleared the running state — return a silent
        // empty failure so we don't surface a duplicate error bubble.
        logger.logStateChange(
          AgentRuntimeState.failed,
          'Run cancelled by user',
        );
        await _taskScope.finishScopeForRequest(request, LedgerStatus.aborted);
        return AgentRuntimeResponse(
          finalMessage: '',
          success: false,
          state: AgentRuntimeState.failed,
        );
      }
      logger.logError('Runtime exception', e);
      await _taskScope.finishScopeForRequest(request, LedgerStatus.failed);
      return _loopRunner.fail(
        LlmErrorMapper.friendlyMessage(e, effectiveLang),
        logger,
      );
    } catch (e) {
      logger.logError('Runtime exception', e);
      await _taskScope.finishScopeForRequest(request, LedgerStatus.failed);
      return _loopRunner.fail(
        LlmErrorMapper.friendlyMessage(e, effectiveLang),
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
            'args': pending.toolArgs,
            'success': true,
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
      // Tool FAILED. For a multi-step task (resume context present) a failure
      // is NOT terminal — it is exactly the signal the execute loop's review +
      // self-heal flow is built to handle (missing precondition, missing
      // toolchain, transient blip). Re-enter the loop with the failed result
      // in previousResults so the selector picks the corrective next step and
      // re-attempts, instead of dead-ending the whole task here. Only when
      // there is no resume context (a one-off confirmed action with no
      // surrounding plan) do we synthesize a final failure message.
      final failureResume = pending.resumeContext;
      if (failureResume != null) {
        final treeJson = failureResume['goal_tree'] as Map<String, dynamic>?;
        final goalTree = treeJson != null
            ? GoalTree.fromJson(treeJson)
            : GoalTree.singleSubgoal(
                mainGoal: pending.toolName,
                subgoalLabel: pending.toolName,
              );
        // Keep the active subgoal open — the action did not complete. The
        // selector/reviewer will drive the corrective step and retry.
        final active = goalTree.nextActionable;
        if (active != null) {
          active.status = SubgoalStatus.inProgress;
          active.notes = 'confirmed tool failed; recovering';
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
            (failureResume['plan'] as Map?)?.cast<String, dynamic>() ??
            {'steps': []};
        final previousResults =
            (failureResume['previous_results'] as List?)
                ?.whereType<Map>()
                .map((m) => m.cast<String, dynamic>())
                .toList() ??
            <Map<String, dynamic>>[];
        // Record the FAILED result (including stderr/error) so the selector
        // sees the cause and the self-heal rules fire on the next step.
        previousResults.add({
          'step': failureResume['current_step'] ?? 1,
          'tool': pending.toolName,
          'args': pending.toolArgs,
          'success': false,
          'result': result.data,
          'error': result.error,
          'confirmed': true,
        });
        final availableTools =
            (failureResume['available_tools'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const <String>[];
        final memorySnapshot =
            (failureResume['memory_snapshot'] as String?) ?? '';
        final autoApproveSensitive =
            failureResume['auto_approve_sensitive'] as bool? ?? false;
        final isWorkflowAutoExecute =
            failureResume['is_workflow_auto_execute'] as bool? ?? false;
        final currentStep = (failureResume['current_step'] as int? ?? 1) + 1;
        final userMessage =
            (failureResume['user_message'] as String?) ?? request.userMessage;
        final resumedRequest = AgentRuntimeRequest(
          agentId: request.agentId,
          agentName: request.agentName,
          userMessage: userMessage,
          recentMessages: request.recentMessages,
          source: request.source,
        );
        logger.logStateChange(
          AgentRuntimeState.selectingTool,
          'Resuming execute loop after confirmed-tool FAILURE for self-heal '
          '(subgoals remaining: ${goalTree.subgoals.where((s) => !s.isTerminal).length})',
        );
        emit(logger.events.last);
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

      // No resume context: a one-off confirmed action that failed. Surface the
      // specific cause to the user rather than a generic abort.
      final rawCause = ExecuteLoopRunner.extractFailureCause(result);
      final fallbackMsg = rawCause.isNotEmpty
          ? rawCause
          : await verbalizer.abort(
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
    final seeds = analysis['subgoal_seeds'];
    // The analyzer's explicit enumeration is a lower-bound invariant. If the
    // planner collapses eight requested rows into one coarse "populate" goal,
    // keep the per-item seeds so progress and completion cannot stop at row 1.
    final subgoalsJson = plan['subgoals'];
    final plannerCollapsedEnumeration =
        seeds is List &&
        seeds.length > 1 &&
        (subgoalsJson is! List || subgoalsJson.length < seeds.length);
    if (!plannerCollapsedEnumeration &&
        subgoalsJson is List &&
        subgoalsJson.isNotEmpty) {
      try {
        final tree = GoalTree.fromJson({
          'main_goal': mainGoal,
          'completion_criteria': plan['completion_criteria'] ?? const [],
          'subgoals': subgoalsJson,
        });
        return _withStructuralAnalysisMetadata(tree, analysis);
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
                if (t.operation.isNotEmpty) '_operation': t.operation,
                if (t.entityId.isNotEmpty) 'entity_id': t.entityId,
                if (t.entityLabel.isNotEmpty) 'entity_label': t.entityLabel,
                'name': t.entityLabel,
              },
            ),
        ],
      );
    }
    if (seeds is List && seeds.length > 1) {
      final operation = _structuralOperationFromAnalysis(analysis);
      final expectedTool = _structuralToolFromAnalysis(analysis);
      return GoalTree(
        mainGoal: mainGoal,
        subgoals: [
          for (var i = 0; i < seeds.length; i++)
            Subgoal(
              id: 'sg${i + 1}',
              label: seeds[i].toString(),
              requiredSlots: {
                if (operation.isNotEmpty) '_operation': operation,
                if (expectedTool.isNotEmpty) 'tool': expectedTool,
              },
            ),
        ],
      );
    }
    final operation = _structuralOperationFromAnalysis(analysis);
    final expectedTool = _structuralToolFromAnalysis(analysis);
    return GoalTree(
      mainGoal: mainGoal,
      subgoals: [
        Subgoal(
          id: 'sg_main',
          label: mainGoal,
          requiredSlots: {
            if (operation.isNotEmpty) '_operation': operation,
            if (expectedTool.isNotEmpty) 'tool': expectedTool,
          },
        ),
      ],
    );
  }

  String _structuralOperationFromAnalysis(Map<String, dynamic> analysis) {
    final intent = (analysis['intent'] ?? '').toString().toLowerCase();
    final tokens = intent.split(RegExp(r'[^a-z]+')).where((e) => e.isNotEmpty);
    const operations = {
      'create',
      'update',
      'delete',
      'rename',
      'toggle',
      'read',
      'list',
      'search',
      'get',
      'status',
      'inspect',
      'query',
      'summarize',
      'classify',
      'open',
      'send',
      'respond',
    };
    for (final token in tokens.toList().reversed) {
      if (operations.contains(token)) return token;
    }
    return '';
  }

  String _structuralToolFromAnalysis(Map<String, dynamic> analysis) {
    final intent = (analysis['intent'] ?? '').toString().trim();
    return toolRouter.getDefinition(intent) == null ? '' : intent;
  }

  GoalTree _withStructuralAnalysisMetadata(
    GoalTree tree,
    Map<String, dynamic> analysis,
  ) {
    final inferredOperation = _structuralOperationFromAnalysis(analysis);
    final inferredTool = _structuralToolFromAnalysis(analysis);
    if (inferredOperation.isEmpty && inferredTool.isEmpty) return tree;

    return GoalTree(
      mainGoal: tree.mainGoal,
      completionCriteria: tree.completionCriteria,
      subgoals: [
        for (final subgoal in tree.subgoals)
          Subgoal(
            id: subgoal.id,
            label: subgoal.label,
            requiredSlots: {
              ...subgoal.requiredSlots,
              if (!subgoal.requiredSlots.containsKey('_operation') &&
                  inferredOperation.isNotEmpty)
                '_operation': inferredOperation,
              if (!subgoal.requiredSlots.containsKey('tool') &&
                  !subgoal.requiredSlots.containsKey('tool_name') &&
                  inferredTool.isNotEmpty)
                'tool': inferredTool,
            },
            missingSlots: subgoal.missingSlots,
            status: subgoal.status,
            resultRef: subgoal.resultRef,
            notes: subgoal.notes,
          ),
      ],
    );
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

  Map<String, dynamic> _fallbackPlanFromAnalysis({
    required Map<String, dynamic> analysis,
    required String userMessage,
  }) {
    final mainGoal = (analysis['goal'] ?? userMessage).toString();
    final seeds = (analysis['subgoal_seeds'] as List?)
        ?.map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    final labels = seeds == null || seeds.isEmpty ? <String>[mainGoal] : seeds;
    final operation = _operationFromAnalysis(analysis);
    return {
      'main_goal': mainGoal,
      'completion_criteria': [
        'The requested outcome is completed and verified.',
      ],
      'subgoals': [
        for (var i = 0; i < labels.length; i++)
          {
            'id': labels.length == 1 ? 'sg_main' : 'sg${i + 1}',
            'label': labels[i],
            'required_slots': {'_operation': operation},
            'missing_slots': <String>[],
            'status': 'pending',
          },
      ],
      'narrative': '',
    };
  }

  String _operationFromAnalysis(Map<String, dynamic> analysis) {
    final text = [
      analysis['intent'],
      analysis['goal'],
      ...(analysis['subgoal_seeds'] as List? ?? const []),
    ].map((e) => e.toString().toLowerCase()).join(' ');
    const ordered = <String>[
      'delete',
      'remove',
      'update',
      'patch',
      'edit',
      'rename',
      'toggle',
      'create',
      'insert',
      'add',
      'open',
      'launch',
      'send',
      'write',
      'read',
      'list',
      'search',
      'query',
      'summarize',
      'classify',
      'status',
      'get',
    ];
    for (final op in ordered) {
      if (text.contains(op)) {
        return switch (op) {
          'remove' => 'delete',
          'patch' || 'edit' => 'update',
          'insert' || 'add' => 'create',
          'launch' => 'open',
          _ => op,
        };
      }
    }
    return 'execute';
  }

  ToolCatalogSelection _toolSelectionFromAnalysis(
    Map<String, dynamic> analysis,
  ) {
    final rawSkillIds = analysis['selected_skill_ids'];
    final skillIds = rawSkillIds is List
        ? PredefinedSkillRegistry.normalizeSkillIds(rawSkillIds)
        : <String>[];

    if (skillIds.isNotEmpty) {
      final toolNames = PredefinedSkillRegistry.toolNamesForSkillIds(skillIds);
      if (toolNames.isNotEmpty) {
        final groups = PredefinedSkillRegistry.toolGroupsForSkillIds(skillIds);
        return ToolCatalogSelection(
          toolNames: toolNames,
          groups: groups,
          confidence: skillIds.length == 1 ? 0.85 : 0.7,
          reason: 'analyzer selected_skill_ids: ${skillIds.join(', ')}',
        );
      }
    }

    final groupsHint = (analysis['tool_groups'] as List?)
        ?.map((e) => e.toString())
        .toList();
    return ToolCatalog.fromGroups(groupsHint);
  }

  void _attachSelectedSkillContext(
    Map<String, dynamic> plan,
    Map<String, dynamic> analysis,
  ) {
    final rawSkillIds = analysis['selected_skill_ids'];
    if (rawSkillIds is! List) return;
    final detail = PredefinedSkillRegistry.skillDetailBlock(rawSkillIds).trim();
    if (detail.isEmpty) return;
    plan['_selected_skill_context'] = detail;
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
      coreSkillsRepo: ref.read(agentSkillsRepositoryProvider),
      secureStorage: ref.read(secureStorageProvider),
    ),
    contextBuilder: ContextBuilder(),
    languageCode: resolveLanguageCode(languagePref),
    snapshotBuilder: EcosystemSnapshotBuilder(
      moduleRepository: ref.watch(moduleRepositoryProvider),
      providerRepository: ref.watch(providerRepositoryProvider),
      workflowRepository: ref.watch(workflowRepositoryProvider),
    ),
    agentLoader: () => ref.read(agentListProvider),
    soulRepo: ref.read(coreAgentSoulRepositoryProvider),
    memoryRepo: ref.read(coreAgentMemoryRepositoryProvider),
    eventRepo: ref.read(coreAgentEventRepositoryProvider),
    skillsRepo: ref.read(agentSkillsRepositoryProvider),
  );
});
