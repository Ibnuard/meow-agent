import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../app/theme.dart';
import '../../../app/widgets/meow_mascot.dart';
import '../../agents/data/agent_repository.dart';
import '../../miniapp/presentation/miniapp_list_screen.dart';
import '../../modules/data/module_model.dart';
import '../../modules/data/module_repository.dart';
import '../../modules/presentation/module_visuals.dart';
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
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? context.cs.surface
          : const Color(0xFFFBFCFE),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 104), // Clear floating dock
          child: Column(
            children: [
              _LogoHeader(s: s),
              if (hasAgents) ...[
                _ModulesSection(s: s),
                _MiniAppsHomeSection(s: s),
              ] else
                _SetupCallToAction(s: s),
            ],
          ),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 18),
        decoration: BoxDecoration(
          color: isDark ? extras.card : const Color(0xFFF6F8FC),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
            color: isDark ? extras.subtleBorder : const Color(0xFFEFF3FA),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const MeowMascot(size: 62, borderRadius: 20),
            const SizedBox(height: 14),
            ShaderMask(
              shaderCallback: (bounds) => LinearGradient(
                colors: [
                  cs.primary,
                  const Color(0xFF8B5CF6),
                  cs.primary,
                ],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ).createShader(bounds),
              child: Text(
                s.homeBrandName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.9,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              s.appTagline,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 14),
            Container(
              width: 44,
              height: 3,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    cs.primary.withValues(alpha: 0.1),
                    cs.primary.withValues(alpha: 0.5),
                    cs.primary.withValues(alpha: 0.1),
                  ],
                ),
                borderRadius: BorderRadius.circular(999),
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
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.modules,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: cs.onSurface,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      s.homeModuleSubtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => context.push('/modules/store'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.add_rounded, size: 18),
                    const SizedBox(width: 5),
                    Text(s.add),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          modulesAsync.when(
            loading: () => const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
            error: (e, _) => Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(s.failedLoadModules),
              ),
            ),
            data: (modules) {
              if (modules.isEmpty) {
                return Center(
                  child: Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: extras.card,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: extras.subtleBorder),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.extension_outlined,
                          size: 40,
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

              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: modules.length,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 0.82,
                ),
                itemBuilder: (context, i) {
                  return _ModuleCard(module: modules[i], s: s);
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

class _MiniAppsHomeSection extends ConsumerWidget {
  const _MiniAppsHomeSection({required this.s});

  final AppStrings s;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = context.cs;
    final extras = context.extras;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final modulesAsync = ref.watch(installedModulesProvider);
    final isMiniAppActive = modulesAsync.maybeWhen(
      data: (list) => list.any((m) => m.id == 'miniapp' && m.enabled),
      orElse: () => false,
    );
    if (!isMiniAppActive) return const SizedBox.shrink();

    final appsAsync = ref.watch(miniAppsListProvider);

    return appsAsync.maybeWhen(
      data: (apps) {
        final pinned = apps.where((a) => a.showOnHome).take(4).toList();
        if (pinned.isEmpty) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.miniAppsHomeTitle,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: cs.onSurface,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    s.miniAppsHomeSubtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: pinned.length,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 2.2,
                ),
                itemBuilder: (context, i) {
                  final app = pinned[i];
                  return Material(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(20),
                    child: InkWell(
                      onTap: () => context.push('/miniapp/run/${app.id}'),
                      borderRadius: BorderRadius.circular(20),
                      splashColor: cs.primary.withValues(alpha: 0.08),
                      highlightColor: cs.primary.withValues(alpha: 0.04),
                      child: Ink(
                        decoration: BoxDecoration(
                          color: isDark ? extras.card : const Color(0xFFF4F7FB),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: isDark ? extras.subtleBorder : const Color(0xFFEAF0F8),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: Row(
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: cs.primary.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  app.icon ?? '📱',
                                  style: const TextStyle(fontSize: 18),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      app.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        color: cs.onSurface,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      s.openLabel,
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                        color: cs.primary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
      orElse: () => const SizedBox.shrink(),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        onTap: () => context.push('/modules/${module.id}'),
        borderRadius: BorderRadius.circular(24),
        splashColor: cs.primary.withValues(alpha: 0.08),
        highlightColor: cs.primary.withValues(alpha: 0.04),
        child: Ink(
          decoration: BoxDecoration(
            color: isDark ? extras.card : const Color(0xFFF4F7FB),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: isDark ? extras.subtleBorder : const Color(0xFFEAF0F8),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                ModuleIconBadge(
                  moduleId: module.id,
                  size: 36,
                  iconSize: 18,
                  radius: 12,
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 28,
                  child: Center(
                    child: Text(
                      module.name,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        color: cs.onSurface,
                        height: 1.12,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  module.enabled ? s.active : s.disabled,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: module.enabled ? cs.primary : cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 86,
            height: 86,
            decoration: BoxDecoration(
              color: isDark ? extras.card : const Color(0xFFF4F7FB),
              shape: BoxShape.circle,
              border: Border.all(color: extras.subtleBorder),
            ),
            alignment: Alignment.center,
            child: const MeowMascot(
              size: 56,
              borderRadius: 22,
              showShadow: false,
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
