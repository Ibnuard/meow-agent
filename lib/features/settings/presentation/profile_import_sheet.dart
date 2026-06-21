import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../app/widgets/meow_button.dart';
import '../../../app/widgets/meow_confirm_dialog.dart';
import '../../../app/widgets/meow_sheet.dart';
import '../../settings/data/app_language_provider.dart';
import '../data/profile_backup_service.dart';

/// Modal bottom sheet shown after the user picks a profile JSON file.
/// Displays a preview (agent/provider counts), warnings, mode selector,
/// and confirm button.
///
/// Returns the selected [ProfileImportMode] when the user taps Import,
/// or null if dismissed/cancelled.
class ProfileImportSheet extends StatefulWidget {
  const ProfileImportSheet({
    super.key,
    required this.preview,
    required this.strings,
  });

  final ProfileImportPreview preview;
  final AppStrings strings;

  /// Show the import bottom sheet. Returns the selected mode, or null.
  static Future<ProfileImportMode?> show(
    BuildContext context, {
    required ProfileImportPreview preview,
    required AppStrings strings,
  }) {
    return showModalBottomSheet<ProfileImportMode>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: false,
      backgroundColor: Colors.transparent,
      builder: (_) => ProfileImportSheet(preview: preview, strings: strings),
    );
  }

  @override
  State<ProfileImportSheet> createState() => _ProfileImportSheetState();
}

class _ProfileImportSheetState extends State<ProfileImportSheet> {
  ProfileImportMode _mode = ProfileImportMode.merge;

  AppStrings get s => widget.strings;
  ProfileImportPreview get preview => widget.preview;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;

    return MeowSheet(
      title: s.profileImportPreviewTitle,
      subtitle: s.profileImportPreviewSummary(
        preview.agents,
        preview.providers,
      ),
      onClose: () => Navigator.pop(context),
      maxHeightFactor: 0.85,
      footer: MeowPrimaryButton(
        label: s.profileImportButtonImport,
        onPressed: _onConfirm,
      ),
      children: [
        Text(
          s.profileImportNoApiKey,
          style: TextStyle(
            fontSize: 12,
            color: cs.onSurfaceVariant.withValues(alpha: 0.7),
            fontStyle: FontStyle.italic,
            height: 1.4,
          ),
        ),
        if (preview.warnings.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.error.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: cs.error.withValues(alpha: 0.2)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: preview.warnings
                  .map(
                    (warning) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        s.profileImportSkipped(
                          warning,
                          s.profileImportReasonOrphanProvider,
                        ),
                        style: TextStyle(fontSize: 12, color: cs.error),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
        const SizedBox(height: 16),
        _buildModeOption(
          cs: cs,
          mode: ProfileImportMode.merge,
          icon: Icons.merge_rounded,
          label: s.profileImportMerge,
          description: s.profileImportMergeDesc,
        ),
        const SizedBox(height: 6),
        _buildModeOption(
          cs: cs,
          mode: ProfileImportMode.replace,
          icon: Icons.swap_horiz_rounded,
          label: s.profileImportReplace,
          description: s.profileImportReplaceDesc,
        ),
      ],
    );
  }

  Widget _buildModeOption({
    required ColorScheme cs,
    required ProfileImportMode mode,
    required IconData icon,
    required String label,
    required String description,
  }) {
    final selected = _mode == mode;
    return Material(
      color: selected ? cs.primary.withValues(alpha: 0.10) : Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: () => setState(() => _mode = mode),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(icon, size: 16, color: cs.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: selected
                            ? FontWeight.w800
                            : FontWeight.w600,
                        color: selected ? cs.primary : cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      description,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected) ...[
                const SizedBox(width: 10),
                Icon(Icons.check_rounded, size: 18, color: cs.primary),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _onConfirm() async {
    if (_mode == ProfileImportMode.replace) {
      final confirmed = await showMeowConfirmDialog(
        context,
        strings: s,
        title: s.profileImportReplaceConfirmTitle,
        message: s.profileImportReplaceConfirmBody,
        confirmLabel: s.profileImportReplace,
        cancelLabel: s.cancel,
        icon: Icons.warning_rounded,
        destructive: true,
      );
      if (!confirmed) return;
    }
    if (mounted) {
      Navigator.pop(context, _mode);
    }
  }
}
