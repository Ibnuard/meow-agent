import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/responsive.dart';
import 'app/router.dart';
import 'app/theme.dart';
import 'app/theme_mode_provider.dart';
import 'core/storage/app_settings_repository.dart';
import 'core/storage/legacy_migration.dart';
import 'core/storage/local_storage_service.dart';
import 'core/storage/meow_database.dart';
import 'core/storage/module_entry_repository.dart';
import 'features/agents/data/agent_repository.dart';
import 'features/chat/data/chat_history_service.dart';
import 'features/chat/presentation/chat_screen.dart';
import 'features/modules/presentation/permission_reconciler.dart';
import 'features/modules/data/share_intent_service.dart';
import 'features/modules/workflows/workflow_event_listener.dart';
import 'features/modules/workflows/workflow_foreground_service.dart';
import 'features/modules/workflows/workflow_log_detail_screen.dart';
import 'features/modules/workflows/workflow_notification_service.dart';
import 'features/modules/workflows/workflow_repository.dart';
import 'features/modules/workflows/workflow_runner.dart';
import 'features/modules/workflows/workflow_scheduler.dart';
import 'features/settings/data/app_language_provider.dart';
import 'services/bubble/bubble_chat_service.dart';
import 'features/chat/data/chat_notification_service.dart';
import 'features/chat/data/chat_runtime_manager.dart';
import 'services/permission/permission_observer.dart';
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

  // Lock to portrait orientation only.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  final prefs = await SharedPreferences.getInstance();

  // Pre-warm the SQLite core DB so AgentListNotifier and ProviderListNotifier
  // can populate their state in the background while the first frame renders.
  // Without this, chat could open before the async _load() completes, causing
  // "provider not found" errors and missing history.
  final db = MeowDatabase.instance;
  await db.database;

  // One-shot legacy migration: pull prefs + modules from SharedPreferences
  // into SQLite. Runs before the prefs preload so first-time upgraders
  // see their correct theme/language on the first frame.
  final settingsRepo = AppSettingsRepository(db);
  final moduleEntryRepo = ModuleEntryRepository(db);
  await LegacyMigration.runOnce(
    prefs: prefs,
    settings: settingsRepo,
    modules: moduleEntryRepo,
  );

  // Pre-load all prefs from app_settings so that LocalStorageService and the
  // theme/language providers can initialize synchronously on the first frame.
  final allSettings = await settingsRepo.getAll();
  final localStorageService = LocalStorageService(settingsRepo, allSettings);

  final initialTheme = allSettings['prefs.theme'] ?? 'system';
  final initialLang = allSettings['prefs.language'] ?? 'system';
  final initialActiveAgentId = allSettings['active.agent_id'];

  runApp(
    ProviderScope(
      overrides: [
        localStorageProvider.overrideWithValue(localStorageService),
        initialThemeModeProvider.overrideWithValue(initialTheme),
        initialAppLanguageProvider.overrideWithValue(initialLang),
        initialActiveAgentIdProvider.overrideWithValue(initialActiveAgentId),
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

    // Activate lifecycle-aware permission observer.
    ref.read(permissionObserverProvider);
    // Activate cross-module permission auto-OFF reconciler.
    ref.read(modulePermissionReconcilerProvider);

    // Listen for incoming shared text pushed from native side.
    _channel.setMethodCallHandler(_handleNativeCall);

    // Check for shared text after first frame (cold start from intent).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkSharedText();
      _runWorkspaceMigration();
      _initWorkflowServices();
      _prewarmChatDatabase();
      _initBubbleChat();
    });
  }

  /// Open the chat history SQLite DB in the background so the first chat
  /// open isn't blocked by the platform-channel cost of openDatabase.
  Future<void> _prewarmChatDatabase() async {
    try {
      // Cheap query that forces lazy `_database` getter to initialize.
      await ref.read(chatHistoryServiceProvider).count('__warmup__');
    } catch (_) {
      // Non-fatal — the DB will open on first real use anyway.
    }
  }

  /// Migrate workspace files from internal to external Documents (one-time).
  Future<void> _runWorkspaceMigration() async {
    try {
      final repo = ref.read(agentRepositoryProvider);
      final agents = await repo.loadAll();
      await WorkspaceMigrationService.migrate(
        agents.map((a) => (id: a.id, name: a.name)).toList(),
      );
      // Workspace folders are now created lazily by WorkspaceFolderService
      // on first access; no need for an explicit sync step.
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
      // Share the workflow plugin with chat notifications to avoid callback
      // conflicts (Android only registers the last initialize callback).
      await ChatNotificationService.instance.ensureConfirmationChannel();
      await WorkflowScheduler.initialize();
      await WorkflowScheduler.rescheduleAll();
      // Start the in-app workflow runner with dynamic scheduling.
      ref.read(workflowRunnerProvider).start();
      // Start event listener for battery, charging, WiFi triggers.
      ref.read(workflowEventListenerProvider).start();
      // L1: Start persistent foreground service if workflows are enabled.
      await WorkflowForegroundService.ensureSchedulerRunning();
      // L2: Register WorkManager keep-alive fallback (restarts service if killed).
      await WorkflowScheduler.registerKeepAlive();
    } catch (_) {
      // Non-fatal.
    }
  }

  /// Initialize bubble chat bridge (overlay → LLM → overlay response).
  void _initBubbleChat() {
    BubbleChatService(ref).init();
  }

  /// Handle notification tap — navigate to workflow log detail or chat,
  /// or handle confirmation action buttons.
  void _handleNotificationTap(NotificationResponse response) async {
    final payload = response.payload;
    if (payload == null) return;

    // Confirmation action buttons: "confirm:<agentId>"
    if (payload.startsWith('confirm:')) {
      final agentId = payload.replaceFirst('confirm:', '');
      if (agentId.isEmpty) return;
      final actionId = response.actionId;
      if (actionId == null || actionId.isEmpty) {
        // Tapped notification body — navigate to chat.
        final router = ref.read(goRouterProvider);
        router.go('/agents/$agentId/chat');
        return;
      }
      final manager = ref.read(chatRuntimeManagerProvider);
      switch (actionId) {
        case ChatNotificationService.actionAccept:
          manager.confirm(agentId);
          break;
        case ChatNotificationService.actionAlways:
          manager.confirm(agentId, alwaysApprove: true);
          break;
        case ChatNotificationService.actionReject:
          manager.reject(agentId);
          break;
      }
      return;
    }

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
    debugPrint(
      '[MeowAgent] Native call: ${call.method}, args=${call.arguments}',
    );
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
      builder: (context, child) {
        // Clamp text scale so extreme accessibility settings don't break
        // fixed-layout widgets (chat bubbles, dock, cards).
        return MediaQuery(
          data: Responsive.clampTextScale(MediaQuery.of(context)),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
