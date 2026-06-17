# MODULE.md — Adding a New Module to Meow Agent

> Step-by-step guide to add a feature module end-to-end:
> **Module Store entry → settings screen → tools → permission gate → dispatch
> (Dart-only or native).**
>
> Follow this exactly — the wiring is convention-based, so every step has a
> single correct home. Companion: **[AGENTS_2.md](./AGENTS_2.md)** (rules),
> **[ARCHITECTURE_2.md](./ARCHITECTURE_2.md)** (runtime), **[DESIGN_2.md](./DESIGN_2.md)** (UI).

---

## 0. Mental Model

A "module" is a user-installable feature with:
- a **Store entry** (id, name, description, icon, default setting toggles),
- a **tool surface** (one or more `namespace.action` tools the agent can call),
- a **permission gate** (which toggle / Android permission each tool needs),
- a **dispatch** implementation (Dart-only, or Dart + native Kotlin).

Two things are independent and BOTH matter:

```
ModuleModel (Store)            ModulePlugin (Runtime)
  id, settings toggles    ┌──▶   moduleId, toolDefinitions, dispatch
        │                 │
        └── gated by ──────┘
   tool_permission_requirements.dart  (toolName → moduleId + settingKey)
```

The toggle in the Store is **decorative** until a gate entry connects a tool to
it. Forgetting the gate entry = the tool **fails open** (runs regardless of the
toggle). The coverage test catches this (Step 5).

---

## 1. Define the Store Entry (`ModuleModel`)

File: `lib/features/modules/data/module_model.dart`.

Add a `static const` to `ModuleRegistry`, then add it to the `available` list.

```dart
static const myFeature = ModuleModel(
  id: 'my_feature',                  // stable id — used everywhere as moduleId
  name: 'My Feature',                // shown in Store (also localize, Step 2)
  description: 'One-line of what it does.',
  icon: '✨',                         // emoji or Material icon name
  settings: {                        // toggle keys; ALL default OFF unless safe
    'allow_read': false,
    'allow_write': false,
  },
);

static const List<ModuleModel> available = [
  // ...existing...
  myFeature,                          // ← add here
];
```

Rules:
- `id` is the **moduleId** referenced by the plugin, the gate, and the permission
  maps. Keep it stable; renaming it later breaks gating.
- `module.enabled` defaults ON at install; **every** setting defaults OFF until
  the user opts in (safe reads may default ON, e.g. `allow_battery: true`).
- Settings are `Map<String, bool>` — toggle-only. No free-form values.

---

## 2. Localize the Store + Settings Strings

File: `lib/features/settings/data/app_language_provider.dart`.

The settings screen renders each toggle's label/description by calling
`AppStrings.moduleSetting(moduleId, settingKey)` (`:1696`), which returns an
`(String title, String description)` record. Add a branch for your module:

```dart
(String, String) moduleSetting(String moduleId, String key) => switch (moduleId) {
  // ...existing modules...
  'my_feature' => switch (key) {
    'allow_read' => (
      isId ? 'Izinkan Baca' : 'Allow Read',
      isId ? 'Agen dapat membaca X.' : 'Agent can read X.',
    ),
    'allow_write' => (
      isId ? 'Izinkan Tulis' : 'Allow Write',
      isId ? 'Agen dapat menulis X.' : 'Agent can write X.',
    ),
    _ => (key, ''),
  },
  // ...
};
```

- `isId` lives **only inside `AppStrings`** — that is its one legitimate home.
  Never re-derive it in a screen (see AGENTS_2.md §1).
- Provide both `id` and `en`. A proper-noun term can return the same text for
  both, but it must still go through `AppStrings`.
- If the module groups settings (like `device_context`), also add branches to
  `moduleSettingGroupTitle` / `moduleSettingGroupDescription` (`:1653`).

The settings screen (`module_detail_screen.dart`) auto-renders one toggle per
`module.settings` entry — **no per-module screen code needed**. It reads labels
via `_settingLabels()` (`:1705`) → `moduleSetting()`.

---

## 3. Build the Tool Surface (`ModulePlugin`)

Create `lib/features/modules/my_feature/my_feature_module.dart`. Extend
`ModulePlugin` — this is the ONLY file that defines the tools.

```dart
import '../../../services/agent_runtime/module_plugin.dart';
import '../../../services/agent_runtime/runtime_models.dart';

class MyFeatureModulePlugin extends ModulePlugin {
  const MyFeatureModulePlugin();

  @override String get moduleId => 'my_feature';   // MUST match ModuleModel.id
  @override String get catalogGroup => 'my_feature';

  // English-only hints for tool shortlisting (never a hard gate).
  @override
  List<String> get capabilityHints => const ['my feature', 'do thing'];

  @override
  List<ToolDefinition> get toolDefinitions => const [
    ToolDefinition(
      name: 'my_feature.read',                     // namespace.action, lowercase
      description: 'Read X and return it.',        // English; the LLM reads this
      risk: 'safe',                                // read-only → auto-execute
      requiresConfirmation: false,
      isRetrieval: true,                           // result IS the answer
      inputSchema: {'query': 'string (optional)'},
    ),
    ToolDefinition(
      name: 'my_feature.write',
      description: 'Write X. Use when the user asks to save X.',
      risk: 'sensitive',                           // side effect → confirm card
      requiresConfirmation: true,
      inputSchema: {'value': 'string (required)'},
      operation: 'create',
      targetEntity: 'my_entity',
      selectorArgs: ['value'],
      // Every MUTATING tool MUST have a verificationProbe (AGENTS_2.md §4.6):
      verificationProbe: ToolVerificationProbe(
        kind: 'tool_result_data',
        entityType: 'my_entity',
        expectedDataKeys: ['id', 'value'],
      ),
    ),
  ];

  @override
  Future<ToolExecutionResult> dispatch(
    ToolCallRequest request,
    ModuleToolContext ctx,
  ) async {
    switch (request.name) {
      case 'my_feature.read':
        return _read(request, ctx);
      case 'my_feature.write':
        return _write(request, ctx);
      default:
        return ToolExecutionResult(
          success: false,
          toolName: request.name,
          error: 'MyFeatureModulePlugin cannot handle ${request.name}',
        );
    }
  }

  // Handlers return ToolExecutionResult — NEVER throw across this boundary.
}
```

Then register it (one line) in
`lib/services/agent_runtime/runtime_module_plugins.dart`:

```dart
const List<ModulePlugin> runtimeModulePlugins = [
  // ...existing...
  MyFeatureModulePlugin(),
];
```

That's it for registration — `ModuleRegistry` derives the tool registry, the
catalog group map, and the dispatch index automatically. No central switch.

### Risk levels

| Risk | Behavior |
|------|----------|
| `safe` | read-only → auto-execute |
| `sensitive-lite` | low-risk side effect (toggle/pin/append) → auto-execute |
| `sensitive` | side effect (write/open/create) → confirmation card |
| `dangerous` | destructive/irreversible → confirmation + extra warning |

`risk` / `requiresConfirmation` are authoritative from this definition — the
runtime never trusts the LLM for them.

### What's in `ModuleToolContext`

`dispatch` receives `ctx` with: `agentId`, `agentName`, `moduleRepository`,
core repos (`coreAgentRepo`, `coreProviderRepo`, `coreSoulRepo`,
`coreMemoryRepo`), `secureStorage`, `attachments`, and more — all built fresh
per dispatch so identity stays current. Use these instead of reaching for global
singletons.

---

## 4. Gate the Tools (CRITICAL — prevents fail-open)

A tool absent from the permission map **runs regardless of the toggle**. Wire
each tool to its module + setting.

### 4.1 Runtime gate — `tool_permission_requirements.dart`

Add one entry per tool to `toolPermissionRequirements`:

```dart
'my_feature.read': ToolPermissionRequirement(
  moduleId: 'my_feature',
  settingKey: 'allow_read',
  settingLabel: 'Allow Read',       // human label for denial messages
  actionLabel: 'read X',
),
'my_feature.write': ToolPermissionRequirement(
  moduleId: 'my_feature',
  settingKey: 'allow_write',
  settingLabel: 'Allow Write',
  actionLabel: 'write X',
  androidPermission: PermissionType.storage,   // only if it needs an OS perm
),
```

The policy (`tool_permission_policy.dart`) checks in order:
**module installed → module enabled → setting toggle on → Android perm granted.**
Any failure returns a localized denial with `errorCode:
'module_permission_denied'`.

#### Prefix rule (one toggle gates a whole family)

If you want ONE toggle to govern every `my_feature.*` tool (like `app_agent.*`
does), add a prefix rule to `toolPermissionPrefixRequirements` **instead of**
per-tool entries:

```dart
const toolPermissionPrefixRequirements = <String, ToolPermissionRequirement>{
  'app_agent.': ToolPermissionRequirement(...),
  'my_feature.': ToolPermissionRequirement(           // gates ALL my_feature.*
    moduleId: 'my_feature',
    settingKey: 'allow_all',
    settingLabel: 'My Feature',
    actionLabel: 'use My Feature',
  ),
};
```

Resolution is **exact entry first, then prefix**. New tools in the family are
then covered automatically and can never fail open. Use a prefix rule when "one
switch = allow everything in this module"; use per-tool entries when toggles are
granular.

### 4.2 Android permission sync — `setting_permission_requirements.dart`

ONLY if a setting requires an Android runtime permission. Add to
`settingPermissionRequirements` so the UI gates toggle-ON behind the OS grant
AND the reconciler flips it OFF when the permission is revoked:

```dart
(moduleId: 'my_feature', settingKey: 'allow_write'): PermissionType.storage,
```

This map drives `PermissionGatedToggleHandlerMixin` (requests the OS permission
when the user turns the toggle ON) and `ModulePermissionReconciler` (auto-OFF on
revoke). If your `ToolPermissionRequirement` set an `androidPermission`, you
almost always want the matching entry here too.

> Two maps, two jobs: `toolPermissionRequirements` enforces at **runtime
> (agent call)**; `settingPermissionRequirements` enforces at the **UI toggle**.
> A storage/contacts/etc. tool needs BOTH. An app-level-only toggle (no OS perm)
> needs only the runtime map.

### 4.3 Verify coverage

Run the guard test — it fails if any registered tool is neither gated nor
allowlisted:

```
flutter test test/tool_permission_coverage_test.dart
```

If your tool is intentionally ungated (a pure safe read with no toggle), add it
to the documented `intentionallyUngated` allowlist with a reason. Prefer a real
gate entry.

---

## 5. Implement Dispatch

### 5.1 Dart-only module

Put the logic in the plugin's handlers (or a `my_feature_tools.dart` helper).
Read/write through `ctx` repos or your own service. Return
`ToolExecutionResult`.

```dart
Future<ToolExecutionResult> _read(ToolCallRequest req, ModuleToolContext ctx) async {
  final query = (req.args['query'] ?? '').toString();
  final data = await _doRead(query);            // pure Dart
  return ToolExecutionResult(
    success: true,
    toolName: req.name,
    data: {'results': data},
  );
}
```

### 5.2 Native (Kotlin) module

When you need platform APIs (contacts, telephony, accessibility, etc.), add a
`MethodChannel` and a Kotlin handler.

**Dart side** — a thin service wrapper (`my_feature_service.dart`):

```dart
class MyFeatureService {
  static const _channel = MethodChannel('com.meowagent/my_feature');

  Future<Map<String, dynamic>> doThing(Map<String, dynamic> args) async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('doThing', args);
      return raw ?? const {'success': false, 'message': 'No result.'};
    } on MissingPluginException {
      return const {'success': false, 'message': 'Native not connected yet.'};
    } on PlatformException catch (e) {
      return {'success': false, 'message': e.message ?? 'Request failed.'};
    }
  }
}
```

The plugin's `dispatch` calls this service and wraps the map in a
`ToolExecutionResult`.

**Kotlin side** — `android/.../MyFeaturePlugin.kt`, following the
`CommunicationPlugin` pattern:

```kotlin
class MyFeaturePlugin(private val activity: FlutterActivity) : MethodChannel.MethodCallHandler {
  companion object {
    const val CHANNEL = "com.meowagent/my_feature"
    private const val TAG = "MeowMyFeature"
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    try {
      when (call.method) {
        "doThing" -> doThing(call, result)
        else -> result.notImplemented()
      }
    } catch (e: Exception) {
      Log.e(TAG, "Error in ${call.method}: ${e.message}", e)
      result.error("MY_FEATURE_ERROR", e.message, null)   // never crash
    }
  }
}
```

**Register the channel** in `MainActivity.kt` `configureFlutterEngine`:

```kotlin
MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MyFeaturePlugin.CHANNEL)
    .setMethodCallHandler(MyFeaturePlugin(this))
```

**Native rules** (from AGENTS_2.md §4.5):
1. Always return `Map<String, Any?>`.
2. Always wrap in try/catch — never crash the app.
3. Permission-check in native; return a safe fallback, not a crash.
4. Log with `Log.e(TAG, msg, e)`.
5. Never block the main thread — heavy work async.

**Manifest** — declare any new Android permission in
`android/app/src/main/AndroidManifest.xml`, and make sure `PermissionType`
(`permission_manager.dart`) has the matching variant if it's a runtime grant.

---

## 6. Test

| Test | Why |
|------|-----|
| `flutter test test/tool_permission_coverage_test.dart` | no fail-open / no orphan gate |
| `flutter test test/module_plugin_test.dart` | registry/catalog drift guard |
| `flutter test test/<my_feature>_test.dart` | per-tool unit tests |
| `flutter analyze` | clean |

Minimum per new tool: success path, empty/null input (no crash), permission
missing (safe fallback), registered with correct risk/confirmation metadata,
and a `verificationProbe` for mutating tools.

---

## 7. Checklist

- [ ] `ModuleModel` added to `ModuleRegistry` + `available` list (Step 1).
- [ ] `moduleSetting()` branch added for every toggle, `id` + `en` (Step 2).
- [ ] `MyFeatureModulePlugin` created; `moduleId` matches `ModuleModel.id` (Step 3).
- [ ] Registered in `runtime_module_plugins.dart` (Step 3).
- [ ] Every tool gated in `toolPermissionRequirements` OR by a prefix rule (Step 4.1).
- [ ] Android-perm tools also in `settingPermissionRequirements` (Step 4.2).
- [ ] Mutating tools have a `verificationProbe`.
- [ ] (Native) Kotlin plugin + channel registered in `MainActivity.kt`; manifest
      permission + `PermissionType` variant added.
- [ ] Coverage test, drift guard, unit tests, and `flutter analyze` all pass.
- [ ] No `isId` in any screen; no inline prompt/string outside its home file.

---

## 8. Reference: Files You Touch

| Concern | File |
|---------|------|
| Store entry + toggles | `lib/features/modules/data/module_model.dart` |
| Toggle labels (i18n) | `lib/features/settings/data/app_language_provider.dart` (`moduleSetting`) |
| Settings screen (auto) | `lib/features/modules/presentation/module_detail_screen.dart` — no edit needed |
| Tool surface + dispatch | `lib/features/modules/<id>/<id>_module.dart` |
| Plugin registration | `lib/services/agent_runtime/runtime_module_plugins.dart` |
| Runtime gate | `lib/services/agent_runtime/tool_permission_requirements.dart` |
| UI/OS permission sync | `lib/services/permission/setting_permission_requirements.dart` |
| Permission types | `lib/services/permission/permission_manager.dart` |
| Native handler | `android/app/src/main/kotlin/com/meowagent/meow_agent/<Name>Plugin.kt` |
| Channel registration | `android/app/src/main/kotlin/com/meowagent/meow_agent/MainActivity.kt` |
| Manifest | `android/app/src/main/AndroidManifest.xml` |
