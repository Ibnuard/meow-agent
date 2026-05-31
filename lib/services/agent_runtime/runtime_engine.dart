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
    _taskScope = TaskScopeManager(
      ledgerDb: this.ledgerDb,
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
          _taskScope.finishScopeForRequest(request, terminal),
    );
    _taskScope.attachConfirmation(_confirmation);
    _loopRunner = ExecuteLoopRunner(
      toolRouter: toolRouter,
      workspaceLoader: workspaceLoader,
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

  final WorkspaceLoader workspaceLoader;
  final ToolRouter toolRouter;
  final ContextBuilder contextBuilder;
  final String languageCode;
  final EcosystemSnapshotBuilder? snapshotBuilder;
  final List<AgentModel> Function()? agentLoader;
  final TaskLedgerDatabase ledgerDb;
  final OpenAiCompatibleClient _client;
  final Future<EcosystemSnapshot> Function()? _snapshotOverride;
  late final PreflightChecker _preflight;
  late final CompletionVerifier _completionVerifier;
  late final TaskScopeManager _taskScope;
  late final ConfirmationManager _confirmation;
  late final ExecuteLoopRunner _loopRunner;
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

  Map<String, PendingAction> get _pendingActions => _confirmation.pendingActions;
  Map<String, PendingClarification> get _pendingClarifications =>
      _confirmation.pendingClarifications;

  PendingAction? getPendingAction(String agentId) =>
      _confirmation.getPending(agentId);
  void clearPendingAction(String agentId) =>
      _confirmation.clearPending(agentId);
  void clearPendingClarification(String agentId) =>
      _confirmation.clearClarification(agentId);
  Future<void> abortActiveTask(String agentId, {RequestSource source = RequestSource.chat}) =>
      _taskScope.abortActive(agentId, source: source);

  // ═══════════════════════════════════════════════════════════════
  // run() — the main entry point
  // ═══════════════════════════════════════════════════════════════

  Future<AgentRuntimeResponse> run(
    AgentRuntimeRequest request, {required ProviderConfig provider, RuntimeEventCallback? onEvent, bool autoApproveSensitive = false}) async {
    _taskScope.clearCancellation(request.agentId);
    final logger = RuntimeLogger();
    void emit(RuntimeEvent event) { onEvent?.call(event); }
    final llmConfig = LlmProviderConfig(baseUrl: provider.baseUrl, apiKey: provider.apiKey, model: provider.model);
    final client = _client;
    final planner = Planner(client: client, config: llmConfig, languageCode: languageCode);
    final executor = Executor(client: client, config: llmConfig);
    final reflector = Reflector(client: client, config: llmConfig);
    final isWorkflowAutoExecute = request.source == RequestSource.workflow && autoApproveSensitive;
    var detectedLang = _languageDetector.detect(userMessage: request.userMessage, fallbackCode: languageCode);
    logger.logStateChange(AgentRuntimeState.analyzing, 'Language bootstrap: ${detectedLang.code} (${detectedLang.script}, conf ${detectedLang.confidence.toStringAsFixed(2)})');
    emit(logger.events.last);
    final verbalizer = ToolVerbalizer(client: client, config: llmConfig);
    verbalizer.resetTurn();
    try {
      try { await _confirmation.maybeRestoreFromLedger(request.agentId); } catch (e) { logger.logError('Ledger auto-resume failed; continuing fresh', e); }
      var pending = _pendingActions[request.agentId];
      var pendingDecision = ConfirmationDecision.none;
      if (pending != null) {
        pendingDecision = ConfirmationChecker.check(request.userMessage);
        logger.logStateChange(AgentRuntimeState.analyzing, 'Pending action detected: ${pending.toolName}, deterministic decision: ${pendingDecision.name}');
        emit(logger.events.last);
        final pendingResponse = await _confirmation.handleDecision(request: request, pending: pending, decision: pendingDecision, executor: executor, verbalizer: verbalizer, detectedLang: detectedLang, logger: logger, emit: emit);
        if (pendingResponse != null) return pendingResponse;
      }
      final wsName = request.agentName.isNotEmpty ? request.agentName : request.agentId;
      toolRouter.agentName = wsName;
      toolRouter.agentId = request.agentId;
      await workspaceLoader.ensureWorkspace(wsName);
      if (detectedLang.isHighConfidence) { await workspaceLoader.maybeFillPreferredLanguage(wsName, detectedLang.label); }
      final workspace = await workspaceLoader.load(wsName);
      final userNotIntroduced = WorkspaceLoader.isUserNameMissing(workspace.soul);
      final sourceMessages = request.recentMessages;
      final latestMessages = sourceMessages.length > 20 ? sourceMessages.sublist(sourceMessages.length - 20) : sourceMessages;
      final recentMsgs = latestMessages.map((m) => {'role': m.role, 'content': m.content}).toList();
      var pendingClarification = _pendingClarifications[request.agentId];
      if (pendingClarification != null && pendingClarification.isExpired) { _pendingClarifications.remove(request.agentId); pendingClarification = null; }
      final activeLedger = request.source == RequestSource.workflow ? null : await ledgerDb.findActive(agentId: request.agentId, source: request.source == RequestSource.workflow ? LedgerSource.workflow : LedgerSource.chat);
      String activeTaskContext = '';
      if (activeLedger != null) { activeTaskContext = activeLedger.describeForUser(); }
      else if (pending != null) { activeTaskContext = 'pending confirmation: ${pending.debugDescriptor}; summary: ${pending.userFacingSummary}'; }
      else if (pendingClarification != null) { activeTaskContext = 'pending clarification for: ${pendingClarification.originalMessage} (questions: ${pendingClarification.questions.join('; ')})'; }
      final mergedUserMessage = pendingClarification != null ? pendingClarification.mergedWith(request.userMessage) : request.userMessage;
      var effectiveUserMessage = activeTaskContext.isNotEmpty ? request.userMessage : mergedUserMessage;
      var toolSelection = ToolCatalog.select(userMessage: request.userMessage, pendingAction: pending, isWorkflowAutoExecute: isWorkflowAutoExecute);
      var analyzerTools = activeTaskContext.isNotEmpty ? toolRouter.buildAllAnalyzerToolDescriptions() : toolRouter.buildAnalyzerToolDescriptions(toolSelection.toolNames);
      var availableTools = activeTaskContext.isNotEmpty ? toolRouter.buildAllToolDescriptions() : toolRouter.buildToolDescriptions(toolSelection.toolNames);
      if (availableTools.isEmpty) { analyzerTools = toolRouter.buildAllAnalyzerToolDescriptions(); availableTools = toolRouter.buildAllToolDescriptions(); }
      logger.logStateChange(AgentRuntimeState.analyzing, 'Tool context: ${activeTaskContext.isNotEmpty ? 'active-task relation probe' : toolSelection.reason} (${availableTools.length} tools, confidence ${toolSelection.confidence.toStringAsFixed(2)})');
      emit(logger.events.last);
      var state = AgentRuntimeState.analyzing;
      logger.logStateChange(state, 'Analyzing user intent');
      emit(logger.events.last);
      await workspaceLoader.updateHeartbeat(wsName, state: state.name, task: effectiveUserMessage);
      var analysis = await planner.analyze(userMessage: effectiveUserMessage, workspace: workspace, availableTools: analyzerTools, logger: logger, recentMessages: recentMsgs, pendingAction: pending, recentToolMemory: _memory.formatForPrompt(request.agentId), isWorkflowAutoExecute: isWorkflowAutoExecute, activeTaskContext: activeTaskContext);
      emit(logger.events.last);
      if (analysis == null) { await _taskScope.finishScopeForRequest(request, LedgerStatus.failed); return _loopRunner.fail('Failed to analyze request.', logger); }
      final analyzeNarrative = (analysis['narrative'] ?? '').toString();
      if (analyzeNarrative.isNotEmpty) { logger.logNarrative('analyze', analyzeNarrative); emit(logger.events.last); }
      final analyzerLangCode = (analysis['detected_language'] ?? '').toString().trim().toLowerCase();
      if (analyzerLangCode.isNotEmpty && analyzerLangCode != detectedLang.code && (!detectedLang.isHighConfidence || detectedLang.script == 'Latin')) {
        final refined = DetectedLanguage.fromAnalyzerCode(analyzerLangCode);
        logger.logStateChange(AgentRuntimeState.analyzing, 'Language refined by analyzer: ${detectedLang.code} → ${refined.code} (${refined.label})');
        emit(logger.events.last);
        detectedLang = refined;
      }
      if (activeTaskContext.isEmpty) {
        final groupsHint = (analysis['tool_groups'] as List?)?.map((e) => e.toString()).toList();
        final narrowed = ToolCatalog.fromGroups(groupsHint);
        final narrowedAvailable = toolRouter.buildToolDescriptions(narrowed.toolNames);
        if (narrowedAvailable.isNotEmpty) {
          toolSelection = narrowed;
          analyzerTools = toolRouter.buildAnalyzerToolDescriptions(narrowed.toolNames);
          availableTools = narrowedAvailable;
          logger.logStateChange(AgentRuntimeState.analyzing, 'Tool surface narrowed from analyzer tool_groups: ${narrowed.reason} (${availableTools.length} tools, confidence ${narrowed.confidence.toStringAsFixed(2)})');
          emit(logger.events.last);
        }
      }
      var relation = (analysis['task_relation'] as String? ?? 'none').trim();
      if (activeTaskContext.isNotEmpty) {
        if (relation == 'none' && pendingDecision != ConfirmationDecision.confirmed && pendingDecision != ConfirmationDecision.rejected && pendingDecision != ConfirmationDecision.previewOnly && analysis['requires_tools'] == true) { relation = 'new_task'; }
        if (relation == 'new_task') {
          final previousGoal = activeLedger?.mainGoal ?? pending?.userFacingSummary ?? pendingClarification?.originalMessage ?? 'the previous task';
          await _taskScope.finishScopeForRequest(request, LedgerStatus.aborted);
          pending = null; pendingDecision = ConfirmationDecision.none; pendingClarification = null;
          effectiveUserMessage = request.userMessage; activeTaskContext = '';
          final groupsHint = (analysis['tool_groups'] as List?)?.map((e) => e.toString()).toList();
          final narrowed = ToolCatalog.fromGroups(groupsHint);
          final narrowedAvailable = toolRouter.buildToolDescriptions(narrowed.toolNames);
          if (narrowedAvailable.isNotEmpty) { toolSelection = narrowed; analyzerTools = toolRouter.buildAnalyzerToolDescriptions(narrowed.toolNames); availableTools = narrowedAvailable; }
          else { analyzerTools = toolRouter.buildAllAnalyzerToolDescriptions(); availableTools = toolRouter.buildAllToolDescriptions(); }
          final headsUp = await verbalizer.taskAborted(previousMainGoal: previousGoal, language: detectedLang);
          logger.logStateChange(AgentRuntimeState.analyzing, 'Active task scope archived (aborted) due to new_task classification. Tools re-narrowed to ${availableTools.length} from analyzer tool_groups. Heads-up surfaced.');
          emit(logger.events.last);
          logger.logNarrative('relation', headsUp);
          emit(logger.events.last);
        } else if (pendingClarification != null && effectiveUserMessage != mergedUserMessage) {
          effectiveUserMessage = mergedUserMessage;
          analysis = await planner.analyze(userMessage: effectiveUserMessage, workspace: workspace, availableTools: analyzerTools, logger: logger, recentMessages: recentMsgs, pendingAction: pending, recentToolMemory: _memory.formatForPrompt(request.agentId), isWorkflowAutoExecute: isWorkflowAutoExecute, activeTaskContext: activeTaskContext);
          emit(logger.events.last);
          if (analysis == null) { await _taskScope.finishScopeForRequest(request, LedgerStatus.failed); return _loopRunner.fail('Failed to analyze clarified request.', logger); }
        }
      }
      if (pending != null && pendingDecision != ConfirmationDecision.confirmed && pendingDecision != ConfirmationDecision.rejected && pendingDecision != ConfirmationDecision.previewOnly && relation != 'new_task') {
        final pendingLang = pending.languageCode;
        final coveredByTier1 = pendingLang == 'id' || pendingLang == 'en' || detectedLang.code == 'id' || detectedLang.code == 'en';
        if (!coveredByTier1 || pendingDecision == ConfirmationDecision.unclear) {
          final classifier = ConfirmationClassifier(client: client, config: llmConfig);
          pendingDecision = await classifier.classify(userMessage: request.userMessage, pendingSummary: pending.userFacingSummary, languageCode: pendingLang);
          logger.logStateChange(AgentRuntimeState.analyzing, 'Pending action LLM decision after relation gate: ${pendingDecision.name}');
          emit(logger.events.last);
          final pendingResponse = await _confirmation.handleDecision(request: request, pending: pending, decision: pendingDecision, executor: executor, verbalizer: verbalizer, detectedLang: detectedLang, logger: logger, emit: emit);
          if (pendingResponse != null) return pendingResponse;
        }
      }
      final missingInfo = (analysis['missing_info'] as List?)?.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList() ?? const <String>[];
      if (missingInfo.isNotEmpty) {
        state = AgentRuntimeState.askingUser;
        final question = missingInfo.length == 1 ? missingInfo.first : missingInfo.map((q) => '- $q').join('\n');
        _pendingClarifications[request.agentId] = PendingClarification(originalMessage: pendingClarification?.originalMessage ?? request.userMessage, questions: missingInfo, createdAt: DateTime.now());
        logger.logFinalResponse(question);
        return AgentRuntimeResponse(finalMessage: question, success: true, state: state, events: logger.events);
      }
      _pendingClarifications.remove(request.agentId);
      ReflectionOutput? reflection;
      TargetResolutionGraph? targetGraph;
      final analyzerSaysToolsForReflect = analysis['requires_tools'] == true;
      final reflectSnapshot = analyzerSaysToolsForReflect ? await _buildSnapshot() : EcosystemSnapshot(agents: const [], workflows: const [], providers: const [], modules: const [], builtAt: DateTime.fromMillisecondsSinceEpoch(0));
      final canSkipReflect = analyzerSaysToolsForReflect && !isWorkflowAutoExecute && toolSelection.isHighConfidence && toolSelection.groups.length == 1 && missingInfo.isEmpty && analysis['bulk_selector'] != true && !_isDestructiveIntent(analysis) && !reflectSnapshot.isRelevantForReflection;
      final shouldReflect = analyzerSaysToolsForReflect && !isWorkflowAutoExecute && !canSkipReflect;
      if (shouldReflect) {
        state = AgentRuntimeState.analyzing;
        logger.logStateChange(state, 'Reflecting on impact and slot needs');
        emit(logger.events.last);
        final snapshot = reflectSnapshot;
        reflection = await reflector.reflect(userMessage: effectiveUserMessage, analysis: analysis, snapshot: snapshot, availableTools: _toolDefinitionsFor(toolSelection.toolNames), language: detectedLang, logger: logger, recentMessages: recentMsgs);
        final targetResolution = TargetResolver.resolveReflection(reflection: reflection, snapshot: snapshot, request: request, language: detectedLang);
        reflection = targetResolution.reflection;
        targetGraph = targetResolution.graph;
        logger.logLlmDecision('reflect', reflection.toJson());
        emit(logger.events.last);
        if (targetResolution.graph.isNotEmpty) { logger.logLlmDecision('target_resolution', targetResolution.graph.toJson()); emit(logger.events.last); }
        if (reflection.narrative.isNotEmpty) { logger.logNarrative('reflect', reflection.narrative); emit(logger.events.last); }
        if (reflection.strategy == ReflectionStrategy.clarify && reflection.clarifyQuestions.isNotEmpty) {
          final question = reflection.clarifyQuestions.first;
          _pendingClarifications[request.agentId] = PendingClarification(originalMessage: request.userMessage, questions: reflection.clarifyQuestions, createdAt: DateTime.now());
          logger.logFinalResponse(question);
          return AgentRuntimeResponse(finalMessage: question, success: true, state: AgentRuntimeState.askingUser, events: logger.events);
        }
        if (reflection.strategy == ReflectionStrategy.block) {
          final reason = reflection.blockReason.isNotEmpty ? reflection.blockReason : await verbalizer.abort(reason: 'destructive request blocked', language: detectedLang);
          logger.logFinalResponse(reason);
          return AgentRuntimeResponse(finalMessage: reason, success: true, state: AgentRuntimeState.done, events: logger.events);
        }
      }
      final analyzerSaysTools = analysis['requires_tools'] == true;
      final requiresTools = analyzerSaysTools || isWorkflowAutoExecute;
      if (!requiresTools) {
        state = AgentRuntimeState.done;
        logger.logStateChange(state, 'Direct response (no tools needed)');
        emit(logger.events.last);
        final identityBlock = 'Identity context (from SOUL.md — user-editable):\n${workspace.soul}';
        final recentToolMemory = _memory.formatForPrompt(request.agentId);
        final toolMemoryBlock = recentToolMemory.isEmpty ? '' : '\n\nRECENT TOOL RESULTS (source of truth):\n$recentToolMemory\n\nUse successful retrieval results (read/list/search/status) to answer follow-up questions. Never treat failed tool results or prior progress/narrative messages as evidence. If the relevant result failed or is missing, say you cannot verify it yet and ask for the exact target or next step.';
        final worldModelBlock = '\n\nMEOW AGENT WORLD MODEL:\nYou are an Android-native AI agent, NOT a generic LLM or terminal-based assistant. Your workspace is a sandbox at Documents/MeowAgent/, rooted at your agent folder.\n${PromptConstants.systemMarkdownMap}';
        const capabilityDirectGuard = '\n\nCAPABILITY ANSWER GUARD:\nIf the user asks what you can do, what tools you have, or what capabilities are available, answer ONLY from a fresh system.tools.list retrieval result in RECENT TOOL RESULTS. If that result is not present, say you need to check the current tool list first. Never list generic assistant abilities or actions not backed by registered tools.';
        final baseSystem = '${_directResponseRulesFor(languageLabel: detectedLang.label, isWorkflowAutoExecute: isWorkflowAutoExecute, userNotIntroduced: userNotIntroduced)}\n\n$identityBlock$worldModelBlock$toolMemoryBlock$capabilityDirectGuard';
        final systemContent = pending != null ? '$baseSystem\n\nPENDING ACTION (user was asked to confirm):\nTool: ${pending.toolName}\nArgs: ${pending.toolArgs}\nSummary: ${pending.userFacingSummary}\nIf user asks about the result or preview, show them what the result would be.' : baseSystem;
        final directResponse = await client.chat(config: llmConfig, phase: 'direct', messages: [{'role': 'system', 'content': systemContent}, ...recentMsgs, {'role': 'user', 'content': request.userMessage}]);
        if (pending != null) { _pendingActions.remove(request.agentId); }
        logger.logFinalResponse(directResponse);
        return AgentRuntimeResponse(finalMessage: directResponse, success: true, state: AgentRuntimeState.done, events: logger.events);
      }
      final seeds = analysis['subgoal_seeds']; final hasMultiSeed = seeds is List && seeds.length > 1;
      final analyzerBulk = analysis['bulk_selector'] == true;
      final reflectorMultiSubgoal = reflection != null && reflection.goalTree.subgoals.length > 1;
      final reflectorMultiTarget = reflection != null && reflection.targets.length > 1;
      final hasMultiTarget = hasMultiSeed || analyzerBulk || reflectorMultiSubgoal || reflectorMultiTarget;
      final canSkipPlanner = pending == null && !isWorkflowAutoExecute && toolSelection.isHighConfidence && toolSelection.groups.length == 1 && missingInfo.isEmpty && !hasMultiTarget;
      Map<String, dynamic>? plan;
      if (canSkipPlanner) {
        state = AgentRuntimeState.planning;
        logger.logStateChange(state, 'Plan synthesized locally (group: ${toolSelection.groups.first})');
        emit(logger.events.last);
        plan = {'steps': [{'id': 1, 'description': analysis['goal'] as String? ?? 'Execute requested action', 'tool': null}]};
      } else {
        state = AgentRuntimeState.planning;
        logger.logStateChange(state, 'Creating execution plan');
        emit(logger.events.last);
        await workspaceLoader.updateHeartbeat(request.agentName.isNotEmpty ? request.agentName : request.agentId, state: state.name, task: request.userMessage);
        plan = await planner.plan(analysis: analysis, availableTools: availableTools, logger: logger); emit(logger.events.last);
        if (plan == null) {
          logger.logError('Planner returned null on first attempt; retrying with broadened tools.');
          final broadenedAnalyzer = toolRouter.buildAllAnalyzerToolDescriptions();
          plan = await planner.plan(analysis: analysis, availableTools: broadenedAnalyzer.isNotEmpty ? broadenedAnalyzer : toolRouter.buildAllToolDescriptions(), logger: logger);
          emit(logger.events.last);
        }
        if (plan == null) { await _taskScope.finishScopeForRequest(request, LedgerStatus.failed); return _loopRunner.fail('Failed to create execution plan.', logger); }
        final planNarrative = (plan['narrative'] ?? '').toString();
        if (planNarrative.isNotEmpty) { logger.logNarrative('plan', planNarrative); emit(logger.events.last); }
      }
      final goalTree = reflection != null && reflection.goalTree.isNotEmpty ? reflection.goalTree : _buildGoalTree(plan: plan, analysis: analysis, userMessage: effectiveUserMessage);
      if (targetGraph != null && targetGraph.isNotEmpty) { plan['runtime_target_graph'] = targetGraph.toJson(); }
      logger.logLlmDecision('plan.goal_tree', goalTree.toJson());
      final loopRequest = effectiveUserMessage == request.userMessage ? request : AgentRuntimeRequest(agentId: request.agentId, agentName: request.agentName, userMessage: effectiveUserMessage, recentMessages: request.recentMessages, metadata: request.metadata, source: request.source);
      final recovery = RecoveryCoordinator();
      final validator = PostExecuteValidator(snapshotBuilder: () async => _buildSnapshot());
      final capturedAnalysis = Map<String, dynamic>.from(analysis);
      Future<({Map<String, dynamic> plan, GoalTree goalTree})?> rethink() async {
        try {
          final freshSnapshot = await _buildSnapshot();
          final freshAnalysis = Map<String, dynamic>.from(capturedAnalysis);
          final priorContext = recovery.toReflectionContextList();
          if (priorContext.isNotEmpty) { freshAnalysis['prior_attempts'] = priorContext; }
          final broadenedTools = toolRouter.buildAllToolDescriptions();
          final broadenedAnalyzerTools = toolRouter.buildAllAnalyzerToolDescriptions();
          freshAnalysis['available_tools_broadened'] = true;
          final reReflection = await reflector.reflect(userMessage: effectiveUserMessage, analysis: freshAnalysis, snapshot: freshSnapshot, availableTools: _toolDefinitionsFor(toolRouter.registeredTools.toSet()), language: detectedLang, logger: logger, recentMessages: recentMsgs);
          final newPlan = await planner.plan(analysis: freshAnalysis, availableTools: broadenedAnalyzerTools.isNotEmpty ? broadenedAnalyzerTools : broadenedTools, logger: logger);
          if (newPlan == null) return null;
          final newTree = reReflection.goalTree.isNotEmpty ? reReflection.goalTree : _buildGoalTree(plan: newPlan, analysis: freshAnalysis, userMessage: effectiveUserMessage);
          return (plan: newPlan, goalTree: newTree);
        } catch (e) { logger.logError('Recovery rethink failed', e); return null; }
      }
      return _loopRunner.run(request: loopRequest, plan: plan, goalTree: goalTree, executor: executor, verbalizer: verbalizer, detectedLang: detectedLang, availableTools: availableTools, logger: logger, emit: emit, memorySnapshot: _memory.formatForPrompt(request.agentId), recovery: recovery, postExecuteValidator: validator, rethink: rethink, autoApproveSensitive: autoApproveSensitive, isWorkflowAutoExecute: isWorkflowAutoExecute);
    } catch (e) { logger.logError('Runtime exception', e); await _taskScope.finishScopeForRequest(request, LedgerStatus.failed); return _loopRunner.fail('Runtime error: $e', logger); }
  }

  // ═══════════════════════════════════════════════════════════════
  // executeConfirmed
  // ═══════════════════════════════════════════════════════════════

  Future<AgentRuntimeResponse> executeConfirmed(AgentRuntimeRequest request, {required ProviderConfig provider, required String toolName, required Map<String, dynamic> toolArgs, RuntimeEventCallback? onEvent}) {
    return _confirmation.executeConfirmed(request, provider: provider, toolName: toolName, toolArgs: toolArgs, onEvent: onEvent);
  }

  // ═══════════════════════════════════════════════════════════════
  // _executePendingTool
  // ═══════════════════════════════════════════════════════════════

  Future<AgentRuntimeResponse> _executePendingTool({
    required AgentRuntimeRequest request, required PendingAction pending, required Executor executor, required ToolVerbalizer verbalizer, required DetectedLanguage detectedLang, required RuntimeLogger logger, required void Function(RuntimeEvent) emit}) async {
    try {
      var state = AgentRuntimeState.executingTool;
      logger.logStateChange(state, 'Executing confirmed tool: ${pending.toolName}'); emit(logger.events.last);
      final toolRequest = ToolCallRequest(name: pending.toolName, args: pending.toolArgs, risk: 'confirmed', requiresConfirmation: false);
      logger.logToolCall(toolRequest);
      final result = await toolRouter.forceExecute(toolRequest);
      logger.logToolResult(result); emit(logger.events.last);
      _memory.record(agentId: request.agentId, toolName: pending.toolName, args: pending.toolArgs, data: result.data, success: result.success, error: result.error);
      final permissionFinal = _loopRunner.permissionDeniedResponseFor(result);
      if (permissionFinal != null) {
        await _taskScope.finishScopeForRequest(request, LedgerStatus.failed); logger.logFinalResponse(permissionFinal);
        await workspaceLoader.updateHeartbeat(request.agentName.isNotEmpty ? request.agentName : request.agentId, state: 'failed', task: request.userMessage, lastTool: pending.toolName, lastResult: 'permission_denied', lastError: result.error);
        return AgentRuntimeResponse(finalMessage: permissionFinal, success: false, state: AgentRuntimeState.failed, events: logger.events);
      }
      if (result.success) {
        final resume = pending.resumeContext;
        if (resume != null) {
          final treeJson = resume['goal_tree'] as Map<String, dynamic>?;
          final goalTree = treeJson != null ? GoalTree.fromJson(treeJson) : GoalTree.singleSubgoal(mainGoal: pending.toolName, subgoalLabel: pending.toolName);
          final active = goalTree.nextActionable;
          if (active != null) { active.status = SubgoalStatus.done; active.resultRef = 'confirmed:${pending.toolName}:${result.success}'; }
          _memory.record(agentId: request.agentId, toolName: pending.toolName, args: pending.toolArgs, data: result.data, success: result.success, error: result.error);
          final plan = (resume['plan'] as Map?)?.cast<String, dynamic>() ?? {'steps': []};
          final previousResults = (resume['previous_results'] as List?)?.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList() ?? <Map<String, dynamic>>[];
          previousResults.add({'step': resume['current_step'] ?? 1, 'tool': pending.toolName, 'result': result.data, 'confirmed': true});
          final availableTools = (resume['available_tools'] as List?)?.map((e) => e.toString()).toList() ?? const <String>[];
          final memorySnapshot = (resume['memory_snapshot'] as String?) ?? '';
          final autoApproveSensitive = resume['auto_approve_sensitive'] as bool? ?? false;
          final isWorkflowAutoExecute = resume['is_workflow_auto_execute'] as bool? ?? false;
          final currentStep = (resume['current_step'] as int? ?? 1) + 1;
          final userMessage = (resume['user_message'] as String?) ?? request.userMessage;
          final resumedRequest = AgentRuntimeRequest(agentId: request.agentId, agentName: request.agentName, userMessage: userMessage, recentMessages: request.recentMessages, source: request.source);
          if (goalTree.isComplete) {
            final verificationBlocker = await _completionVerifier.blockIfUnverified(request: resumedRequest, plan: plan, goalTree: goalTree, previousResults: previousResults, currentStep: currentStep, availableTools: availableTools, memorySnapshot: memorySnapshot, detectedLang: detectedLang, autoApproveSensitive: autoApproveSensitive, isWorkflowAutoExecute: isWorkflowAutoExecute, logger: logger, parkTask: (questions) => _taskScope.parkForUserInput(request: resumedRequest, plan: plan, goalTree: goalTree, previousResults: previousResults, currentStep: currentStep, availableTools: availableTools, memorySnapshot: memorySnapshot, detectedLangCode: detectedLang.code, autoApproveSensitive: autoApproveSensitive, isWorkflowAutoExecute: isWorkflowAutoExecute, questions: questions), lastToolName: pending.toolName);
            if (verificationBlocker != null) return verificationBlocker;
            final successMsg = _loopRunner.shouldAnswerFromToolResult(toolName: pending.toolName, userMessage: userMessage, result: result) ? await verbalizer.answerFromToolResult(userMessage: userMessage, tool: toolRequest, result: result, language: detectedLang) : await _loopRunner.finalForCompletedTree(goalTree: goalTree, fallbackTool: toolRequest, fallbackResult: result, verbalizer: verbalizer, language: detectedLang, targetGraph: (plan['runtime_target_graph'] as Map?)?.cast<String, dynamic>());
            logger.logFinalResponse(successMsg);
            await workspaceLoader.updateHeartbeat(request.agentName.isNotEmpty ? request.agentName : request.agentId, state: 'done', task: pending.toolName, lastTool: pending.toolName, lastResult: 'success');
            await _taskScope.archiveLedgerForRequest(request, LedgerStatus.completed);
            return AgentRuntimeResponse(finalMessage: successMsg, success: true, state: AgentRuntimeState.done, events: logger.events, actions: result.actions);
          }
          logger.logStateChange(AgentRuntimeState.selectingTool, 'Resuming execute loop after confirmation (subgoals remaining: ${goalTree.subgoals.where((s) => !s.isTerminal).length})');
          emit(logger.events.last);
          return _loopRunner.run(request: resumedRequest, plan: plan, goalTree: goalTree, executor: executor, verbalizer: verbalizer, detectedLang: detectedLang, availableTools: availableTools, logger: logger, emit: emit, memorySnapshot: memorySnapshot, autoApproveSensitive: autoApproveSensitive, isWorkflowAutoExecute: isWorkflowAutoExecute, initialPreviousResults: previousResults, initialStep: currentStep);
        }
        final successMsg = _loopRunner.shouldAnswerFromToolResult(toolName: pending.toolName, userMessage: request.userMessage, result: result) ? await verbalizer.answerFromToolResult(userMessage: request.userMessage, tool: toolRequest, result: result, language: detectedLang) : await verbalizer.success(tool: toolRequest, result: result, language: detectedLang);
        logger.logFinalResponse(successMsg);
        await workspaceLoader.updateHeartbeat(request.agentName.isNotEmpty ? request.agentName : request.agentId, state: 'done', task: request.userMessage, lastTool: pending.toolName, lastResult: 'success');
        return AgentRuntimeResponse(finalMessage: successMsg, success: true, state: AgentRuntimeState.done, events: logger.events, actions: result.actions);
      }
      await workspaceLoader.updateHeartbeat(request.agentName.isNotEmpty ? request.agentName : request.agentId, state: state.name, task: request.userMessage, lastTool: pending.toolName, lastResult: 'failed', lastError: result.error);
      state = AgentRuntimeState.reviewing;
      logger.logStateChange(state, 'Reviewing tool result'); emit(logger.events.last);
      final review = await executor.review(result: result, plan: {'steps': [{'id': 1, 'description': 'Execute confirmed tool', 'tool': pending.toolName}]}, currentStep: 1, userMessage: request.userMessage, logger: logger, language: detectedLang.label);
      emit(logger.events.last);
      if (review != null) { final reviewNarrative = (review['narrative'] ?? '').toString(); if (reviewNarrative.isNotEmpty) { logger.logNarrative('review', reviewNarrative); emit(logger.events.last); } }
      final reviewMessage = review?['final_response'] as String?;
      if (reviewMessage != null && reviewMessage.isNotEmpty) { await _taskScope.finishScopeForRequest(request, LedgerStatus.failed); logger.logFinalResponse(reviewMessage); return AgentRuntimeResponse(finalMessage: reviewMessage, success: false, state: AgentRuntimeState.done, events: logger.events); }
      final fallbackMsg = await verbalizer.abort(reason: result.error ?? 'tool failed', language: detectedLang);
      await _taskScope.finishScopeForRequest(request, LedgerStatus.failed);
      logger.logFinalResponse(fallbackMsg);
      return AgentRuntimeResponse(finalMessage: fallbackMsg, success: false, state: AgentRuntimeState.done, events: logger.events);
    } catch (e) { logger.logError('Runtime exception', e); await _taskScope.finishScopeForRequest(request, LedgerStatus.failed); return _loopRunner.fail('Runtime error: $e', logger); }
  }

  // ═══════════════════════════════════════════════════════════════
  // Goal tree / snapshot / tool defs
  // ═══════════════════════════════════════════════════════════════

  GoalTree _buildGoalTree({required Map<String, dynamic> plan, required Map<String, dynamic> analysis, required String userMessage}) {
    final mainGoal = (plan['main_goal'] as String?) ?? (analysis['goal'] as String?) ?? userMessage;
    final subgoalsJson = plan['subgoals'];
    if (subgoalsJson is List && subgoalsJson.isNotEmpty) {
      try { return GoalTree.fromJson({'main_goal': mainGoal, 'completion_criteria': plan['completion_criteria'] ?? const [], 'subgoals': subgoalsJson}); } catch (_) {}
    }
    final seeds = analysis['subgoal_seeds'];
    if (seeds is List && seeds.length > 1) { return GoalTree(mainGoal: mainGoal, subgoals: [for (var i = 0; i < seeds.length; i++) Subgoal(id: 'sg${i + 1}', label: seeds[i].toString())]); }
    return GoalTree.singleSubgoal(mainGoal: mainGoal, subgoalLabel: mainGoal);
  }

  Future<EcosystemSnapshot> _buildSnapshot() async {
    final override = _snapshotOverride; if (override != null) return override();
    final builder = snapshotBuilder; final loader = agentLoader;
    if (builder == null || loader == null) { return EcosystemSnapshot(agents: const [], workflows: const [], providers: const [], modules: const [], builtAt: DateTime.now()); }
    try { return await builder.build(agents: loader()); }
    catch (_) { return EcosystemSnapshot(agents: const [], workflows: const [], providers: const [], modules: const [], builtAt: DateTime.now()); }
  }

  List<ToolDefinition> _toolDefinitionsFor(Set<String> names) {
    final out = <ToolDefinition>[];
    for (final n in names) { final def = toolRouter.getDefinition(n); if (def != null) out.add(def); }
    return out;
  }

  // ═══════════════════════════════════════════════════════════════
  // _isDestructiveIntent — stays on engine (used in run(), not loop)
  // ═══════════════════════════════════════════════════════════════

  bool _isDestructiveIntent(Map<String, dynamic> analysis) {
    final risk = (analysis['risk'] ?? '').toString().toLowerCase();
    if (risk == 'sensitive' || risk == 'dangerous') return true;
    final intent = (analysis['intent'] ?? '').toString().toLowerCase();
    const destructiveOps = {'delete', 'remove', 'update', 'rename', 'toggle', 'overwrite', 'move'};
    for (final op in destructiveOps) { if (intent.contains(op)) return true; }
    return false;
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
