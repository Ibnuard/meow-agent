import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../app/theme.dart';
import '../../../app/theme_mode_provider.dart';
import '../../../app/widgets/widgets.dart';
import '../data/app_language_provider.dart';
import '../data/llm_debug_provider.dart';
import '../data/notification_sound_provider.dart';
import '../data/profile_backup_service.dart';
import '../../chat/data/chat_notification_service.dart';

import '../../providers/data/provider_repository.dart';
import '../../agents/data/agent_repository.dart';
import 'profile_import_sheet.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _exporting = false;
  bool _importing = false;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final providersAsync = ref.watch(providerListProvider);
    final themeMode = ref.watch(themeModeProvider);
    final isDark = themeMode == ThemeMode.dark ||
        (themeMode == ThemeMode.system &&
            MediaQuery.platformBrightnessOf(context) == Brightness.dark);
    final appLanguage = ref.watch(appLanguageProvider);
    final strings = AppStrings(resolveLanguageCode(appLanguage));

    return Scaffold(
      appBar: AppBar(title: Text(strings.settings)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
          children: [
            // ─── PREFERENCES (provider mgmt + theme + language) ─────
            _SectionHeader(label: strings.preferences),
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
                _SettingsToggleTile(
                  icon: Icons.dark_mode_outlined,
                  label: strings.darkMode,
                  value: isDark,
                  onChanged: (v) {
                    ref
                        .read(themeModeProvider.notifier)
                        .set(v ? ThemeMode.dark : ThemeMode.light);
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
                  onTap: () =>
                      _showLanguageSheet(context, ref, appLanguage, strings),
                ),
                _SettingsTile(
                  icon: Icons.volume_up_rounded,
                  label: strings.notificationSound,
                  trailing: Text(
                    ref.watch(notificationSoundProvider).label,
                    style: TextStyle(
                      fontSize: 13,
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onTap: () =>
                      _showSoundSheet(context, ref, strings),
                ),
              ],
            ),

            const SizedBox(height: 28),

            // ─── PROFILE (backup & restore) ─────────────────────
            _SectionHeader(label: strings.profileSection),
            const SizedBox(height: 10),
            _SettingsGroup(
              children: [
                _SettingsTile(
                  icon: Icons.upload_rounded,
                  label: strings.exportProfile,
                  trailing: _exporting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : null,
                  onTap: _exporting ? null : () => _handleExport(strings),
                ),
                _SettingsTile(
                  icon: Icons.download_rounded,
                  label: strings.importProfile,
                  trailing: _importing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : null,
                  onTap: _importing ? null : () => _handleImport(strings),
                ),
              ],
            ),

            const SizedBox(height: 28),

            // ─── OTHERS (developer + support) ─────────────────
            _SectionHeader(label: strings.others),
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
                _SettingsTile(
                  icon: Icons.info_outline_rounded,
                  label: strings.aboutApp,
                  onTap: () {
                    showDialog(
                      context: context,
                      builder: (dialogCtx) => AlertDialog(
                        contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(18),
                              child: Image.asset(
                                'assets/images/meow.png',
                                width: 64,
                                height: 64,
                                fit: BoxFit.cover,
                              ),
                            ),
                            const SizedBox(height: 14),
                            Text(
                              strings.aboutTitle,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              strings.aboutBody,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 13,
                                color: Theme.of(dialogCtx)
                                    .colorScheme
                                    .onSurfaceVariant,
                                height: 1.5,
                              ),
                            ),
                          ],
                        ),
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
                _SettingsTile(
                  icon: Icons.terminal_rounded,
                  label: 'Shizuku Automation Test',
                  onTap: () => context.push(AppRoutes.shizukuTest),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showLanguageSheet(
    BuildContext context,
    WidgetRef ref,
    AppLanguage current,
    AppStrings strings,
  ) async {
    final selected = await MeowDropdown.showSheet<AppLanguage>(
      context,
      title: strings.language,
      subtitle: strings.languageDescription,
      selectedValue: current,
      searchable: false,
      useRootNavigator: true,
      options: AppLanguage.values
          .map(
            (language) => MeowDropdownOption<AppLanguage>(
              value: language,
              label: language.label,
              prefix: _LanguageOptionIcon(language: language),
            ),
          )
          .toList(),
    );

    if (selected != null) {
      await ref.read(appLanguageProvider.notifier).set(selected);
    }
  }

  Future<void> _showSoundSheet(
    BuildContext context,
    WidgetRef ref,
    AppStrings strings,
  ) async {
    final current = ref.read(notificationSoundProvider);
    final selected = await MeowDropdown.showSheet<NotificationSound>(
      context,
      title: strings.notificationSound,
      subtitle: strings.notificationSoundDesc,
      selectedValue: current,
      searchable: false,
      useRootNavigator: true,
      options: NotificationSound.values
          .map(
            (sound) => MeowDropdownOption<NotificationSound>(
              value: sound,
              label: sound.label,
              prefix: Icon(
                sound == NotificationSound.cat
                    ? Icons.pets_rounded
                    : Icons.notifications_rounded,
                size: 18,
                color: Theme.of(context).colorScheme.primary,
              ),
              suffix: IconButton(
                icon: Icon(
                  Icons.play_circle_outline_rounded,
                  size: 22,
                  color: Theme.of(context).colorScheme.primary,
                ),
                onPressed: () => _previewSound(sound),
                tooltip: 'Preview',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              ),
            ),
          )
          .toList(),
    );

    if (selected != null) {
      await ref.read(notificationSoundProvider.notifier).set(selected);
    }
  }

  Future<void> _previewSound(NotificationSound sound) async {
    await ChatNotificationService.instance.show(
      agentId: '__preview__',
      agentName: 'Meow Agent',
      preview: sound == NotificationSound.cat
          ? 'Meow! \u{1F431}'
          : 'This is a notification preview.',
      soundFileName: sound.fileName,
    );
  }

  // ─── Profile Export ──────────────────────────────────────────────────────

  Future<void> _handleExport(AppStrings s) async {
    setState(() => _exporting = true);
    try {
      final service = ref.read(profileBackupServiceProvider);
      final snapshot = await service.buildSnapshot();
      final jsonStr = ProfileBackupService.encodeSnapshot(snapshot);
      final bytes = utf8.encode(jsonStr);

      final now = DateTime.now();
      final datePart =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final result = await FilePicker.platform.saveFile(
        dialogTitle: s.exportProfile,
        fileName: 'meow-profile-$datePart.json',
        bytes: bytes,
      );

      if (!mounted) return;
      if (result != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.profileExportSuccess)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.profileExportFailed)),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // ─── Profile Import ──────────────────────────────────────────────────────

  Future<void> _handleImport(AppStrings s) async {
    setState(() => _importing = true);
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );
      if (picked == null || picked.files.isEmpty) return;

      final bytes = picked.files.first.bytes;
      if (bytes == null) return;
      final jsonStr = utf8.decode(bytes);
      final snapshot = ProfileBackupService.decodeSnapshot(jsonStr);
      if (snapshot == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(s.profileImportInvalidFile)),
          );
        }
        return;
      }

      final service = ref.read(profileBackupServiceProvider);
      final preview = await service.validate(snapshot);
      if (!preview.isValid) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(s.profileImportInvalidFile)),
          );
        }
        return;
      }

      if (!mounted) return;
      final mode = await ProfileImportSheet.show(
        context,
        preview: preview,
        strings: s,
      );
      if (mode == null) return; // User dismissed.

      final stats = await service.apply(snapshot, mode: mode);

      // Refresh providers and agent lists.
      await ref.read(providerListProvider.notifier).load();
      await ref.read(agentListProvider.notifier).reload();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              s.profileImportSuccess(stats.agentsAdded, stats.providersAdded),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.profileImportInvalidFile)),
        );
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }
}

class _LanguageOptionIcon extends StatelessWidget {
  const _LanguageOptionIcon({required this.language});

  final AppLanguage language;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final icon = switch (language) {
      AppLanguage.system => Icons.phone_android_rounded,
      AppLanguage.id => Icons.translate_rounded,
      AppLanguage.en => Icons.language_rounded,
    };

    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Icon(icon, size: 16, color: cs.primary),
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
        child: SizedBox(
          height: 52,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(icon, size: 19, color: cs.onSurfaceVariant),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: cs.onSurface,
                    ),
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 8), trailing!],
                const SizedBox(width: 4),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 19,
                  color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                ),
              ],
            ),
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
    return InkWell(
      onTap: () => onChanged(!value),
      child: SizedBox(
        height: 52,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Icon(icon, size: 19, color: cs.onSurfaceVariant),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: cs.onSurface,
                  ),
                ),
              ),
              SizedBox(
                width: 44,
                height: 30,
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: Switch.adaptive(
                    value: value,
                    onChanged: onChanged,
                    activeTrackColor: cs.primary,
                    activeThumbColor: cs.onPrimary,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
