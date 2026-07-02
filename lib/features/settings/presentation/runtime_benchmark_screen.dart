import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../app/widgets/widgets.dart';
import '../data/app_language_provider.dart';

class RuntimeBenchmarkScreen extends ConsumerWidget {
  const RuntimeBenchmarkScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final langPref = ref.watch(appLanguageProvider);
    final s = AppStrings(resolveLanguageCode(langPref));
    final cs = context.cs;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: s.closeTooltip,
          onPressed: () => context.pop(),
        ),
        title: Text(s.runtimeBenchmarkTitle),
      ),
      body: ListView(
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
            _BenchmarkCaseCard(testCase: testCase, strings: s),
            const SizedBox(height: 10),
          ],
        ],
      ),
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
  const _BenchmarkCaseCard({required this.testCase, required this.strings});

  final RuntimeBenchmarkCase testCase;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
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
        ],
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

enum RuntimeBenchmarkCase {
  profileNameNickname,
  databaseZeroRows,
  notePayloadIntegrity,
  shortFollowUp,
  capabilityBoundary,
}
