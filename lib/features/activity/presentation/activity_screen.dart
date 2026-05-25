import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../settings/data/app_language_provider.dart';

/// Activity screen — placeholder for the agent's action log / history.
class ActivityScreen extends ConsumerWidget {
  const ActivityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = context.cs;
    final langPref = ref.watch(appLanguageProvider);
    final s = AppStrings(resolveLanguageCode(langPref));

    return Scaffold(
      appBar: AppBar(title: Text(s.activity)),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.history_rounded,
                  size: 44,
                  color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                ),
                const SizedBox(height: 12),
                Text(
                  s.noActivityYet,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  s.activityBody,
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
    );
  }
}
