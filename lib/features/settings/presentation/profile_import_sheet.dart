import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../app/widgets/meow_button.dart';
import '../../../app/widgets/meow_confirm_dialog.dart';
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
      isScrollControlled: true,
      useSafeArea: true,
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
    // Account for the floating bottom dock + system gesture area.
    final bottomInset = MediaQuery.of(context).viewPadding.bottom + 140;
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 12, 20, 24 + bottomInset),
        child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle bar.
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: cs.onSurfaceVariant.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 18),

          // Title.
          Text(
            s.profileImportPreviewTitle,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 10),

          // Summary.
          Text(
            s.profileImportPreviewSummary(preview.agents, preview.providers),
            style: TextStyle(
              fontSize: 13,
              color: cs.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 6),

          // API key note.
          Text(
            s.profileImportNoApiKey,
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurfaceVariant.withValues(alpha: 0.7),
              fontStyle: FontStyle.italic,
              height: 1.4,
            ),
          ),

          // Warnings.
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
                      (w) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          s.profileImportSkipped(
                            w,
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

          const SizedBox(height: 18),

          // Mode selector.
          _buildModeOption(
            cs: cs,
            mode: ProfileImportMode.merge,
            label: s.profileImportMerge,
            description: s.profileImportMergeDesc,
          ),
          const SizedBox(height: 8),
          _buildModeOption(
            cs: cs,
            mode: ProfileImportMode.replace,
            label: s.profileImportReplace,
            description: s.profileImportReplaceDesc,
          ),

          const SizedBox(height: 20),

          // Confirm button.
          SizedBox(
            width: double.infinity,
            child: MeowPrimaryButton(
              label: s.profileImportButtonImport,
              onPressed: _onConfirm,
            ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildModeOption({
    required ColorScheme cs,
    required ProfileImportMode mode,
    required String label,
    required String description,
  }) {
    final selected = _mode == mode;
    return GestureDetector(
      onTap: () => setState(() => _mode = mode),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected
              ? cs.primary.withValues(alpha: 0.08)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? cs.primary.withValues(alpha: 0.5)
                : cs.onSurfaceVariant.withValues(alpha: 0.2),
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_off_rounded,
              size: 20,
              color: selected ? cs.primary : cs.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: 11,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onConfirm() async {
    if (_mode == ProfileImportMode.replace) {
      final confirmed = await showMeowConfirmDialog(
        context,
        isId: s.isId,
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
