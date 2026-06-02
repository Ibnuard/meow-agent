import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../settings/data/app_language_provider.dart';
import '../data/module_model.dart';
import '../data/module_repository.dart';
import 'module_visuals.dart';

/// Screen showing available modules to install.
class ModuleStoreScreen extends ConsumerWidget {
  const ModuleStoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = context.cs;
    final extras = context.extras;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final installed = ref.watch(installedModulesProvider).value ?? [];
    final installedIds = installed.map((m) => m.id).toSet();
    final langPref = ref.watch(appLanguageProvider);
    final s = AppStrings(resolveLanguageCode(langPref));

    return Scaffold(
      backgroundColor: isDark ? cs.surface : const Color(0xFFFBFCFE),
      appBar: AppBar(title: Text(s.moduleStore)),
      body: ListView.builder(
        padding: EdgeInsets.fromLTRB(
          18,
          12,
          18,
          24 + MediaQuery.of(context).padding.bottom,
        ),
        itemCount: ModuleRegistry.available.length,
        itemBuilder: (context, i) {
          final module = ModuleRegistry.available[i];
          final isInstalled = installedIds.contains(module.id);

          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(24),
              child: Ink(
                decoration: BoxDecoration(
                  color: isDark ? extras.card : const Color(0xFFF4F7FB),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: isDark
                        ? extras.subtleBorder
                        : const Color(0xFFEAF0F8),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      ModuleIconBadge(
                        moduleId: module.id,
                        size: 50,
                        iconSize: 23,
                        radius: 17,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              module.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                color: cs.onSurface,
                                height: 1.1,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              _moduleDescription(module, s),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: cs.onSurfaceVariant,
                                height: 1.25,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      isInstalled
                          ? _StatusPill(label: s.installed)
                          : TextButton(
                              onPressed: () async {
                                await ref
                                    .read(moduleRepositoryProvider)
                                    .install(module);
                                ref.invalidate(installedModulesProvider);
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        s.moduleInstalled(module.name),
                                      ),
                                      duration: const Duration(seconds: 2),
                                    ),
                                  );
                                  context.pop();
                                }
                              },
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
                              child: Text(s.install),
                            ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  String _moduleDescription(ModuleModel module, AppStrings s) {
    switch (module.id) {
      case 'clipboard_ai':
        return s.moduleDescClipboard;
      case 'app_control':
        return s.moduleDescAppControl;
      case 'device_context':
        return s.moduleDescDeviceContext;
      case 'notification_intelligence':
        return s.moduleDescNotification;
      case 'notes':
        return s.moduleDescNotes;
      case 'files':
        return s.moduleDescFiles;
      case 'calendar':
        return s.moduleDescCalendar;
      case 'workflows':
        return s.moduleDescWorkflows;
      case 'web':
        return s.moduleDescWeb;
      default:
        return module.description;
    }
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;

    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: cs.primary,
        ),
      ),
    );
  }
}
