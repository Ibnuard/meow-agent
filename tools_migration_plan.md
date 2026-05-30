# Meow Agent — Tools Migration Plan (Stage 3b)

## Status

Completed in this migration pass:
- Chat, Notification, App Control, Clipboard, and Device Context tools moved out of `tool_router.dart`.
- `ToolRouter` now derives all tool definitions and dispatch handlers from `runtimeModulePlugins`.
- `ToolCatalog.groups` now derives from the same runtime plugin registry instead of a hand-maintained static map.
- Guard/golden/full test suite passes after migration.

---

## Context
Monolithic `tool_router.dart` (formerly 2499 lines) and static `ToolCatalog.groups` create a sync hazard. Adding a tool required editing multiple files. 
We transitioned to a **Self-Registering Module Plugin Architecture** (Stage 3). 5 modules are successfully migrated (notes, files, calendar, workflow, system).
The remaining modules from this plan have now been migrated, so any agent can execute the full tool surface through module plugins.

---

## Architecture Overview

1. **`ModulePlugin`** (`lib/services/agent_runtime/module_plugin.dart`): Abstract class defining a module's tool definitions, catalog group, capability hints, and a `dispatch` method.
2. **`ModuleRegistry`** (`lib/services/agent_runtime/module_registry.dart`): Collects all plugins and derives `_registry` definitions, `catalogGroups` maps, and reverse lookups at runtime.
3. **`ModuleToolContext`** (`lib/services/agent_runtime/module_plugin.dart`): Injected dependencies (repos, active agent name/id, full tool definitions) rebuilt dynamically per-turn by the router.

---

## Migration Pattern (Step-by-Step)

For each remaining module:

### Step 1: Create the Plugin File
Create `lib/features/modules/<module_name>/<module_name>_module.dart`.
Extend `ModulePlugin`. Define `moduleId`, `catalogGroup`, `capabilityHints` (English-only), and `toolDefinitions` (exact definitions moved from `_staticRegistry`).

### Step 2: Implement the Dispatch Method
Move/wrap the `_executeXxx` handlers.
- **For helper-backed tools (e.g. calendar/notes):** Instantiate the existing helper (e.g., `NotesTools`) inside `dispatch` and delegate.
- **For in-router handlers (e.g. device/notification):** Extract the native/channel method calls from `tool_router.dart` into a new helper service class in the module folder (e.g., `DeviceTools`), then call it from `dispatch`.

### Step 3: Register in ToolRouter
In `lib/services/agent_runtime/tool_router.dart`:
- Import the new `<module_name>_module.dart` file.
- Add the plugin class instance to `_moduleRegistry` (inside `ModuleRegistry([...])`).
- Remove the matching `ToolDefinition` literals from `_staticRegistry`.
- Remove the matching `case` dispatch arms from `_dispatch()`.
- Delete any unused `_executeXxx` methods or private helper instances in `tool_router.dart`.

### Step 4: Run Drift-Guard & Golden Tests
Run the suite to verify compilation and identical behavior:
```bash
flutter test test/module_plugin_test.dart
flutter test test/runtime_golden_test.dart
flutter test
```

---

## Concrete Example: Notes Migration

### 1. `NotesModulePlugin` definition (`lib/features/modules/notes/notes_module.dart`)
```dart
import '../../../services/agent_runtime/module_plugin.dart';
import '../../../services/agent_runtime/runtime_models.dart';
import 'notes_tools.dart';

class NotesModulePlugin extends ModulePlugin {
  const NotesModulePlugin();

  @override
  String get moduleId => 'notes';

  @override
  String get catalogGroup => 'notes';

  @override
  List<String> get capabilityHints => const ['note', 'notes', 'memo'];

  @override
  List<ToolDefinition> get toolDefinitions => const [
    ToolDefinition(
      name: 'notes.create',
      description: 'Create a markdown note.',
      risk: 'safe',
      requiresConfirmation: false,
      inputSchema: {'title': 'string', 'content': 'string'},
      operation: 'create',
      targetEntity: 'note',
      selectorArgs: ['title'],
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'note',
        expectedDataKeys: ['noteId'],
      ),
    ),
    // ...other note defs
  ];

  @override
  Future<ToolExecutionResult> dispatch(ToolCallRequest request, ModuleToolContext ctx) {
    final tools = NotesTools(moduleRepository: ctx.moduleRepository);
    switch (request.name) {
      case 'notes.create':
        return tools.executeCreate(request.args);
      // ...other note arms
      default:
        return Future.value(ToolExecutionResult(
          success: false,
          toolName: request.name,
          error: 'Unsupported tool: ${request.name}',
        ));
    }
  }
}
```

### 2. Registry in `tool_router.dart`
```dart
final ModuleRegistry _moduleRegistry = ModuleRegistry(const [
  NotesModulePlugin(),
  FilesModulePlugin(),
  CalendarModulePlugin(),
  WorkflowModulePlugin(),
  SystemModulePlugin(),
]);
```

---

## Remaining Modules Migrated In This Pass

### 1. Chat Module (1 tool) — DONE
- **Tools:** `chat.send`.
- **Target:** `lib/features/modules/chat/chat_module.dart`.
- **Dispatch action:** Puts message in chat history. Move `_executeChatSend` from router into `ChatModulePlugin`.

### 2. Notification Module (7 tools) — DONE
- **Tools:** `notification.status`, `notification.read_recent`, `notification.summarize`, `notification.classify`, `notification.reply_suggestion`, `notification.open_app`, `notification.create_local`.
- **Target:** `lib/features/modules/notification_intelligence/notification_module.dart`.
- **Dispatch action:** Calls `AgentNotificationService` / `NotificationRepository`. Move `_executeNotificationXxx` helpers from router.

### 3. App & Clipboard Modules (7 tools) — DONE
- **Tools:**
  - `app.resolve`, `app.open`, `app.list_installed`, `settings.open`, `intent.open_url`
  - `clipboard.read`, `clipboard.write`
- **Target:** `lib/features/modules/app_control/app_module.dart` (or separate).
- **Dispatch action:** MethodChannel native calls. Move `_executeAppXxx`, `_executeClipboardXxx`, `_executeOpenSettings`, `_executeOpenUrl` out of router.

### 4. Device Module (16 tools) — DONE
- **Tools:** `device.battery`, `device.network`, `device.storage`, `device.time`, `device.locale`, `device.summary`, `device.foreground_app`, `device.usage_stats`, `device.charging`, `device.dnd`, `device.bluetooth`, `device.dnd.set`, `device.wifi.reconnect`, `device.bluetooth.set`, `device.wifi`, `device.cellular`.
- **Target:** `lib/features/modules/device_context/device_module.dart`.
- **Dispatch action:** Native MethodChannel wrappers. Move `_executeDeviceXxx` methods and the private `_deviceRepo()` helper out of the router.

---

## Verification & Guard Rails

- **Drift Guard** (`test/module_plugin_test.dart`): Automatically runs after any registry change. Asserts that the catalog's tools and the router's active registry are 100% matched. **Any drift or missing plugin tool causes a compile/test failure.**
- **Golden Suite** (`test/runtime_golden_test.dart`): Verifies end-to-end intent, skips, and verification probes.
