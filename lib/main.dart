import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/router.dart';
import 'app/theme.dart';
import 'app/theme_mode_provider.dart';
import 'core/storage/local_storage_service.dart';
import 'features/modules/data/share_intent_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Edge-to-edge: body extends behind the system bars. The shell adds
  // additive padding over MediaQuery.viewPadding.bottom so nothing
  // collides with the gesture area.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarContrastEnforced: false,
    ),
  );

  final prefs = await SharedPreferences.getInstance();

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
      child: const MeowAgentApp(),
    ),
  );
}

class MeowAgentApp extends ConsumerStatefulWidget {
  const MeowAgentApp({super.key});

  @override
  ConsumerState<MeowAgentApp> createState() => _MeowAgentAppState();
}

class _MeowAgentAppState extends ConsumerState<MeowAgentApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Check for shared text after first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkSharedText());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Check again when app resumes (e.g., from share intent while running).
    if (state == AppLifecycleState.resumed) {
      _checkSharedText();
    }
  }

  Future<void> _checkSharedText() async {
    final service = ref.read(shareIntentServiceProvider);
    final text = await service.getSharedText();
    if (text != null && text.isNotEmpty) {
      final router = ref.read(goRouterProvider);
      router.push(
        '${AppRoutes.clipboardProcess}?text=${Uri.encodeComponent(text)}',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(goRouterProvider);
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp.router(
      title: 'Meow Agent',
      debugShowCheckedModeBanner: false,
      theme: MeowTheme.light(),
      darkTheme: MeowTheme.dark(),
      themeMode: themeMode,
      routerConfig: router,
    );
  }
}
