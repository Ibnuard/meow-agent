import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../settings/data/app_language_provider.dart';
import '../data/module_model.dart';
import '../data/module_repository.dart';

/// Screen showing available modules to install.
class ModuleStoreScreen extends ConsumerWidget {
  const ModuleStoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = context.cs;
    final extras = context.extras;
    final installed = ref.watch(installedModulesProvider).value ?? [];
    final installedIds = installed.map((m) => m.id).toSet();
    final langPref = ref.watch(appLanguageProvider);
    final s = AppStrings(resolveLanguageCode(langPref));

    return Scaffold(
      appBar: AppBar(title: Text(s.moduleStore)),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: ModuleRegistry.available.length,
        itemBuilder: (context, i) {
          final module = ModuleRegistry.available[i];
          final isInstalled = installedIds.contains(module.id);

          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: extras.card,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: extras.subtleBorder),
            ),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    module.icon,
                    style: const TextStyle(fontSize: 24),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        module.name,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: cs.onSurface,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _moduleDescription(module, s),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                isInstalled
                    ? Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: cs.primary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          s.installed,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: cs.primary,
                          ),
                        ),
                      )
                    : TextButton(
                        onPressed: () async {
                          await ref
                              .read(moduleRepositoryProvider)
                              .install(module);
                          ref.invalidate(installedModulesProvider);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(s.moduleInstalled(module.name)),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                            context.pop();
                          }
                        },
                        child: Text(s.install),
                      ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _moduleDescription(ModuleModel module, AppStrings s) {
    if (!s.isId) return module.description;
    switch (module.id) {
      case 'clipboard_ai':
        return 'Proses teks dari clipboard dengan AI. Terjemahkan, rangkum, tulis ulang, atau jelaskan teks apapun.';
      case 'app_control':
        return 'Biarkan AI membuka aplikasi, URL, dan pengaturan sistem atas nama kamu.';
      case 'device_context':
        return 'Biarkan agen membaca baterai, jaringan, penyimpanan, waktu, locale, DND, dan lainnya.';
      case 'notification_intelligence':
        return 'Biarkan agen membaca dan merangkum notifikasi Android. Hanya baca — tidak membalas otomatis.';
      case 'notes':
        return 'Buat dan kelola catatan markdown untuk kamu dan agenmu. Lapisan memori lokal yang persisten.';
      default:
        return module.description;
    }
  }
}

