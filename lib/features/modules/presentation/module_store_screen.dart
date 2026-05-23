import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
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

    return Scaffold(
      appBar: AppBar(title: const Text('Module Store')),
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
                        module.description,
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
                          'Installed',
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
                                content:
                                    Text('${module.name} installed.'),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                            context.pop();
                          }
                        },
                        child: const Text('Install'),
                      ),
              ],
            ),
          );
        },
      ),
    );
  }
}
