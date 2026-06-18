import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/activity/presentation/activity_screen.dart';
import '../features/agents/presentation/agent_list_screen.dart';
import '../features/agents/presentation/agent_manager_screen.dart';
import '../features/chat/presentation/chat_screen.dart';
import '../features/home/presentation/home_screen.dart';
import '../features/modules/presentation/clipboard_process_screen.dart';
import '../features/modules/presentation/module_detail_screen.dart';
import '../features/modules/presentation/module_store_screen.dart';
import '../features/modules/web/presentation/api_store_screen.dart';
import '../features/modules/notes/note_detail_screen.dart';
import '../features/modules/notes/note_editor_screen.dart';
import '../features/modules/notes/notes_list_screen.dart';
import '../features/providers/presentation/add_provider_screen.dart';
import '../features/providers/presentation/provider_list_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import 'shell.dart';

/// Global navigator key for pushing routes from outside the widget tree
/// (e.g., notification tap handlers).
final rootNavigatorKey = GlobalKey<NavigatorState>();

class AppRoutes {
  static const home = '/';
  static const activity = '/activity';
  static const agents = '/agents';
  static const settings = '/settings';
  static const agentChat = '/agents/:id/chat';
  static const addAgent = '/agents/new';
  static const editAgent = '/agents/:id/edit';
  static const addProvider = '/providers/new';
  static const editProvider = '/providers/:id/edit';
  static const providerList = '/providers';
  // Chat with the default agent (used by the featured chat button).
  static const defaultChat = '/chat';
  // Modules.
  static const moduleStore = '/modules/store';
  static const moduleDetail = '/modules/:id';
  static const clipboardProcess = '/modules/clipboard/process';
  // Notes.
  static const notesList = '/notes';
  static const noteDetail = '/notes/:id';
  static const noteNew = '/notes/new';
  static const noteEdit = '/notes/:id/edit';
  static const apiStore = '/modules/api-store';
}

final goRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: AppRoutes.home,
    routes: [
      // Standalone routes (no bottom bar).
      GoRoute(
        path: AppRoutes.addAgent,
        name: 'addAgent',
        builder: (context, state) => const AgentManagerScreen(),
      ),
      GoRoute(
        path: AppRoutes.editAgent,
        name: 'editAgent',
        builder: (context, state) {
          final id = state.pathParameters['id']!;
          return AgentManagerScreen(agentId: id);
        },
      ),
      GoRoute(
        path: AppRoutes.addProvider,
        name: 'addProvider',
        builder: (context, state) => const AddProviderScreen(),
      ),
      GoRoute(
        path: AppRoutes.providerList,
        name: 'providerList',
        builder: (context, state) => const ProviderListScreen(),
      ),
      GoRoute(
        path: AppRoutes.editProvider,
        name: 'editProvider',
        builder: (context, state) {
          final id = state.pathParameters['id']!;
          return AddProviderScreen(providerId: id);
        },
      ),
      GoRoute(
        path: AppRoutes.agentChat,
        name: 'agentChat',
        builder: (context, state) {
          final id = state.pathParameters['id'] ?? 'default';
          final initial = state.uri.queryParameters['initialText'];
          return ChatScreen(agentId: id, initialText: initial);
        },
      ),
      GoRoute(
        path: AppRoutes.defaultChat,
        name: 'defaultChat',
        builder: (context, state) {
          final initial = state.uri.queryParameters['initialText'];
          return ChatScreen(agentId: 'default', initialText: initial);
        },
      ),
      GoRoute(
        path: AppRoutes.moduleStore,
        name: 'moduleStore',
        builder: (context, state) => const ModuleStoreScreen(),
      ),
      GoRoute(
        path: AppRoutes.apiStore,
        name: 'apiStore',
        builder: (context, state) => const ApiStoreScreen(),
      ),
      GoRoute(
        path: AppRoutes.moduleDetail,
        name: 'moduleDetail',
        builder: (context, state) {
          final id = state.pathParameters['id']!;
          return ModuleDetailScreen(moduleId: id);
        },
      ),
      GoRoute(
        path: AppRoutes.clipboardProcess,
        name: 'clipboardProcess',
        builder: (context, state) {
          final text = state.uri.queryParameters['text'] ?? '';
          return ClipboardProcessScreen(inputText: text);
        },
      ),
      GoRoute(
        path: AppRoutes.notesList,
        name: 'notesList',
        builder: (context, state) => const NotesListScreen(),
      ),
      GoRoute(
        path: AppRoutes.noteNew,
        name: 'noteNew',
        builder: (context, state) => const NoteEditorScreen(),
      ),
      GoRoute(
        path: AppRoutes.noteDetail,
        name: 'noteDetail',
        builder: (context, state) {
          final id = state.pathParameters['id']!;
          return NoteDetailScreen(noteId: id);
        },
      ),
      GoRoute(
        path: AppRoutes.noteEdit,
        name: 'noteEdit',
        builder: (context, state) {
          final id = state.pathParameters['id']!;
          return NoteEditorScreen(noteId: id);
        },
      ),

      // Main app shell with bottom navigation.
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(
            path: AppRoutes.home,
            name: 'home',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: HomeScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.activity,
            name: 'activity',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: ActivityScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.agents,
            name: 'agents',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: AgentListScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.settings,
            name: 'settings',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: SettingsScreen(),
            ),
          ),
        ],
      ),
    ],
  );
});
