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
        padding: EdgeInsets.fromLTRB(18, 8, 18, 24 + bottomInset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle bar — matches MeowDropdown sheet (38×4, alpha .24, pill).
            Center(
              child: Container(
                width: 38,
                height: 4,
                margin: const EdgeInsets.only(top: 8),
                decoration: BoxDecoration(
                  color: cs.onSurfaceVariant.withValues(alpha: 0.24),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),

            // Header row: title + subtitle on the left, close button on the
            // right — mirrors the language/notification picker sheet header.
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 12, 0, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.profileImportPreviewTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: cs.onSurface,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          s.profileImportPreviewSummary(
                            preview.agents,
                            preview.providers,
                          ),
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.35,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(
                      Icons.close_rounded,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),

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

            const SizedBox(height: 16),

            // Mode selector — same row styling as the picker-sheet option tile.
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
              // Icon chip — matches _LanguageOptionIcon (30×30, radius 11,
              // primary tint).
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
