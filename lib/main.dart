import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/router.dart';
import 'app/theme.dart';
import 'app/theme_mode_provider.dart';
import 'core/storage/local_storage_service.dart';
import 'features/agents/data/agent_repository.dart';
import 'features/chat/data/chat_notification_service.dart';
import 'features/modules/data/share_intent_service.dart';
import 'features/modules/workflows/workflow_event_listener.dart';
import 'features/modules/workflows/workflow_log_detail_screen.dart';
import 'features/modules/workflows/workflow_notification_service.dart';
import 'features/modules/workflows/workflow_repository.dart';
import 'features/modules/workflows/workflow_runner.dart';
import 'features/modules/workflows/workflow_scheduler.dart';
import 'services/workspace/workspace_migration_service.dart';

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
  static const _channel = MethodChannel('com.meowagent/share');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Listen for incoming shared text pushed from native side.
    _channel.setMethodCallHandler(_handleNativeCall);

    // Check for shared text after first frame (cold start from intent).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkSharedText();
      _runWorkspaceMigration();
      _initWorkflowServices();
    });
  }

  /// Migrate workspace files from internal to external Documents (one-time).
  Future<void> _runWorkspaceMigration() async {
    try {
      final repo = ref.read(agentRepositoryProvider);
      final agents = repo.loadAll();
      await WorkspaceMigrationService.migrate(
        agents.map((a) => (id: a.id, name: a.name)).toList(),
      );
      // Also sync workspaces for any agents missing external workspace.
      await repo.syncWorkspaces();
    } catch (_) {
      // Non-fatal — migration can retry next launch.
    }
  }

  /// Initialize workflow notification service and reschedule active workflows.
  Future<void> _initWorkflowServices() async {
    try {
      await WorkflowNotificationService.initialize(
        onTap: _handleNotificationTap,
      );
      ChatNotificationService.instance.ensureChannel();
      await WorkflowScheduler.initialize();
      await WorkflowScheduler.rescheduleAll();
      // Start the in-app workflow runner with dynamic scheduling.
      ref.read(workflowRunnerProvider).start();
      // Start event listener for battery, charging, WiFi triggers.
      ref.read(workflowEventListenerProvider).start();
    } catch (_) {
      // Non-fatal.
    }
  }

  /// Handle notification tap — navigate to workflow log detail or chat.
  void _handleNotificationTap(NotificationResponse response) async {
    final payload = response.payload;
    if (payload == null) return;

    // Chat notification: "chat:<agentId>"
    if (payload.startsWith('chat:')) {
      final agentId = payload.replaceFirst('chat:', '');
      if (agentId.isEmpty) return;
      final router = ref.read(goRouterProvider);
      router.go('/agents/$agentId/chat');
      return;
    }

    // Workflow notification: "workflow:<workflowId>"
    if (!payload.startsWith('workflow:')) return;

    final workflowId = payload.replaceFirst('workflow:', '');
    if (workflowId.isEmpty) return;

    // Load the latest execution for this workflow.
    final repo = WorkflowRepository();
    final execution = await repo.getLatestForWorkflow(workflowId);
    if (execution == null) return;

    // Navigate using the global navigator key.
    final nav = rootNavigatorKey.currentState;
    if (nav == null) return;
    nav.push(
      MaterialPageRoute(
        builder: (_) => WorkflowLogDetailScreen(execution: execution),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkSharedText();
    }
  }

  /// Handle method calls FROM native (when new intent arrives while running).
  Future<dynamic> _handleNativeCall(MethodCall call) async {
    debugPrint('[MeowAgent] Native call: ${call.method}, args=${call.arguments}');
    if (call.method == 'onSharedText') {
      final text = call.arguments as String?;
      if (text != null && text.isNotEmpty) {
        debugPrint('[MeowAgent] Navigating with text length=${text.length}');
        _navigateToProcess(text);
      }
    }
  }

  Future<void> _checkSharedText() async {
    final service = ref.read(shareIntentServiceProvider);
    final text = await service.getSharedText();
    debugPrint('[MeowAgent] _checkSharedText returned length=${text?.length}');
    if (text != null && text.isNotEmpty) {
      _navigateToProcess(text);
    }
  }

  void _navigateToProcess(String text) {
    debugPrint('[MeowAgent] _navigateToProcess called');
    final router = ref.read(goRouterProvider);
    router.push(
      '${AppRoutes.clipboardProcess}?text=${Uri.encodeComponent(text)}',
    );
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
