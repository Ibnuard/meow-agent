import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/settings/data/app_language_provider.dart';
import '../../features/providers/data/provider_config.dart';
import '../../features/settings/data/llm_provider_config.dart';
import '../llm/openai_compatible_client.dart';
import 'context_builder.dart';
import 'executor.dart';
import 'pending_action.dart';
import 'planner.dart';
import 'runtime_logger.dart';
import 'runtime_models.dart';
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

  static const int maxSteps = 5;

  /// System-level behavior rules for direct (no-tool) responses.
  /// Always enforced regardless of SOUL.md content.
  String get _directResponseRules {
    final language = languageLabelFromCode(languageCode);
    return '''SYSTEM RULES (always enforced):
- Default response language: $language, unless user explicitly switches.
- Be concise and practical. Avoid exaggerated or futuristic language.
- Ask the user before sensitive or destructive actions.
- Respect enabled permissions and modules. Do not assume capabilities.
- If a tool fails or requires permission, stop and inform the user clearly.
- If the user's identity (Name) in SOUL.md is still a placeholder, politely ask once and offer to fill it in. Do not ask repeatedly.
- When user provides identity info, update only the relevant SOUL.md field — never overwrite unrelated sections.''';
  }

  /// Pending actions per agent (agentId → PendingAction).
  final Map<String, PendingAction> _pendingActions = {};

  /// Get pending action for an agent.
  PendingAction? getPendingAction(String agentId) => _pendingActions[agentId];

  /// Clear pending action for an agent.
  void clearPendingAction(String agentId) => _pendingActions.remove(agentId);

  /// Run the full agentic loop for a request.
  Future<AgentRuntimeResponse> run(
    AgentRuntimeRequest request, {
    required ProviderConfig provider,
    RuntimeEventCallback? onEvent,
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
    final client = OpenAiCompatibleClient();
    final planner = Planner(
      client: client,
      config: llmConfig,
      languageCode: languageCode,
    );
    final executor = Executor(client: client, config: llmConfig);

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
            logger.logStateChange(AgentRuntimeState.done, 'User rejected pending action');
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
            logger.logStateChange(AgentRuntimeState.done, 'User requested preview only');
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
      await workspaceLoader.ensureWorkspace(request.agentId);
      final workspace = await workspaceLoader.load(request.agentId);
      // Tool list comes from the ToolRouter registry (system source of truth),
      // NOT from user-editable SKILLS.md template.
      final availableTools = toolRouter.buildAllToolDescriptions();

      // Build recent messages for context (last 20).
      final recentMsgs = request.recentMessages
          .take(20)
          .map((m) => {'role': m.role, 'content': m.content})
          .toList();

      // 2. Analyze.
      var state = AgentRuntimeState.analyzing;
      logger.logStateChange(state, 'Analyzing user intent');
      emit(logger.events.last);
      await workspaceLoader.updateHeartbeat(
        request.agentId,
        state: state.name,
        task: request.userMessage,
      );

      final analysis = await planner.analyze(
        userMessage: request.userMessage,
        workspace: workspace,
        availableTools: availableTools,
        logger: logger,
        recentMessages: recentMsgs,
        pendingAction: pending,
      );
      emit(logger.events.last);

      if (analysis == null) {
        return _fail('Failed to analyze request.', logger);
      }

      // If no tools required, respond directly with full context.
      final requiresTools = analysis['requires_tools'] == true;
      if (!requiresTools) {
        state = AgentRuntimeState.done;
        logger.logStateChange(state, 'Direct response (no tools needed)');
        emit(logger.events.last);

        // Build messages with pending action context if exists.
        // System rules are always enforced; SOUL.md is identity context only.
        final identityBlock =
            'Identity context (from SOUL.md — user-editable):\n${workspace.soul}';
        final baseSystem = '$_directResponseRules\n\n$identityBlock';
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
      state = AgentRuntimeState.planning;
      logger.logStateChange(state, 'Creating execution plan');
      emit(logger.events.last);
      await workspaceLoader.updateHeartbeat(
        request.agentId,
        state: state.name,
        task: request.userMessage,
      );

      final plan = await planner.plan(
        analysis: analysis,
        availableTools: availableTools,
        logger: logger,
      );
      emit(logger.events.last);

      if (plan == null) {
        return _fail('Failed to create execution plan.', logger);
      }

      // 4. Execute loop.
      return _executeLoop(
        request: request,
        plan: plan,
        executor: executor,
        availableTools: availableTools,
        logger: logger,
        emit: emit,
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
    final client = OpenAiCompatibleClient();
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
      logger.logStateChange(state, 'Executing confirmed tool: ${pending.toolName}');
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

      await workspaceLoader.updateHeartbeat(
        request.agentId,
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
            {'id': 1, 'description': 'Execute confirmed tool', 'tool': pending.toolName}
          ]
        },
        currentStep: 1,
        userMessage: request.userMessage,
        logger: logger,
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
        );
      }

      return AgentRuntimeResponse(
        finalMessage: result.success
            ? 'Tool ${pending.toolName} executed successfully.'
            : 'Tool ${pending.toolName} failed: ${result.error}',
        success: result.success,
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
    required Executor executor,
    required List<String> availableTools,
    required RuntimeLogger logger,
    required void Function(RuntimeEvent) emit,
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
          request.agentId,
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
          finalMessage: selection['question'] as String? ?? 'Need more information.',
          success: true,
          state: AgentRuntimeState.askingUser,
          events: logger.events,
        );
      }

      if (status == 'failed') {
        return _fail(selection['error'] as String? ?? 'Runtime failed.', logger);
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

        // Check confirmation requirement from REGISTRY.
        if (definition.requiresConfirmation) {
          state = AgentRuntimeState.waitingConfirmation;
          logger.logStateChange(state, 'Tool requires confirmation: ${toolRequest.name}');
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
            request.agentId,
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

        final result = await toolRouter.execute(toolRequest);
        logger.logToolResult(result);
        emit(logger.events.last);

        await workspaceLoader.updateHeartbeat(
          request.agentId,
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
            request.agentId,
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
          return _fail(review['error'] as String? ?? 'Unrecoverable error.', logger);
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
    toolRouter: ToolRouter(),
    contextBuilder: ContextBuilder(),
    languageCode: resolveLanguageCode(languagePref),
  );
});
