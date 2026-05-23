import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../app/theme.dart';
import '../../../app/theme_mode_provider.dart';

import '../../providers/data/provider_repository.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = context.cs;
    final providersAsync = ref.watch(providerListProvider);
    final isDark = ref.watch(themeModeProvider) == ThemeMode.dark;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
          children: [
            // ─── PROVIDERS ───────────────────────────────────
            _SectionHeader(label: 'PROVIDERS'),
            const SizedBox(height: 10),
            _SettingsGroup(
              children: [
                _SettingsTile(
                  icon: Icons.dns_outlined,
                  label: 'Manage Providers',
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
            _SectionHeader(label: 'PREFERENCES'),
            const SizedBox(height: 10),
            _SettingsGroup(
              children: [
                _SettingsToggleTile(
                  icon: Icons.dark_mode_outlined,
                  label: 'Dark Mode',
                  value: isDark,
                  onChanged: (v) {
                    ref.read(themeModeProvider.notifier).set(
                          v ? ThemeMode.dark : ThemeMode.light,
                        );
                  },
                ),
              ],
            ),

            const SizedBox(height: 28),

            // ─── SUPPORT ─────────────────────────────────────
            _SectionHeader(label: 'SUPPORT'),
            const SizedBox(height: 10),
            _SettingsGroup(
              children: [
                _SettingsTile(
                  icon: Icons.info_outline_rounded,
                  label: 'About App',
                  onTap: () {
                    showDialog(
                      context: context,
                      builder: (dialogCtx) => AlertDialog(
                        title: const Text('Meow Agent'),
                        content: const Text(
                          'Android-native agentic AI.\n'
                          'Modular, permission-aware, and BYOK.\n\n'
                          'Version 0.1.0',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(dialogCtx),
                            child: const Text('Close'),
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
