import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../app/theme.dart';
import '../../agents/data/agent_repository.dart';
import '../../modules/data/module_model.dart';
import '../../modules/data/module_repository.dart';
import '../../settings/data/app_language_provider.dart';

/// Home screen.
///
/// Behavior:
/// - Before any agent is set up: shows logo + a centered "Set Up" CTA.
/// - After setup: shows the modules grid with installed modules.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasAgents = ref.watch(hasAgentsProvider);
    final langPref = ref.watch(appLanguageProvider);
    final s = AppStrings(resolveLanguageCode(langPref));

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _LogoHeader(s: s),
            Expanded(
              child: hasAgents
                  ? _ModulesSection(s: s)
                  : _SetupCallToAction(s: s),
            ),
          ],
        ),
      ),
    );
  }
}

class _LogoHeader extends StatelessWidget {
  const _LogoHeader({required this.s});
  final AppStrings s;

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
              s.appTagline,
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

class _ModulesSection extends ConsumerWidget {
  const _ModulesSection({required this.s});
  final AppStrings s;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = context.cs;
    final extras = context.extras;
    final modulesAsync = ref.watch(installedModulesProvider);

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                s.modules,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => context.push('/modules/store'),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: Text(s.add),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: modulesAsync.when(
              loading: () => const Center(
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              error: (e, _) => Center(
                child: Text(s.failedLoadModules),
              ),
              data: (modules) {
                if (modules.isEmpty) {
                  return Center(
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
                            s.noModulesYet,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: cs.onSurface,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            s.noModulesBrowse,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                return ListView.builder(
                  itemCount: modules.length,
                  itemBuilder: (context, i) {
                    final module = modules[i];
                    return _ModuleCard(module: module, s: s);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ModuleCard extends StatelessWidget {
  const _ModuleCard({required this.module, required this.s});
  final ModuleModel module;
  final AppStrings s;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final extras = context.extras;

    return GestureDetector(
      onTap: () => context.push('/modules/${module.id}'),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: extras.card,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: extras.subtleBorder),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: Text(
                module.icon,
                style: const TextStyle(fontSize: 22),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    module.name,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    module.enabled ? s.active : s.disabled,
                    style: TextStyle(
                      fontSize: 12,
                      color: module.enabled
                          ? cs.primary
                          : cs.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: cs.onSurfaceVariant,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

class _SetupCallToAction extends StatelessWidget {
  const _SetupCallToAction({required this.s});
  final AppStrings s;

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
            s.welcomeTitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            s.welcomeBody,
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
              label: Text(s.setUp),
            ),
          ),
        ],
      ),
    );
  }
}
