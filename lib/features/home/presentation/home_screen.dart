import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../app/theme.dart';
import '../../agents/data/agent_repository.dart';

/// Home screen.
///
/// Behavior:
/// - Before any agent is set up: shows logo + a centered "Set Up" CTA.
/// - After setup: shows the modules grid (currently empty placeholder).
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasAgents = ref.watch(hasAgentsProvider);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const _LogoHeader(),
            Expanded(
              child: hasAgents
                  ? const _ModulesEmptyState()
                  : const _SetupCallToAction(),
            ),
          ],
        ),
      ),
    );
  }
}

class _LogoHeader extends StatelessWidget {
  const _LogoHeader();

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 22),
        decoration: BoxDecoration(
          color: extras.card,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: extras.subtleBorder),
        ),
        child: Column(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [cs.primary, extras.gradientEnd],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(18),
              ),
              alignment: Alignment.center,
              child: const Text('🐾', style: TextStyle(fontSize: 28)),
            ),
            const SizedBox(height: 10),
            Text(
              'MEOW AGENT',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                letterSpacing: 2.0,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Android-native agentic AI',
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModulesEmptyState extends StatelessWidget {
  const _ModulesEmptyState();

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Modules',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Center(
              child: Container(
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: extras.card,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: extras.subtleBorder),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.extension_outlined,
                      size: 44,
                      color: cs.primary.withValues(alpha: 0.7),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'No modules yet',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Modules will show up here once installed.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SetupCallToAction extends StatelessWidget {
  const _SetupCallToAction();

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: extras.card,
              shape: BoxShape.circle,
              border: Border.all(color: extras.subtleBorder),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.auto_awesome_rounded,
              size: 44,
              color: cs.primary,
            ),
          ),
          const SizedBox(height: 22),
          Text(
            'Welcome to Meow Agent',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Set up your first agent to get started. '
            'Bring your own OpenAI-compatible API key.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: cs.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 28),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => context.push(AppRoutes.addAgent),
              icon: const Icon(Icons.rocket_launch_rounded, size: 18),
              label: const Text('Set Up'),
            ),
          ),
        ],
      ),
    );
  }
}
