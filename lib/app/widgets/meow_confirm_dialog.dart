import 'package:flutter/material.dart';

import '../../features/settings/data/app_language_provider.dart';
import '../theme.dart';

/// Show a generic, reusable destructive confirmation dialog.
///
/// Returns `true` if the user confirmed, `false` or `null` otherwise.
///
/// All copy is parameterized so callers can keep their own tone, but defaults
/// are provided that work for 90% of delete flows. Pass `isId` to switch the
/// default labels between Indonesian and English.
Future<bool> showMeowConfirmDialog(
  BuildContext context, {
  String? title,
  String? message,
  String? confirmLabel,
  String? cancelLabel,
  IconData icon = Icons.delete_outline_rounded,
  bool isId = true,
  bool destructive = true,
}) async {
  final cs = Theme.of(context).colorScheme;
  final extras = Theme.of(context).extension<MeowExtras>()!;
  final s = AppStrings(isId ? 'id' : 'en');

  final accent = destructive ? cs.error : cs.primary;
  final resolvedTitle = title ??
      (destructive ? s.confirmDefaultTitle : s.confirmDefaultConfirm);
  final resolvedMessage = message ?? s.confirmDefaultBody;
  final resolvedConfirm = confirmLabel ??
      (destructive ? s.confirmDefaultDelete : s.confirmDefaultContinue);
  final resolvedCancel = cancelLabel ?? s.cancel;

  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      return AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
        contentPadding: const EdgeInsets.fromLTRB(24, 14, 24, 8),
        title: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, size: 18, color: accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                resolvedTitle,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
            ),
          ],
        ),
        content: Text(
          resolvedMessage,
          style: TextStyle(
            fontSize: 13,
            height: 1.45,
            color: cs.onSurfaceVariant,
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            style: TextButton.styleFrom(
              foregroundColor: cs.onSurfaceVariant,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            ),
            child: Text(resolvedCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: accent.withValues(alpha: 0.15),
              foregroundColor: accent,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: accent.withValues(alpha: 0.3)),
              ),
              textStyle: const TextStyle(fontWeight: FontWeight.w700),
            ),
            child: Text(resolvedConfirm),
          ),
        ],
        // Use extras for an even subtler visual line; not strictly needed.
        backgroundColor: cs.brightness == Brightness.dark
            ? const Color(0xFF0F172A)
            : cs.surface,
        surfaceTintColor: Colors.transparent,
        shadowColor: extras.subtleBorder,
      );
    },
  );

  return result == true;
}
