import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/modules/data/module_repository.dart';
import '../../features/agents/data/agent_repository.dart';
import '../../features/settings/data/app_language_provider.dart';
import '../../features/providers/data/provider_config.dart';
import '../../features/providers/data/provider_repository.dart';
import '../../features/settings/data/llm_provider_config.dart';
import '../llm/openai_compatible_client.dart';
import 'context_builder.dart';
import 'executor.dart';
import 'pending_action.dart';
import 'pending_clarification.dart';
import 'planner.dart';
import 'prompt_constants.dart';
import 'runtime_logger.dart';
import 'runtime_memory.dart';
import 'runtime_models.dart';
import 'tool_catalog.dart';
import 'tool_permission_policy.dart';
import 'tool_router.dart';
import 'workspace_loader.dart';

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
  });

  final WorkspaceLoader workspaceLoader;
  final ToolRouter toolRouter;
  final ContextBuilder contextBuilder;
  final String languageCode;

  /// Shared LLM client. Reused across all turns of this engine instance so
  /// the underlying Dio's connection pool can keep keep-alive sockets warm.
  final OpenAiCompatibleClient _client = OpenAiCompatibleClient();

  static const int maxSteps = 5;

  /// System-level behavior rules for direct (no-tool) responses.
  /// Always enforced regardless of SOUL.md content.
  String _directResponseRulesFor({bool isWorkflowAutoExecute = false}) {
    final language = languageLabelFromCode(languageCode);
    return PromptConstants.systemRules(
      language,
      isWorkflowAutoExecute: isWorkflowAutoExecute,
    );
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

    // Workflow auto-execute mode: scheduled run + sensitive actions pre-approved.
    // Used by prompt builders to switch language/rules and by the runtime to
    // bypass the confirmation gate.
    final isWorkflowAutoExecute =
        request.source == RequestSource.workflow && autoApproveSensitive;

    try {
      // Check if there's a pending action for this agent.
      final pending = _pendingActions[request.agentId];
      if (pending != null) {
        // Deterministic pre-check: does the user confirm/reject/preview?
        final decision = ConfirmationChecker.check(request.userMessage);
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
            return AgentRuntimeResponse(
              finalMessage: '❌ Aksi dibatalkan.',
              success: true,
              state: AgentRuntimeState.done,
              events: logger.events,
            );

          case ConfirmationDecision.previewOnly:
            // Don't execute, just show preview.
            _pendingActions.remove(request.agentId);
            logger.logStateChange(
              AgentRuntimeState.done,
              'User requested preview only',
            );
            emit(logger.events.last);
            return AgentRuntimeResponse(
              finalMessage: pending.previewText,
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
      final workspace = await workspaceLoader.load(wsName);
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
        final baseSystem =
            '${_directResponseRulesFor(isWorkflowAutoExecute: isWorkflowAutoExecute)}\n\n$identityBlock';
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
      final canSkipPlanner =
          pending == null &&
          !isWorkflowAutoExecute &&
          toolSelection.isHighConfidence &&
          toolSelection.groups.length == 1 &&
          missingInfo.isEmpty;

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
      }

      // 4. Execute loop.
      return _executeLoop(
        request: request,
        plan: plan,
        executor: executor,
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

    // Clear pending action.
    _pendingActions.remove(request.agentId);

    final llmConfig = LlmProviderConfig(
      baseUrl: provider.baseUrl,
      apiKey: provider.apiKey,
      model: provider.model,
    );
    final client = _client;
    final executor = Executor(client: client, config: llmConfig);

    final pending = PendingAction(
      toolName: toolName,
      toolArgs: toolArgs,
      userFacingSummary: 'Confirmed by user',
    );

    return _executePendingTool(
      request: request,
      pending: pending,
      executor: executor,
      logger: logger,
      emit: emit,
    );
  }

  /// Execute a pending tool (after confirmation).
  Future<AgentRuntimeResponse> _executePendingTool({
    required AgentRuntimeRequest request,
    required PendingAction pending,
    required Executor executor,
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

      final localFinal = _localFinalResponseFor(pending.toolName, result);
      if (localFinal != null) {
        logger.logFinalResponse(localFinal);
        await workspaceLoader.updateHeartbeat(
          request.agentName.isNotEmpty ? request.agentName : request.agentId,
          state: 'done',
          task: request.userMessage,
          lastTool: pending.toolName,
          lastResult: 'success',
        );
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
        lastTool: pending.toolName,
        lastResult: result.success ? 'success' : 'failed',
        lastError: result.error,
      );

      // Review result.
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
        language: languageLabelFromCode(languageCode),
      );
      emit(logger.events.last);

      if (review == null) {
        return _fail('Review phase failed.', logger);
      }

      final reviewStatus = review['status'] as String? ?? '';
      if (reviewStatus == 'done') {
        final finalResponse =
            review['final_response'] as String? ?? 'Task completed.';
        logger.logFinalResponse(finalResponse);
        return AgentRuntimeResponse(
          finalMessage: finalResponse,
          success: true,
          state: AgentRuntimeState.done,
          events: logger.events,
          actions: result.actions,
        );
      }

      return AgentRuntimeResponse(
        finalMessage: result.success
            ? 'Tool ${pending.toolName} executed successfully.'
            : 'Tool ${pending.toolName} failed: ${result.error}',
        success: result.success,
        state: AgentRuntimeState.done,
        events: logger.events,
        actions: result.success ? result.actions : const [],
      );
    } catch (e) {
      logger.logError('Runtime exception', e);
      return _fail('Runtime error: $e', logger);
    }
  }

  Future<AgentRuntimeResponse> _executeLoop({
    required AgentRuntimeRequest request,
    required Map<String, dynamic> plan,
    required Executor executor,
    required List<String> availableTools,
    required RuntimeLogger logger,
    required void Function(RuntimeEvent) emit,
    required String memorySnapshot,
    bool autoApproveSensitive = false,
    bool isWorkflowAutoExecute = false,
  }) async {
    final previousResults = <Map<String, dynamic>>[];
    var currentStep = 1;
    var retryCount = 0;

    for (var i = 0; i < maxSteps; i++) {
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
      );
      emit(logger.events.last);

      if (selection == null) {
        return _fail('Tool selection failed.', logger);
      }

      final status = selection['status'] as String? ?? '';

      if (status == 'done') {
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

        // Check confirmation requirement from REGISTRY.
        // Skip the gate when the caller (e.g., a sensitive workflow) opted in.
        if (definition.requiresConfirmation && !autoApproveSensitive) {
          state = AgentRuntimeState.waitingConfirmation;
          logger.logStateChange(
            state,
            'Tool requires confirmation: ${toolRequest.name}',
          );
          emit(logger.events.last);

          // Build a humanized confirmation summary that hides the tool name.
          final summary = _humanizeConfirmation(toolRequest);

          // Store as pending action.
          final pending = PendingAction(
            toolName: toolRequest.name,
            toolArgs: toolRequest.args,
            userFacingSummary: summary,
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

        final localFinal = _isLastPlannedStep(plan, currentStep)
            ? _localFinalResponseFor(toolRequest.name, result)
            : null;
        if (localFinal != null) {
          logger.logFinalResponse(localFinal);
          await workspaceLoader.updateHeartbeat(
            request.agentName.isNotEmpty ? request.agentName : request.agentId,
            state: 'done',
            task: request.userMessage,
            lastTool: toolRequest.name,
            lastResult: 'success',
          );
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
          language: languageLabelFromCode(languageCode),
        );
        emit(logger.events.last);

        if (review == null) {
          return _fail('Review phase failed.', logger);
        }

        final reviewStatus = review['status'] as String? ?? '';

        if (reviewStatus == 'done') {
          final finalResponse =
              review['final_response'] as String? ?? 'Task completed.';
          logger.logFinalResponse(finalResponse);
          await workspaceLoader.updateHeartbeat(
            request.agentName.isNotEmpty ? request.agentName : request.agentId,
            state: 'done',
            task: request.userMessage,
            lastTool: toolRequest.name,
            lastResult: 'success',
          );
          return AgentRuntimeResponse(
            finalMessage: finalResponse,
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
      'Maximum runtime steps ($maxSteps) reached without completion.',
      logger,
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

  String? _localFinalResponseFor(String toolName, ToolExecutionResult result) {
    if (!result.success) return null;
    final isId = languageCode == 'id';

    switch (toolName) {
      case 'notes.create':
        return isId
            ? 'Sudah saya buatkan catatannya.'
            : 'Done, I created the note.';
      case 'calendar.create':
        return isId
            ? 'Sudah saya jadwalkan.'
            : 'Done, I added it to the calendar.';
      case 'clipboard.write':
        return isId
            ? 'Sudah saya salin ke clipboard.'
            : 'Done, I copied it to the clipboard.';
      case 'app.open':
        return isId ? 'Saya buka sekarang.' : 'Opening it now.';
      case 'intent.open_url':
        return isId ? 'Saya buka URL-nya sekarang.' : 'Opening the URL now.';
      case 'settings.open':
        return isId
            ? 'Saya buka pengaturannya sekarang.'
            : 'Opening settings now.';
      case 'device.dnd.set':
        return isId
            ? 'Pengaturan Do Not Disturb sudah diperbarui.'
            : 'Do Not Disturb has been updated.';
      case 'device.bluetooth.set':
        return isId
            ? 'Pengaturan Bluetooth sudah diperbarui.'
            : 'Bluetooth has been updated.';
      case 'device.wifi.reconnect':
        return isId
            ? 'Saya sudah mencoba menghubungkan ulang WiFi.'
            : 'I tried reconnecting WiFi.';
      case 'system.profile.update':
        return isId
            ? 'Sudah saya simpan di profil agent ini.'
            : 'Done, I saved it to this agent profile.';
      case 'system.memory.append':
        return isId ? 'Sudah saya ingat.' : 'Done, I will remember that.';
      case 'system.agents.create':
        return isId ? 'Agent baru sudah dibuat.' : 'Done, I created the agent.';
      case 'system.agents.delete':
        return isId
            ? 'Agent tersebut sudah dihapus.'
            : 'Done, I deleted that agent.';
      default:
        return null;
    }
  }

  /// Translate a raw tool request into a human-friendly Indonesian summary
  /// that does not expose internal tool names.
  String _humanizeConfirmation(ToolCallRequest req) {
    String? truncate(String? s, [int n = 80]) {
      if (s == null || s.isEmpty) return null;
      return s.length > n ? '${s.substring(0, n)}…' : s;
    }

    switch (req.name) {
      case 'clipboard.write':
        final text = truncate(req.args['text'] as String?);
        return text != null
            ? 'Saya akan menulis ke clipboard:\n\n"$text"\n\nLanjutkan?'
            : 'Saya akan menulis sesuatu ke clipboard. Lanjutkan?';
      case 'app.open':
        final pkg = req.args['package'] as String? ?? '';
        final hint = pkg.isNotEmpty ? ' ($pkg)' : '';
        return 'Saya akan membuka sebuah aplikasi$hint. Lanjutkan?';
      case 'intent.open_url':
        final url = truncate(req.args['url'] as String?, 60);
        return url != null
            ? 'Saya akan membuka URL:\n\n$url\n\nLanjutkan?'
            : 'Saya akan membuka sebuah URL. Lanjutkan?';
      case 'settings.open':
        return 'Saya akan membuka pengaturan sistem. Lanjutkan?';
      case 'device.dnd.set':
        final enabled = req.args['enabled'] as bool? ?? false;
        final mode = req.args['mode'] as String?;
        if (enabled) {
          final modeLabel = mode ?? 'priority_only';
          return 'Saya akan mengaktifkan Do Not Disturb (mode: $modeLabel). Lanjutkan?';
        }
        return 'Saya akan mematikan Do Not Disturb. Lanjutkan?';
      case 'device.wifi.reconnect':
        return 'Saya akan menghubungkan ulang ke jaringan WiFi terakhir. Lanjutkan?';
      case 'device.bluetooth.set':
        final btOn = req.args['enabled'] as bool? ?? false;
        return btOn
            ? 'Saya akan menyalakan Bluetooth. Lanjutkan?'
            : 'Saya akan mematikan Bluetooth. Lanjutkan?';
      case 'system.agents.delete':
        final name = req.args['name'] as String?;
        final id = req.args['id'] as String? ?? req.args['agentId'] as String?;
        final target = name != null && name.isNotEmpty
            ? name
            : (id != null && id.isNotEmpty ? id : 'agent tersebut');
        return 'Saya akan menghapus $target beserta workspace-nya. Tindakan ini tidak bisa dibatalkan. Lanjutkan?';
      default:
        return 'Saya ingin menjalankan sebuah aksi sensitif. Lanjutkan?';
    }
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
  );
});
