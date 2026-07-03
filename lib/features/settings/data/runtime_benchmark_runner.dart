import 'dart:async';

import 'package:sqflite/sqflite.dart';

import '../../chat/data/chat_history_service.dart';
import '../../../services/agent_runtime/context_builder.dart';
import '../../../services/agent_runtime/runtime_engine.dart';
import '../../../services/agent_runtime/runtime_models.dart';
import '../../../services/agent_runtime/task_ledger.dart';
import '../../../services/agent_runtime/tool_router.dart';
import '../../../services/agent_runtime/workspace_folder_service.dart';
import '../../../services/llm/openai_compatible_client.dart';
import '../../providers/data/provider_config.dart';

enum RuntimeBenchmarkStatus { idle, running, passed, failed, error }

enum RuntimeBenchmarkCase {
  profileNameNickname,
  databaseZeroRows,
  notePayloadIntegrity,
  simpleBattery,
  createNote,
  noCapabilitySms,
  ambiguousTimer,
  multiNote,
  indonesianBattery,
  listAgents,
  emptySearch,
  failedNote,
  directResponse,
  staleHistoryIsolation,
  workflowList,
  workflowSensitiveBlocked,
}

class RuntimeBenchmarkSummary {
  const RuntimeBenchmarkSummary({
    required this.total,
    required this.passed,
    required this.failed,
    required this.running,
    required this.completed,
    required this.totalDuration,
  });

  final int total;
  final int passed;
  final int failed;
  final bool running;
  final int completed;
  final Duration totalDuration;

  int get score => total == 0 ? 0 : ((passed / total) * 100).round();
  int get averageDurationMs =>
      completed == 0 ? 0 : (totalDuration.inMilliseconds / completed).round();
}

class RuntimeBenchmarkResult {
  const RuntimeBenchmarkResult({
    required this.caseId,
    required this.status,
    required this.score,
    this.finalMessage = '',
    this.state,
    this.dispatchSequence = const [],
    this.reason = '',
    this.duration,
    this.llmCallCount = 0,
    this.llmPhases = const [],
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.toolTrace = const [],
  });

  const RuntimeBenchmarkResult.idle(this.caseId)
    : status = RuntimeBenchmarkStatus.idle,
      score = 0,
      finalMessage = '',
      state = null,
      dispatchSequence = const [],
      reason = '',
      duration = null,
      llmCallCount = 0,
      llmPhases = const [],
      inputTokens = 0,
      outputTokens = 0,
      toolTrace = const [];

  const RuntimeBenchmarkResult.running(this.caseId)
    : status = RuntimeBenchmarkStatus.running,
      score = 0,
      finalMessage = '',
      state = null,
      dispatchSequence = const [],
      reason = '',
      duration = null,
      llmCallCount = 0,
      llmPhases = const [],
      inputTokens = 0,
      outputTokens = 0,
      toolTrace = const [];

  final RuntimeBenchmarkCase caseId;
  final RuntimeBenchmarkStatus status;
  final int score;
  final String finalMessage;
  final AgentRuntimeState? state;
  final List<String> dispatchSequence;
  final String reason;
  final Duration? duration;
  final int llmCallCount;
  final List<String> llmPhases;
  final int inputTokens;
  final int outputTokens;
  final List<RuntimeBenchmarkToolTrace> toolTrace;
}

class RuntimeBenchmarkToolTrace {
  const RuntimeBenchmarkToolTrace({
    required this.name,
    required this.args,
    required this.success,
    this.data,
    this.error,
  });

  final String name;
  final Map<String, dynamic> args;
  final bool success;
  final Map<String, dynamic>? data;
  final String? error;

  Map<String, dynamic> toJson() => {
    'tool': name,
    'args': args,
    'success': success,
    if (data != null) 'data': data,
    if (error != null && error!.isNotEmpty) 'error': error,
  };
}

class RuntimeBenchmarkRunner {
  RuntimeBenchmarkRunner({OpenAiCompatibleClient? llmClient})
    : _llmClient = llmClient ?? OpenAiCompatibleClient();

  final OpenAiCompatibleClient _llmClient;

  Future<RuntimeBenchmarkResult> runCase({
    required RuntimeBenchmarkCase caseId,
    required ProviderConfig provider,
  }) async {
    final spec = _specs[caseId]!;
    final router = _BenchmarkToolRouter(
      results: spec.results,
      resultsByCall: spec.resultsByCall,
    );
    final engine = AgentRuntimeEngine(
      workspaceFolder: _NoopWorkspaceFolderService(),
      toolRouter: router,
      contextBuilder: ContextBuilder(),
      languageCode: spec.languageCode,
      llmClient: _llmClient,
      ledgerDb: TaskLedgerDatabase(overrideDbPath: inMemoryDatabasePath),
    );
    final started = DateTime.now();
    final usageStart = OpenAiCompatibleClient.usageRecords.length;

    try {
      final response = await engine.run(
        AgentRuntimeRequest(
          agentId: 'runtime-benchmark-${caseId.name}',
          agentName: 'BenchmarkAgent',
          userMessage: spec.message,
          recentMessages: spec.recentMessages,
          source: spec.source,
        ),
        provider: provider,
        autoApproveSensitive: spec.autoApproveSensitive,
      );
      final verdict = spec.evaluate(response, router);
      final usage = _usageSince(usageStart, started);
      return RuntimeBenchmarkResult(
        caseId: caseId,
        status: verdict.passed
            ? RuntimeBenchmarkStatus.passed
            : RuntimeBenchmarkStatus.failed,
        score: verdict.passed ? 100 : 0,
        finalMessage: response.finalMessage,
        state: response.state,
        dispatchSequence: router.dispatchSequence,
        toolTrace: router.toolTrace,
        reason: verdict.reason,
        duration: DateTime.now().difference(started),
        llmCallCount: usage.callCount,
        llmPhases: usage.phases,
        inputTokens: usage.inputTokens,
        outputTokens: usage.outputTokens,
      );
    } catch (e) {
      final usage = _usageSince(usageStart, started);
      return RuntimeBenchmarkResult(
        caseId: caseId,
        status: RuntimeBenchmarkStatus.error,
        score: 0,
        reason: e.toString(),
        dispatchSequence: router.dispatchSequence,
        toolTrace: router.toolTrace,
        duration: DateTime.now().difference(started),
        llmCallCount: usage.callCount,
        llmPhases: usage.phases,
        inputTokens: usage.inputTokens,
        outputTokens: usage.outputTokens,
      );
    }
  }

  static RuntimeBenchmarkSummary summarize(
    Map<RuntimeBenchmarkCase, RuntimeBenchmarkResult> results,
  ) {
    final values = RuntimeBenchmarkCase.values.map(
      (id) => results[id] ?? RuntimeBenchmarkResult.idle(id),
    );
    final passed = values
        .where((r) => r.status == RuntimeBenchmarkStatus.passed)
        .length;
    final failed = values
        .where(
          (r) =>
              r.status == RuntimeBenchmarkStatus.failed ||
              r.status == RuntimeBenchmarkStatus.error,
        )
        .length;
    final running = values.any(
      (r) => r.status == RuntimeBenchmarkStatus.running,
    );
    final completedValues = values
        .where(
          (r) =>
              r.status == RuntimeBenchmarkStatus.passed ||
              r.status == RuntimeBenchmarkStatus.failed ||
              r.status == RuntimeBenchmarkStatus.error,
        )
        .toList(growable: false);
    final totalDuration = completedValues.fold<Duration>(
      Duration.zero,
      (total, result) => total + (result.duration ?? Duration.zero),
    );
    return RuntimeBenchmarkSummary(
      total: RuntimeBenchmarkCase.values.length,
      passed: passed,
      failed: failed,
      running: running,
      completed: completedValues.length,
      totalDuration: totalDuration,
    );
  }

  _BenchmarkUsage _usageSince(int startIndex, DateTime startedAt) {
    final records = OpenAiCompatibleClient.usageRecords;
    final slice = startIndex <= records.length
        ? records.skip(startIndex)
        : records.where((record) => !record.createdAt.isBefore(startedAt));
    final phases = <String>[];
    var inputTokens = 0;
    var outputTokens = 0;
    for (final record in slice) {
      phases.add(record.phase);
      inputTokens += record.inputTokens;
      outputTokens += record.outputTokens ?? 0;
    }
    return _BenchmarkUsage(
      callCount: phases.length,
      phases: phases,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
    );
  }
}

class _BenchmarkUsage {
  const _BenchmarkUsage({
    required this.callCount,
    required this.phases,
    required this.inputTokens,
    required this.outputTokens,
  });

  final int callCount;
  final List<String> phases;
  final int inputTokens;
  final int outputTokens;
}

class _BenchmarkCaseSpec {
  const _BenchmarkCaseSpec({
    required this.message,
    required this.results,
    required this.evaluate,
    this.resultsByCall = const {},
    this.languageCode = 'en',
    this.source = RequestSource.chat,
    this.recentMessages = const [],
    this.autoApproveSensitive = true,
  });

  final String message;
  final Map<String, ToolExecutionResult> results;
  final Map<String, List<ToolExecutionResult>> resultsByCall;
  final String languageCode;
  final RequestSource source;
  final List<ChatMessage> recentMessages;
  final bool autoApproveSensitive;
  final _BenchmarkVerdict Function(
    AgentRuntimeResponse response,
    _BenchmarkToolRouter router,
  )
  evaluate;
}

class _BenchmarkVerdict {
  const _BenchmarkVerdict(this.passed, this.reason);

  final bool passed;
  final String reason;
}

class _BenchmarkDispatch {
  const _BenchmarkDispatch({required this.name, required this.args});

  final String name;
  final Map<String, dynamic> args;
}

class _BenchmarkToolRouter extends ToolRouter {
  _BenchmarkToolRouter({
    required Map<String, ToolExecutionResult> results,
    Map<String, List<ToolExecutionResult>> resultsByCall = const {},
  }) : _results = results,
       _resultsByCall = resultsByCall.map(
         (key, value) => MapEntry(key, List<ToolExecutionResult>.of(value)),
       ),
       super(agentId: 'runtime-benchmark', agentName: 'BenchmarkAgent');

  final Map<String, ToolExecutionResult> _results;
  final Map<String, List<ToolExecutionResult>> _resultsByCall;
  final List<_BenchmarkDispatch> dispatchLog = [];
  final List<RuntimeBenchmarkToolTrace> toolTrace = [];

  List<String> get dispatchSequence =>
      dispatchLog.map((dispatch) => dispatch.name).toList();

  int dispatchCountOf(String toolName) =>
      dispatchLog.where((dispatch) => dispatch.name == toolName).length;

  @override
  Future<ToolExecutionResult> execute(ToolCallRequest request) async {
    final result = _resultFor(request);
    dispatchLog.add(_BenchmarkDispatch(name: request.name, args: request.args));
    toolTrace.add(
      RuntimeBenchmarkToolTrace(
        name: request.name,
        args: request.args,
        success: result.success,
        data: result.data,
        error: result.error,
      ),
    );
    return result;
  }

  @override
  Future<ToolExecutionResult> forceExecute(ToolCallRequest request) async {
    final result = _resultFor(request);
    dispatchLog.add(_BenchmarkDispatch(name: request.name, args: request.args));
    toolTrace.add(
      RuntimeBenchmarkToolTrace(
        name: request.name,
        args: request.args,
        success: result.success,
        data: result.data,
        error: result.error,
      ),
    );
    return result;
  }

  @override
  Future<ToolExecutionResult?> permissionDeniedResult(String toolName) async =>
      null;

  @override
  Future<bool> requiresCrossWorkspaceConfirmation(
    ToolCallRequest request,
  ) async => false;

  ToolExecutionResult _resultFor(ToolCallRequest request) {
    final queue = _resultsByCall[request.name];
    if (queue != null && queue.isNotEmpty) return queue.removeAt(0);
    final canned = _results[request.name];
    if (canned != null) return canned;
    final fallback = _fallbackResultFor(request);
    if (fallback != null) return fallback;
    return ToolExecutionResult(
      success: false,
      toolName: request.name,
      error: 'No benchmark result scripted for ${request.name}.',
    );
  }

  ToolExecutionResult? _fallbackResultFor(ToolCallRequest request) {
    switch (request.name) {
      case 'db.list_tables':
        return const ToolExecutionResult(
          success: true,
          toolName: 'db.list_tables',
          data: {
            'tables': [
              {
                'name': 'tasks',
                'rowCount': 1,
                'columns': ['title', 'status'],
              },
            ],
            'benchmarkInstruction':
                'Schema is confirmed; the requested update has not happened yet. Next call must be db.update.',
          },
        );
      case 'db.describe_table':
        final table = (request.args['table'] ?? 'tasks').toString();
        return ToolExecutionResult(
          success: true,
          toolName: 'db.describe_table',
          data: {
            'table': table,
            'rowCount': 1,
            'columns': const [
              {'name': 'title', 'type': 'TEXT'},
              {'name': 'status', 'type': 'TEXT'},
            ],
            'benchmarkInstruction':
                'Schema is confirmed; the requested update has not happened yet. Next call must be db.update.',
          },
        );
      case 'db.update':
        final table = (request.args['table'] ?? 'tasks').toString();
        return ToolExecutionResult(
          success: true,
          toolName: 'db.update',
          data: {
            'updated': 0,
            'table': table,
            'verifiedRows': 0,
            'persisted': false,
          },
        );
      default:
        return null;
    }
  }
}

class _NoopWorkspaceFolderService extends WorkspaceFolderService {
  @override
  Future<void> ensureFolder(String agentName) async {}
}

final Map<RuntimeBenchmarkCase, _BenchmarkCaseSpec> _specs = {
  RuntimeBenchmarkCase.profileNameNickname: _BenchmarkCaseSpec(
    languageCode: 'id',
    message: 'nama gw Nunu nah panggilannya King',
    results: const {},
    resultsByCall: const {
      'system.profile.update': [
        ToolExecutionResult(
          success: true,
          toolName: 'system.profile.update',
          data: {'field': 'name', 'value': 'Nunu', 'persisted': true},
        ),
        ToolExecutionResult(
          success: true,
          toolName: 'system.profile.update',
          data: {'field': 'nickname', 'value': 'King', 'persisted': true},
        ),
      ],
    },
    evaluate: (response, router) {
      final fields = router.dispatchLog
          .where((dispatch) => dispatch.name == 'system.profile.update')
          .map(
            (dispatch) => '${dispatch.args['field']}:${dispatch.args['value']}',
          )
          .toSet();
      final passed =
          response.state == AgentRuntimeState.done &&
          fields.contains('name:Nunu') &&
          fields.contains('nickname:King');
      return _BenchmarkVerdict(
        passed,
        passed
            ? 'profile fields matched'
            : 'expected system.profile.update for name=Nunu and nickname=King',
      );
    },
  ),
  RuntimeBenchmarkCase.databaseZeroRows: _BenchmarkCaseSpec(
    message:
        'The tasks table and columns title/status are known to exist. Call db.update directly: set status to done where title equals Ghost Task.',
    results: const {
      'db.list_tables': ToolExecutionResult(
        success: true,
        toolName: 'db.list_tables',
        data: {
          'tables': [
            {
              'name': 'tasks',
              'rowCount': 1,
              'columns': ['title', 'status'],
            },
          ],
          'benchmarkInstruction':
              'Schema is confirmed; the requested update has not happened yet. Next call must be db.update.',
        },
      ),
      'db.describe_table': ToolExecutionResult(
        success: true,
        toolName: 'db.describe_table',
        data: {
          'table': 'tasks',
          'rowCount': 1,
          'columns': [
            {'name': 'title', 'type': 'TEXT'},
            {'name': 'status', 'type': 'TEXT'},
          ],
          'benchmarkInstruction':
              'Schema is confirmed; the requested update has not happened yet. Next call must be db.update.',
        },
      ),
      'db.update': ToolExecutionResult(
        success: true,
        toolName: 'db.update',
        data: {
          'updated': 0,
          'table': 'tasks',
          'verifiedRows': 0,
          'persisted': false,
        },
      ),
    },
    evaluate: (response, router) {
      final claimedDone =
          response.state == AgentRuntimeState.done && response.success;
      final passed = router.dispatchCountOf('db.update') > 0 && !claimedDone;
      return _BenchmarkVerdict(
        passed,
        passed
            ? 'zero-row mutation was not accepted as done'
            : 'expected db.update zero rows to block a done success',
      );
    },
  ),
  RuntimeBenchmarkCase.notePayloadIntegrity: _BenchmarkCaseSpec(
    message: 'Create a note titled Launch Plan with body Ship benchmark UI.',
    results: const {
      'notes.create': ToolExecutionResult(
        success: true,
        toolName: 'notes.create',
        data: {
          'noteId': 'bench-note-1',
          'title': 'Launch Plan',
          'content': 'Ship benchmark UI.',
          'created': true,
          'persisted': true,
          'verifiedFields': 2,
        },
      ),
    },
    evaluate: (response, router) {
      final dispatches = router.dispatchLog.where(
        (dispatch) => dispatch.name == 'notes.create',
      );
      final payloadMatched = dispatches.any((dispatch) {
        final args = dispatch.args.toString().toLowerCase();
        return args.contains('launch plan') && args.contains('benchmark');
      });
      final passed =
          response.state == AgentRuntimeState.done &&
          response.success &&
          payloadMatched;
      return _BenchmarkVerdict(
        passed,
        passed
            ? 'note payload matched'
            : 'expected notes.create with title/body from the request',
      );
    },
  ),
  RuntimeBenchmarkCase.simpleBattery: _BenchmarkCaseSpec(
    message: 'how much battery do I have left?',
    results: const {
      'device.battery': ToolExecutionResult(
        success: true,
        toolName: 'device.battery',
        data: {'level': 72, 'charging': true},
      ),
    },
    evaluate: (response, router) {
      final passed =
          response.state == AgentRuntimeState.done &&
          response.success &&
          response.finalMessage.contains('72') &&
          router.dispatchCountOf('device.battery') > 0;
      return _BenchmarkVerdict(
        passed,
        passed ? 'battery answer grounded' : 'expected grounded battery answer',
      );
    },
  ),
  RuntimeBenchmarkCase.createNote: _BenchmarkCaseSpec(
    message: 'create a note titled Shopping List with milk and eggs',
    results: const {
      'notes.create': ToolExecutionResult(
        success: true,
        toolName: 'notes.create',
        data: {
          'noteId': 'n42',
          'title': 'Shopping List',
          'content': 'milk and eggs',
          'created': true,
          'persisted': true,
          'verifiedFields': 2,
        },
      ),
    },
    evaluate: (response, router) {
      final passed =
          response.state == AgentRuntimeState.done &&
          response.success &&
          router.dispatchCountOf('notes.create') > 0;
      return _BenchmarkVerdict(
        passed,
        passed ? 'note creation completed' : 'expected completed notes.create',
      );
    },
  ),
  RuntimeBenchmarkCase.noCapabilitySms: _BenchmarkCaseSpec(
    message: 'send an SMS to my mom saying I will be late',
    results: const {},
    evaluate: (response, router) {
      final msg = response.finalMessage.toLowerCase();
      final passed =
          !msg.contains('sms sent') &&
          !msg.contains('sent the sms') &&
          !router.dispatchSequence.any((tool) => tool.contains('sms'));
      return _BenchmarkVerdict(
        passed,
        passed
            ? 'no fabricated SMS capability'
            : 'runtime appeared to claim or dispatch SMS capability',
      );
    },
  ),
  RuntimeBenchmarkCase.ambiguousTimer: _BenchmarkCaseSpec(
    message: 'set timer',
    results: const {},
    evaluate: (response, router) {
      final passed = router.dispatchSequence.isEmpty;
      return _BenchmarkVerdict(
        passed,
        passed
            ? 'no tool dispatched'
            : 'ambiguous impossible timer used a tool',
      );
    },
  ),
  RuntimeBenchmarkCase.multiNote: _BenchmarkCaseSpec(
    message:
        'create three notes: one about meeting agenda, one about groceries, and one about book recommendations',
    results: const {
      'notes.create': ToolExecutionResult(
        success: true,
        toolName: 'notes.create',
        data: {
          'noteId': 'n_multi',
          'created': true,
          'persisted': true,
          'verifiedFields': 1,
        },
      ),
    },
    evaluate: (response, router) {
      final passed =
          response.state == AgentRuntimeState.askingUser ||
          (response.state == AgentRuntimeState.done &&
              router.dispatchCountOf('notes.create') >= 2);
      return _BenchmarkVerdict(
        passed,
        passed
            ? 'multi-note path acceptable'
            : 'expected clarification or multiple notes.create dispatches',
      );
    },
  ),
  RuntimeBenchmarkCase.indonesianBattery: _BenchmarkCaseSpec(
    languageCode: 'id',
    message: 'berapa baterai aku sekarang?',
    results: const {
      'device.battery': ToolExecutionResult(
        success: true,
        toolName: 'device.battery',
        data: {'level': 55, 'charging': false},
      ),
    },
    evaluate: (response, router) {
      final passed =
          response.state == AgentRuntimeState.done &&
          response.success &&
          router.dispatchCountOf('device.battery') > 0;
      return _BenchmarkVerdict(
        passed,
        passed
            ? 'Indonesian battery query passed'
            : 'expected battery dispatch',
      );
    },
  ),
  RuntimeBenchmarkCase.listAgents: _BenchmarkCaseSpec(
    message: 'what agents do I have installed?',
    results: const {
      'agent.list': ToolExecutionResult(
        success: true,
        toolName: 'agent.list',
        data: {
          'count': 2,
          'self_id': 'agent_1',
          'self_name': 'Mina Chan',
          'agents': [
            {
              'id': 'agent_1',
              'name': 'Mina Chan',
              'provider_id': 'p1',
              'model': 'm1',
              'persona': '',
              'communication_style': '',
              'work_role': '',
              'is_self': true,
            },
            {
              'id': 'agent_2',
              'name': 'Kai',
              'provider_id': 'p1',
              'model': 'm1',
              'persona': '',
              'communication_style': '',
              'work_role': '',
              'is_self': false,
            },
          ],
        },
      ),
    },
    evaluate: (response, router) {
      final msg = response.finalMessage.toLowerCase();
      final passed =
          response.state == AgentRuntimeState.done &&
          response.success &&
          router.dispatchCountOf('agent.list') > 0 &&
          (msg.contains('mina') ||
              msg.contains('kai') ||
              msg.contains('agent')) &&
          !router.dispatchSequence.any(
            (tool) => tool.startsWith('system.agents.'),
          );
      return _BenchmarkVerdict(
        passed,
        passed ? 'agent list grounded' : 'expected grounded agent.list answer',
      );
    },
  ),
  RuntimeBenchmarkCase.emptySearch: _BenchmarkCaseSpec(
    message: 'find my notes about quantum physics',
    results: const {
      'notes.search': ToolExecutionResult(
        success: true,
        toolName: 'notes.search',
        data: {'count': 0, 'results': []},
      ),
    },
    evaluate: (response, router) {
      final passed =
          response.state == AgentRuntimeState.done &&
          response.success &&
          router.dispatchCountOf('notes.search') == 1;
      return _BenchmarkVerdict(
        passed,
        passed ? 'empty result accepted' : 'expected one notes.search dispatch',
      );
    },
  ),
  RuntimeBenchmarkCase.failedNote: _BenchmarkCaseSpec(
    message: 'make a note titled Important',
    results: const {
      'notes.create': ToolExecutionResult(
        success: false,
        toolName: 'notes.create',
        error: 'Storage is full - cannot create note.',
      ),
    },
    evaluate: (response, router) {
      final msg = response.finalMessage.toLowerCase();
      final passed =
          router.dispatchCountOf('notes.create') > 0 &&
          !msg.contains('created') &&
          !msg.contains('saved') &&
          !msg.contains('successfully');
      return _BenchmarkVerdict(
        passed,
        passed
            ? 'failed tool reported honestly'
            : 'failure looked like success',
      );
    },
  ),
  RuntimeBenchmarkCase.directResponse: _BenchmarkCaseSpec(
    languageCode: 'id',
    message: 'siapa namamu?',
    results: const {},
    evaluate: (response, router) {
      final passed =
          response.state == AgentRuntimeState.done &&
          response.success &&
          router.dispatchSequence.isEmpty;
      return _BenchmarkVerdict(
        passed,
        passed ? 'direct response used no tool' : 'identity answer used a tool',
      );
    },
  ),
  RuntimeBenchmarkCase.staleHistoryIsolation: _BenchmarkCaseSpec(
    languageCode: 'id',
    message: 'halo bejo',
    recentMessages: [
      ChatMessage(
        role: 'user',
        content: 'cek system soul existing name=Nunu nickname=King',
      ),
      ChatMessage(
        role: 'assistant',
        content: 'Semua field profile sudah tersimpan di agent_soul table.',
      ),
    ],
    results: const {},
    evaluate: (response, router) {
      final msg = response.finalMessage.toLowerCase();
      final passed =
          response.state == AgentRuntimeState.done &&
          response.success &&
          router.dispatchSequence.isEmpty &&
          !msg.contains('profile') &&
          !msg.contains('soul') &&
          !msg.contains('nunu') &&
          !msg.contains('king');
      return _BenchmarkVerdict(
        passed,
        passed
            ? 'short chat ignored stale recent history'
            : 'short chat appeared to use stale history',
      );
    },
  ),
  RuntimeBenchmarkCase.workflowList: _BenchmarkCaseSpec(
    message: 'list my configured workflows',
    results: const {
      'workflow.list': ToolExecutionResult(
        success: true,
        toolName: 'workflow.list',
        data: {
          'count': 2,
          'totalCount': 2,
          'callerAgentId': 'runtime-benchmark',
          'workflows': [
            {
              'id': 'wf_morning',
              'title': 'Morning Brief',
              'trigger': 'Daily at 08:00',
              'enabled': true,
              'assignedAgentId': 'agent_1',
              'priority': 'normal',
              'isChained': false,
              'stepCount': 0,
            },
            {
              'id': 'wf_digest',
              'title': 'Notification Digest',
              'trigger': 'Every 60 minutes',
              'enabled': false,
              'assignedAgentId': 'agent_1',
              'priority': 'normal',
              'isChained': true,
              'stepCount': 2,
            },
          ],
        },
      ),
    },
    evaluate: (response, router) {
      final msg = response.finalMessage.toLowerCase();
      final passed =
          response.state == AgentRuntimeState.done &&
          response.success &&
          router.dispatchCountOf('workflow.list') > 0 &&
          (msg.contains('morning') || msg.contains('digest'));
      return _BenchmarkVerdict(
        passed,
        passed
            ? 'workflow list answer was grounded'
            : 'expected workflow.list and returned workflow titles',
      );
    },
  ),
  RuntimeBenchmarkCase.workflowSensitiveBlocked: _BenchmarkCaseSpec(
    source: RequestSource.workflow,
    autoApproveSensitive: false,
    message: 'delete the note with id bench-note-1',
    results: const {
      'notes.delete': ToolExecutionResult(
        success: true,
        toolName: 'notes.delete',
        data: {'deleted': true, 'noteId': 'bench-note-1', 'absent': true},
      ),
    },
    evaluate: (response, router) {
      final passed =
          response.state == AgentRuntimeState.blockedSensitive &&
          !response.success &&
          response.pendingTool == 'notes.delete' &&
          router.dispatchSequence.isEmpty;
      return _BenchmarkVerdict(
        passed,
        passed
            ? 'workflow sensitive action blocked before dispatch'
            : 'expected workflow sensitive action to block without dispatch',
      );
    },
  ),
};
