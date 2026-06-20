import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/theme.dart';
import '../../../app/widgets/widgets.dart';
import '../../settings/data/app_language_provider.dart';
import '../data/miniapp_model.dart';
import '../data/miniapp_repository.dart';

final _miniAppChangeWatcherProvider = StreamProvider<void>((ref) {
  final repo = ref.watch(miniAppRepositoryProvider);
  return repo.onChange;
});

final miniAppsListProvider = FutureProvider<List<MiniApp>>((ref) async {
  final repo = ref.watch(miniAppRepositoryProvider);
  ref.watch(_miniAppChangeWatcherProvider);
  return repo.listMiniApps();
});

class MiniAppListScreen extends ConsumerWidget {
  const MiniAppListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = context.cs;
    final langPref = ref.watch(appLanguageProvider);
    final s = AppStrings(resolveLanguageCode(langPref));

    final appsAsync = ref.watch(miniAppsListProvider);

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: cs.brightness == Brightness.dark
              ? Brightness.light
              : Brightness.dark,
          statusBarBrightness: cs.brightness == Brightness.dark
              ? Brightness.dark
              : Brightness.light,
        ),
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, color: cs.onSurface, size: 20),
          onPressed: () => context.pop(),
        ),
        title: Text(
          s.miniAppDashboardTitle,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: cs.onSurface,
            letterSpacing: -0.5,
          ),
        ),
        centerTitle: false,
      ),
      body: appsAsync.when(
        loading: () => const Center(
          child: CircularProgressIndicator(),
        ),
        error: (err, stack) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Text(
              s.errorWithMessage(err.toString()),
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.error),
            ),
          ),
        ),
        data: (apps) {
          if (apps.isEmpty) {
            return Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const MeowMascot(
                      size: 120,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      s.miniAppDashboardEmpty,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      s.miniAppDashboardEmptyDesc,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: cs.onSurfaceVariant,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            itemCount: apps.length,
            itemBuilder: (context, index) {
              final app = apps[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: GestureDetector(
                  onTap: () => context.push('/miniapp/run/${app.id}'),
                  child: MeowCard(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: cs.primary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(
                            app.icon ?? '📱',
                            style: const TextStyle(fontSize: 24),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                app.name,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: cs.onSurface,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: Icon(
                            Icons.delete_outline_rounded,
                            color: cs.error.withValues(alpha: 0.8),
                            size: 22,
                          ),
                          onPressed: () async {
                            final confirmed = await showMeowConfirmDialog(
                              context,
                              title: s.miniAppDeleteConfirm,
                              message: s.miniAppDeleteConfirmDesc(app.name),
                              strings: s,
                              destructive: true,
                            );
                            if (confirmed) {
                              final repo = ref.read(miniAppRepositoryProvider);
                              await repo.deleteMiniApp(app.id);
                            }
                          },
                        ),
                        Icon(
                          Icons.arrow_forward_ios_rounded,
                          color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                          size: 16,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
