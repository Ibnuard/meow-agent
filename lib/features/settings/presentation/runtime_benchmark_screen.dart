import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../app/widgets/widgets.dart';
import '../../providers/data/provider_config.dart';
import '../../providers/data/provider_repository.dart';
import '../data/app_language_provider.dart';
import '../data/runtime_benchmark_runner.dart';

class RuntimeBenchmarkScreen extends ConsumerStatefulWidget {
  const RuntimeBenchmarkScreen({super.key});

  @override
  ConsumerState<RuntimeBenchmarkScreen> createState() =>
      _RuntimeBenchmarkScreenState();
}

class _RuntimeBenchmarkScreenState
    extends ConsumerState<RuntimeBenchmarkScreen> {
  final _runner = RuntimeBenchmarkRunner();
  final Map<RuntimeBenchmarkCase, RuntimeBenchmarkResult> _results = {};
  String? _selectedProviderId;
  String? _selectedModel;
  bool _running = false;

  @override
  Widget build(BuildContext context) {
    final langPref = ref.watch(appLanguageProvider);
    final s = AppStrings(resolveLanguageCode(langPref));
    final cs = context.cs;
    final providersAsync = ref.watch(providerListProvider);
    final summary = RuntimeBenchmarkRunner.summarize(_results);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: s.closeTooltip,
          onPressed: () => context.pop(),
        ),
        title: Text(s.runtimeBenchmarkTitle),
      ),
      body: providersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              error.toString(),
              style: TextStyle(color: cs.error, fontSize: 13),
            ),
          ),
        ),
        data: (providers) {
          final provider = _selectedProvider(providers);
          final selectedModel = provider == null
              ? null
              : _selectedModelFor(provider);
          final benchmarkProvider = provider == null || selectedModel == null
              ? null
              : provider.copyWith(model: selectedModel);
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            children: [
              Text(
                s.runtimeBenchmarkSubtitle,
                style: TextStyle(
                  color: cs.onSurfaceVariant,
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 16),
              _SummaryCard(
                strings: s,
                summary: summary,
                provider: provider,
                selectedModel: selectedModel,
                providers: providers,
                results: _results,
                onProviderChanged: _running
                    ? null
                    : (id) => setState(() {
                        _selectedProviderId = id;
                        _selectedModel = null;
                      }),
                onModelChanged: _running
                    ? null
                    : (model) => setState(() => _selectedModel = model),
                onRunAll: benchmarkProvider == null || _running
                    ? null
                    : () => _runAll(benchmarkProvider),
              ),
              const SizedBox(height: 18),
              MeowSection(
                title: s.runtimeBenchmarkGatesTitle,
                padding: EdgeInsets.zero,
                bottomSpacing: 0,
                child: Column(
                  children: RuntimeBenchmarkGate.values
                      .map(
                        (gate) =>
                            _GateRow(label: s.runtimeBenchmarkGate(gate.name)),
                      )
                      .toList(),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                s.runtimeBenchmarkCasesTitle,
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              for (final testCase in RuntimeBenchmarkCase.values) ...[
                _BenchmarkCaseCard(
                  testCase: testCase,
                  result:
                      _results[testCase] ??
                      RuntimeBenchmarkResult.idle(testCase),
                  strings: s,
                  running: _running,
                  providerAvailable: benchmarkProvider != null,
                  onRun: benchmarkProvider == null || _running
                      ? null
                      : () => _runOne(testCase, benchmarkProvider),
                ),
                const SizedBox(height: 10),
              ],
            ],
          );
        },
      ),
    );
  }

  ProviderConfig? _selectedProvider(List<ProviderConfig> providers) {
    if (providers.isEmpty) return null;
    final selectedId = _selectedProviderId;
    if (selectedId != null) {
      for (final provider in providers) {
        if (provider.id == selectedId && provider.isComplete) return provider;
      }
    }
    for (final provider in providers) {
      if (provider.isComplete) return provider;
    }
    return providers.first;
  }

  String? _selectedModelFor(ProviderConfig provider) {
    if (provider.models.isEmpty) return null;
    final selected = (_selectedModel ?? '').trim();
    if (selected.isNotEmpty && provider.models.contains(selected)) {
      return selected;
    }
    return provider.effectiveModel(provider.model);
  }

  Future<void> _runAll(ProviderConfig provider) async {
    setState(() => _running = true);
    for (final testCase in RuntimeBenchmarkCase.values) {
      if (!mounted) return;
      setState(() {
        _results[testCase] = RuntimeBenchmarkResult.running(testCase);
      });
      final result = await _runner.runCase(
        caseId: testCase,
        provider: provider,
      );
      if (!mounted) return;
      setState(() => _results[testCase] = result);
    }
    if (!mounted) return;
    setState(() => _running = false);
  }

  Future<void> _runOne(
    RuntimeBenchmarkCase testCase,
    ProviderConfig provider,
  ) async {
    setState(() {
      _running = true;
      _results[testCase] = RuntimeBenchmarkResult.running(testCase);
    });
    final result = await _runner.runCase(caseId: testCase, provider: provider);
    if (!mounted) return;
    setState(() {
      _results[testCase] = result;
      _running = false;
    });
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.strings,
    required this.summary,
    required this.provider,
    required this.selectedModel,
    required this.providers,
    required this.results,
    required this.onProviderChanged,
    required this.onModelChanged,
    required this.onRunAll,
  });

  final AppStrings strings;
  final RuntimeBenchmarkSummary summary;
  final ProviderConfig? provider;
  final String? selectedModel;
  final List<ProviderConfig> providers;
  final Map<RuntimeBenchmarkCase, RuntimeBenchmarkResult> results;
  final ValueChanged<String?>? onProviderChanged;
  final ValueChanged<String?>? onModelChanged;
  final VoidCallback? onRunAll;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final completeProviders = providers
        .where((provider) => provider.isComplete)
        .toList(growable: false);
    return MeowCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.speed_rounded, size: 22, color: cs.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  strings.runtimeBenchmarkScoreSummary(
                    summary.passed,
                    summary.total,
                    summary.score,
                  ),
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _TimingLine(strings: strings, summary: summary),
          const SizedBox(height: 14),
          if (completeProviders.isEmpty)
            Text(
              strings.runtimeBenchmarkNoProvider,
              style: TextStyle(color: cs.error, fontSize: 13, height: 1.35),
            )
          else
            MeowDropdown<String>(
              label: strings.runtimeBenchmarkProviderLabel,
              value: provider?.id,
              strings: strings,
              enabled: onProviderChanged != null,
              options: completeProviders
                  .map(
                    (provider) => MeowDropdownOption<String>(
                      value: provider.id,
                      label: provider.nickname,
                      subtitle: provider.model,
                    ),
                  )
                  .toList(),
              onChanged: onProviderChanged ?? (_) {},
            ),
          if (provider case final selectedProvider?
              when selectedProvider.models.isNotEmpty) ...[
            const SizedBox(height: 12),
            MeowDropdown<String>(
              label: strings.runtimeBenchmarkModelLabel,
              value: selectedModel,
              strings: strings,
              enabled: onModelChanged != null,
              options: selectedProvider.models
                  .map(
                    (model) => MeowDropdownOption<String>(
                      value: model,
                      label: model,
                      subtitle: model == selectedProvider.model
                          ? strings.runtimeBenchmarkDefaultModel
                          : null,
                    ),
                  )
                  .toList(),
              onChanged: onModelChanged ?? (_) {},
            ),
          ],
          const SizedBox(height: 12),
          MeowPrimaryButton(
            label: strings.runtimeBenchmarkRunAll,
            icon: Icons.play_arrow_rounded,
            loading: summary.running,
            onPressed: onRunAll,
          ),
          const SizedBox(height: 8),
          MeowSecondaryButton(
            label: strings.copyAllResults,
            icon: Icons.copy_all_rounded,
            onPressed: summary.completed == 0
                ? null
                : () => _copyAllReports(context),
          ),
        ],
      ),
    );
  }

  Future<void> _copyAllReports(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: _allReportsText()));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(strings.copiedToClipboard)));
  }

  String _allReportsText() {
    final providerLabel = provider?.nickname ?? '-';
    final modelLabel = selectedModel ?? provider?.model ?? '-';
    final lines = <String>[
      '# ${strings.runtimeBenchmarkTitle}',
      '- ${strings.runtimeBenchmarkProviderLabel}: $providerLabel',
      '- ${strings.runtimeBenchmarkModelLabel}: $modelLabel',
      '- ${strings.runtimeBenchmarkScoreLabel}: ${summary.passed}/${summary.total} (${summary.score})',
      '- ${strings.runtimeBenchmarkStateLabel}: ${summary.completed}/${summary.total}',
      '- ${strings.runtimeBenchmarkMessageLabel}: ${strings.runtimeBenchmarkTimingSummary(summary.completed, summary.totalDuration.inMilliseconds, summary.averageDurationMs)}',
      '',
      for (final id in RuntimeBenchmarkCase.values)
        _benchmarkResultReportText(
          strings,
          results[id] ?? RuntimeBenchmarkResult.idle(id),
        ),
    ];
    return lines.join('\n\n');
  }
}

class _TimingLine extends StatelessWidget {
  const _TimingLine({required this.strings, required this.summary});

  final AppStrings strings;
  final RuntimeBenchmarkSummary summary;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.timer_outlined, size: 18, color: cs.tertiary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            strings.runtimeBenchmarkTimingSummary(
              summary.completed,
              summary.totalDuration.inMilliseconds,
              summary.averageDurationMs,
            ),
            style: TextStyle(
              color: cs.onSurfaceVariant,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}

class _GateRow extends StatelessWidget {
  const _GateRow({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.verified_rounded, size: 18, color: cs.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: cs.onSurface, fontSize: 13, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _BenchmarkCaseCard extends StatelessWidget {
  const _BenchmarkCaseCard({
    required this.testCase,
    required this.result,
    required this.strings,
    required this.running,
    required this.providerAvailable,
    required this.onRun,
  });

  final RuntimeBenchmarkCase testCase;
  final RuntimeBenchmarkResult result;
  final AppStrings strings;
  final bool running;
  final bool providerAvailable;
  final VoidCallback? onRun;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final statusColor = _statusColor(context, result.status);
    return MeowCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.science_outlined, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  strings.runtimeBenchmarkCaseTitle(testCase.name),
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _StatusPill(
                label: _benchmarkStatusLabel(strings, result.status),
                color: statusColor,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            strings.runtimeBenchmarkCasePrompt(testCase.name),
            style: TextStyle(color: cs.onSurface, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 8),
          Text(
            strings.runtimeBenchmarkCaseExpected(testCase.name),
            style: TextStyle(
              color: cs.onSurfaceVariant,
              fontSize: 12,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.rule_rounded, size: 16, color: cs.tertiary),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  strings.runtimeBenchmarkCaseVerification(testCase.name),
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
          if (result.status != RuntimeBenchmarkStatus.idle) ...[
            const SizedBox(height: 10),
            _ResultDetails(result: result, strings: strings),
          ],
          const SizedBox(height: 12),
          MeowSecondaryButton(
            label: strings.runtimeBenchmarkRunOne,
            icon: Icons.play_circle_outline_rounded,
            loading: result.status == RuntimeBenchmarkStatus.running,
            onPressed: running || !providerAvailable ? null : onRun,
          ),
        ],
      ),
    );
  }

  Color _statusColor(BuildContext context, RuntimeBenchmarkStatus status) {
    final cs = context.cs;
    return switch (status) {
      RuntimeBenchmarkStatus.passed => cs.primary,
      RuntimeBenchmarkStatus.failed => cs.error,
      RuntimeBenchmarkStatus.error => cs.error,
      RuntimeBenchmarkStatus.running => cs.tertiary,
      RuntimeBenchmarkStatus.idle => cs.onSurfaceVariant,
    };
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 74),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _ResultDetails extends StatelessWidget {
  const _ResultDetails({required this.result, required this.strings});

  final RuntimeBenchmarkResult result;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final tools = result.dispatchSequence.isEmpty
        ? '-'
        : result.dispatchSequence.join(' -> ');
    final phases = result.llmPhases.isEmpty
        ? '-'
        : result.llmPhases.join(' -> ');
    final state = result.state?.name ?? '-';
    final duration = result.duration == null
        ? ''
        : strings.runtimeBenchmarkDurationMs(result.duration!.inMilliseconds);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.extras.inputFill,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.extras.inputBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _DetailLine(
              label: strings.runtimeBenchmarkStateLabel,
              value: duration.isEmpty ? state : '$state - $duration',
            ),
            _DetailLine(
              label: strings.runtimeBenchmarkToolsLabel,
              value: tools,
            ),
            _DetailLine(
              label: strings.runtimeBenchmarkLlmLabel,
              value: strings.runtimeBenchmarkLlmUsage(
                result.llmCallCount,
                result.inputTokens,
                result.outputTokens,
              ),
            ),
            _DetailLine(
              label: strings.runtimeBenchmarkPhasesLabel,
              value: phases,
            ),
            if (result.reason.isNotEmpty)
              _DetailLine(
                label: strings.runtimeBenchmarkReasonLabel,
                value: result.reason,
              ),
            if (result.finalMessage.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${strings.runtimeBenchmarkMessageLabel}: ${result.finalMessage}',
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 11,
                    height: 1.35,
                  ),
                ),
              ),
            if (result.status != RuntimeBenchmarkStatus.running) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => _copyReport(context),
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  label: Text(strings.copyResult),
                  style: TextButton.styleFrom(
                    foregroundColor: cs.primary,
                    textStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _copyReport(BuildContext context) async {
    await Clipboard.setData(
      ClipboardData(text: _benchmarkResultReportText(strings, result)),
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(strings.copiedToClipboard)));
  }
}

String _benchmarkResultReportText(
  AppStrings strings,
  RuntimeBenchmarkResult result,
) {
  final state = result.state?.name ?? '-';
  final tools = result.dispatchSequence.isEmpty
      ? '-'
      : result.dispatchSequence.join(' -> ');
  final phases = result.llmPhases.isEmpty ? '-' : result.llmPhases.join(' -> ');
  final duration = result.duration == null
      ? ''
      : strings.runtimeBenchmarkDurationMs(result.duration!.inMilliseconds);
  final trace = result.toolTrace
      .map((entry) => entry.toJson())
      .toList(growable: false);
  final traceText = trace.isEmpty
      ? '-'
      : const JsonEncoder.withIndent('  ').convert(trace);
  final lines = <String>[
    '# ${strings.runtimeBenchmarkCaseTitle(result.caseId.name)}',
    '- ${strings.runtimeBenchmarkStatusLabel}: ${_benchmarkStatusLabel(strings, result.status)}',
    '- ${strings.runtimeBenchmarkScoreLabel}: ${result.score}',
    '- ${strings.runtimeBenchmarkStateLabel}: ${duration.isEmpty ? state : '$state - $duration'}',
    '- ${strings.runtimeBenchmarkToolsLabel}: $tools',
    '- ${strings.runtimeBenchmarkLlmLabel}: ${strings.runtimeBenchmarkLlmUsage(result.llmCallCount, result.inputTokens, result.outputTokens)}',
    '- ${strings.runtimeBenchmarkPhasesLabel}: $phases',
    '',
    strings.runtimeBenchmarkCasePrompt(result.caseId.name),
    strings.runtimeBenchmarkCaseExpected(result.caseId.name),
    strings.runtimeBenchmarkCaseVerification(result.caseId.name),
    if (result.reason.isNotEmpty) '',
    if (result.reason.isNotEmpty)
      '${strings.runtimeBenchmarkReasonLabel}: ${result.reason}',
    if (result.finalMessage.trim().isNotEmpty) '',
    if (result.finalMessage.trim().isNotEmpty)
      '${strings.runtimeBenchmarkMessageLabel}: ${result.finalMessage}',
    '',
    '${strings.runtimeBenchmarkToolTraceLabel}:',
    if (trace.isEmpty) traceText else '```json',
    if (trace.isNotEmpty) traceText,
    if (trace.isNotEmpty) '```',
  ];
  return lines.join('\n');
}

String _benchmarkStatusLabel(
  AppStrings strings,
  RuntimeBenchmarkStatus status,
) => switch (status) {
  RuntimeBenchmarkStatus.idle => strings.runtimeBenchmarkStatusIdle,
  RuntimeBenchmarkStatus.running => strings.runtimeBenchmarkStatusRunning,
  RuntimeBenchmarkStatus.passed => strings.runtimeBenchmarkStatusPassed,
  RuntimeBenchmarkStatus.failed => strings.runtimeBenchmarkStatusFailed,
  RuntimeBenchmarkStatus.error => strings.runtimeBenchmarkStatusError,
};

class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        '$label: $value',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11, height: 1.3),
      ),
    );
  }
}

enum RuntimeBenchmarkGate {
  canonicalArgs,
  postExecuteProbe,
  doneGate,
  toolNarrowing,
}
