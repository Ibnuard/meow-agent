import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../app/theme.dart';
import '../../../app/theme_mode_provider.dart';
import '../data/app_language_provider.dart';
import '../data/llm_debug_provider.dart';

import '../../providers/data/provider_repository.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = context.cs;
    final providersAsync = ref.watch(providerListProvider);
    final isDark = ref.watch(themeModeProvider) == ThemeMode.dark;
    final appLanguage = ref.watch(appLanguageProvider);
    final strings = AppStrings(resolveLanguageCode(appLanguage));

    return Scaffold(
      appBar: AppBar(title: Text(strings.settings)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
          children: [
            // ─── PROVIDERS ───────────────────────────────────
            _SectionHeader(label: strings.providers),
            const SizedBox(height: 10),
            _SettingsGroup(
              children: [
                _SettingsTile(
                  icon: Icons.dns_outlined,
                  label: strings.manageProviders,
                  trailing: providersAsync.when(
                    data: (list) => Text(
                      '${list.length}',
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    loading: () => const SizedBox.shrink(),
                    error: (e, _) => const SizedBox.shrink(),
                  ),
                  onTap: () => context.push(AppRoutes.providerList),
                ),
              ],
            ),

            const SizedBox(height: 28),

            // ─── PREFERENCES ─────────────────────────────────
            _SectionHeader(label: strings.preferences),
            const SizedBox(height: 10),
            _SettingsGroup(
              children: [
                _SettingsToggleTile(
                  icon: Icons.dark_mode_outlined,
                  label: strings.darkMode,
                  value: isDark,
                  onChanged: (v) {
                    ref.read(themeModeProvider.notifier).set(
                          v ? ThemeMode.dark : ThemeMode.light,
                        );
                  },
                ),
                _SettingsTile(
                  icon: Icons.language_rounded,
                  label: strings.language,
                  trailing: Text(
                    appLanguage.label,
                    style: TextStyle(
                      fontSize: 13,
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onTap: () => _showLanguageSheet(
                    context,
                    ref,
                    appLanguage,
                    strings,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 28),

            // ─── DEVELOPER ───────────────────────────────────
            _SectionHeader(label: strings.developer),
            const SizedBox(height: 10),
            _SettingsGroup(
              children: [
                _SettingsToggleTile(
                  icon: Icons.bug_report_outlined,
                  label: strings.llmDebugging,
                  value: ref.watch(llmDebugModeProvider),
                  onChanged: (v) {
                    ref.read(llmDebugModeProvider.notifier).toggle(v);
                  },
                ),
              ],
            ),

            const SizedBox(height: 28),

            // ─── SUPPORT ─────────────────────────────────────
            _SectionHeader(label: strings.support),
            const SizedBox(height: 10),
            _SettingsGroup(
              children: [
                _SettingsTile(
                  icon: Icons.info_outline_rounded,
                  label: strings.aboutApp,
                  onTap: () {
                    showDialog(
                      context: context,
                      builder: (dialogCtx) => AlertDialog(
                        title: const Text('Meow Agent'),
                        content: Text(strings.aboutBody),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(dialogCtx),
                            child: Text(strings.close),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showLanguageSheet(
    BuildContext context,
    WidgetRef ref,
    AppLanguage current,
    AppStrings strings,
  ) {
    final cs = context.cs;
    final extras = context.extras;
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    // Modal sheet should cover AppShell's floating dock, but still float above
    // Android navigation. Keep a generous lift so it never feels buried.
    final sheetBottomPadding = bottomInset > 0 ? bottomInset + 76.0 : 56.0;

    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        return Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, sheetBottomPadding),
          child: Container(
            decoration: BoxDecoration(
              color: extras.card,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: extras.subtleBorder, width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.22),
                  blurRadius: 32,
                  offset: const Offset(0, 18),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: cs.onSurfaceVariant.withValues(alpha: 0.28),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    strings.language,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    strings.languageDescription,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.35,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 18),
                  for (final lang in AppLanguage.values)
                    _LanguageOptionTile(
                      language: lang,
                      selected: lang == current,
                      onTap: () async {
                        await ref.read(appLanguageProvider.notifier).set(lang);
                        if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                      },
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LanguageOptionTile extends StatelessWidget {
  const _LanguageOptionTile({
    required this.language,
    required this.selected,
    required this.onTap,
  });

  final AppLanguage language;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: selected
            ? cs.primary.withValues(alpha: 0.12)
            : cs.onSurface.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    language.label,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: cs.onSurface,
                    ),
                  ),
                ),
                if (selected)
                  Icon(
                    Icons.check_circle_rounded,
                    size: 20,
                    color: cs.primary,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Small caps section header.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: context.cs.onSurfaceVariant.withValues(alpha: 0.6),
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

/// Grouped container for settings tiles — rounded card with subtle border.
class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final extras = context.extras;
    return Container(
      decoration: BoxDecoration(
        color: extras.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: extras.subtleBorder, width: 1),
      ),
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            children[i],
            if (i < children.length - 1)
              Divider(
                height: 1,
                thickness: 1,
                indent: 52,
                color: extras.subtleBorder,
              ),
          ],
        ],
      ),
    );
  }
}

/// A single settings row: icon + label + trailing (chevron or custom).
class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.label,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(icon, size: 20, color: cs.onSurfaceVariant),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: cs.onSurface,
                  ),
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                trailing!,
              ],
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: cs.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A settings row with a toggle switch instead of chevron.
class _SettingsToggleTile extends StatelessWidget {
  const _SettingsToggleTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(icon, size: 20, color: cs.onSurfaceVariant),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: cs.onSurface,
              ),
            ),
          ),
          Switch.adaptive(
            value: value,
            onChanged: onChanged,
            activeTrackColor: cs.primary,
            activeThumbColor: cs.onPrimary,
          ),
        ],
      ),
    );
  }
}
