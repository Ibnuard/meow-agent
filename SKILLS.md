# SKILLS.md — Meow Agent Codebase Guide

> Panduan lengkap untuk coding agent agar bisa langsung paham arsitektur, cara nambah tool baru, module baru, handling LLM, dan native code.

---

## Arsitektur Overview

```
lib/
├── main.dart                          # Entry point, Riverpod ProviderScope
├── app/
│   ├── router.dart                    # GoRouter navigation
│   ├── shell.dart                     # App shell + floating dock
│   ├── theme.dart                     # Design system (dark navy theme)
│   └── widgets/                       # Shared UI components
├── core/
│   └── storage/                       # Local storage utilities
├── features/
│   ├── chat/                          # Chat UI + history
│   │   ├── data/                      # ChatHistoryService, ChatMessage model
│   │   └── presentation/             # Chat screen widgets
│   ├── agents/                        # Agent management UI
│   ├── modules/
│   │   ├── data/                      # ModuleModel, ModuleRepository, ModuleRegistry
│   │   ├── device_context/            # Device Context module (models, service, repo)
│   │   └── presentation/             # Module store + detail screens
│   ├── providers/                     # LLM provider config UI
│   ├── settings/                      # App settings
│   ├── home/                          # Home screen
│   └── activity/                      # Activity log
├── services/
│   ├── llm/
│   │   └── openai_compatible_client.dart  # OpenAI-compatible HTTP client (Dio)
│   └── agent_runtime/
│       ├── runtime_engine.dart        # Main agentic loop orchestrator
│       ├── runtime_models.dart        # All data classes (Request, Response, ToolDef, etc.)
│       ├── tool_router.dart           # Tool registry + dispatch + execution
│       ├── planner.dart               # LLM-based intent analysis + plan creation
│       ├── executor.dart              # LLM-based tool selection + review loop
│       ├── context_builder.dart       # Builds prompt context from workspace
│       ├── prompt_templates.dart      # All LLM prompt templates
│       ├── pending_action.dart        # Confirmation flow + keyword checker
│       ├── workspace_loader.dart      # SOUL/MEMORY/SKILL/HEARTBEAT file management
│       ├── app_alias_resolver.dart    # Friendly name → package resolution
│       └── runtime_logger.dart        # Event logging during runtime

android/app/src/main/kotlin/com/meowagent/meow_agent/
├── MainActivity.kt                    # MethodChannel registrations (share, services, app_control, device_context)
├── DeviceContextPlugin.kt             # Native device info (battery, network, storage, time, locale, usage, charging, dnd, bluetooth)
├── ClipboardForegroundService.kt      # Persistent clipboard monitoring service
└── FloatingBubbleService.kt           # Floating bubble overlay service
```

---

## Agentic Runtime Loop

Flow eksekusi saat user kirim pesan:

```
User Message
    │
    ▼
┌─────────────────────┐
│  RuntimeEngine.run() │
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐     ┌──────────────────┐
│  Check Pending Action│────▶│ ConfirmationChecker│ (keyword-based, no LLM)
└─────────┬───────────┘     └──────────────────┘
          │
          ▼
┌─────────────────────┐
│  Planner.analyze()   │  ← LLM call: "requires_tools? intent? risk?"
└─────────┬───────────┘
          │
    ┌─────┴─────┐
    │           │
    ▼           ▼
 No Tools    Tools Required
    │           │
    ▼           ▼
 Direct     ┌──────────────┐
 Response   │ Planner.plan()│  ← LLM call: create step-by-step plan
            └──────┬───────┘
                   │
                   ▼
            ┌──────────────────┐
            │ Execute Loop      │  (max 5 iterations)
            │  ├─ selectTool()  │  ← LLM picks next tool
            │  ├─ validate()    │  ← ToolRouter checks registry
            │  ├─ execute()     │  ← ToolRouter dispatches
            │  └─ review()      │  ← LLM reviews result
            └──────────────────┘
                   │
                   ▼
            Final Response to User
```

---

## Cara Menambah Tool Baru

### Step 1: Register di `tool_router.dart` → `_registry`

```dart
'namespace.tool_name': const ToolDefinition(
  name: 'namespace.tool_name',
  description: 'Deskripsi yang jelas untuk LLM. Ini yang dibaca LLM untuk decide kapan pakai tool ini.',
  risk: 'safe',              // 'safe' | 'sensitive' | 'dangerous'
  requiresConfirmation: false, // true = user harus confirm dulu
  inputSchema: {'arg1': 'string', 'arg2': 'int (optional, default 5)'},
),
```

**Naming convention:** `namespace.action` — contoh: `device.battery`, `app.open`, `clipboard.read`

**Risk levels:**
- `safe` — read-only, no side effects → auto-execute
- `sensitive` — has side effects (open app, write data) → requires confirmation
- `dangerous` — destructive/irreversible → requires confirmation + extra warning

### Step 2: Tambah case di `_dispatch()` switch

```dart
case 'namespace.tool_name':
  return _executeMyNewTool(request.args);
```

### Step 3: Implement execution method

```dart
Future<ToolExecutionResult> _executeMyNewTool(Map<String, dynamic> args) async {
  try {
    // 1. Parse args
    final myArg = args['arg1'] as String? ?? '';
    
    // 2. Execute logic (call native, call service, etc.)
    final result = await someService.doThing(myArg);
    
    // 3. Return success
    return ToolExecutionResult(
      success: true,
      toolName: 'namespace.tool_name',
      data: {'key': result},  // Data ini dikirim ke LLM untuk review
    );
  } catch (e) {
    return ToolExecutionResult(
      success: false,
      toolName: 'namespace.tool_name',
      error: e.toString(),
    );
  }
}
```

### Step 4: Update `workspace_loader.dart` → `_defaultSkillsBlock`

Tambah entry di section yang sesuai:

```dart
- namespace.tool_name: Deskripsi tool. Risk: safe. Args: arg1 (string), arg2 (int, optional).
```

> **PENTING:** String ini yang dibaca oleh `ContextBuilder.buildToolDescriptions()` dan dikirim ke LLM sebagai available tools. Format HARUS `- tool.name: description`.

### Step 5: (Jika `requiresConfirmation: true`) Update `_humanizeConfirmation()`

```dart
case 'namespace.tool_name':
  return 'Saya akan melakukan X. Lanjutkan?';
```

---

## Cara Menambah Module Baru

Module = fitur yang bisa di-install/uninstall user dari Module Store.

### Step 1: Define di `ModuleRegistry` (`module_model.dart`)

```dart
static const myModule = ModuleModel(
  id: 'my_module',           // unique ID
  name: 'My Module',
  description: 'Deskripsi untuk user di store.',
  icon: '🔧',               // emoji atau icon name
  settings: {
    'allow_feature_a': true,  // default ON
    'allow_feature_b': false, // default OFF
  },
);

// Tambah ke list:
static const List<ModuleModel> available = [
  clipboardAi,
  appControl,
  deviceContext,
  myModule,        // ← tambah di sini
];
```

### Step 2: Buat folder module di `lib/features/modules/my_module/`

```
lib/features/modules/my_module/
├── my_module_models.dart       # Data classes
├── my_module_service.dart      # MethodChannel wrapper (jika perlu native)
└── my_module_repository.dart   # Business logic + settings check
```

### Step 3: Pattern Repository (cek settings sebelum execute)

```dart
class MyModuleRepository {
  MyModuleRepository({required this.service, required this.moduleRepository});
  
  final MyModuleService service;
  final ModuleRepository moduleRepository;
  
  static const _moduleId = 'my_module';

  Future<SomeResult?> doThing() async {
    // Cek module enabled + per-setting toggle
    final modules = await moduleRepository.getInstalled();
    final mod = modules.where((m) => m.id == _moduleId).firstOrNull;
    if (mod == null || !mod.enabled) return null;
    if (mod.settings['allow_feature_a'] == false) return null;
    
    return service.nativeCall();
  }
}
```

### Step 4: Register tools di `tool_router.dart`

Ikuti "Cara Menambah Tool Baru" di atas. Di execution method, panggil repository:

```dart
Future<ToolExecutionResult> _executeMyModuleTool() async {
  try {
    final repo = MyModuleRepository(
      service: MyModuleService(),
      moduleRepository: ModuleRepository(),
    );
    final result = await repo.doThing();
    if (result == null) {
      return const ToolExecutionResult(
        success: false,
        toolName: 'my_module.tool',
        error: 'My Module is disabled or feature not allowed.',
      );
    }
    return ToolExecutionResult(
      success: true,
      toolName: 'my_module.tool',
      data: result.toJson(),
    );
  } catch (e) {
    return ToolExecutionResult(success: false, toolName: 'my_module.tool', error: e.toString());
  }
}
```

---

## Handling LLM

### Client: `OpenAiCompatibleClient`

- Single class, works with ANY OpenAI-compatible API (OpenAI, Groq, Together, local Ollama, etc.)
- Uses Dio for HTTP
- Endpoint: `{baseUrl}/chat/completions`
- Auth: Bearer token
- Response parsing: `choices[0].message.content`

### LLM Interaction Pattern

Semua LLM call menggunakan pattern yang sama:

```dart
final response = await client.chat(
  config: llmConfig,  // baseUrl, apiKey, model
  messages: [
    {'role': 'system', 'content': 'You are a JSON-only responder.'},
    {'role': 'user', 'content': promptString},
  ],
);
```

### JSON Parsing + Auto-Repair

Semua LLM response di-parse sebagai JSON. Jika gagal:
1. Strip markdown code fences (```json ... ```)
2. Retry dengan `jsonRepairPrompt` — minta LLM fix JSON-nya
3. Jika masih gagal → return null → runtime fails gracefully

### Prompt Architecture

4 fase prompt (semua di `prompt_templates.dart`):

| Fase | Input | Output JSON |
|------|-------|-------------|
| `analyzePrompt` | user message + workspace + tools | `{intent, goal, requires_tools, risk}` |
| `planPrompt` | analysis + tools | `{steps: [{id, description, tool}]}` |
| `selectToolPrompt` | plan + step + previous results | `{status, tool: {name, args}}` atau `{status: "done", final_response}` |
| `reviewPrompt` | tool result + plan + user message | `{status: "done"/"continue"/"retry"/"failed"}` |

### Workspace Files (Agent Context)

Setiap agent punya workspace di `documents/workspaces/{agentId}/`:

| File | Fungsi |
|------|--------|
| `SOUL.md` | System prompt / personality |
| `MEMORY.md` | Persistent memory |
| `SKILLS.md` | Available tools list (auto-refreshed) |
| `HEARTBEAT.md` | Current runtime state |

---

## Handling Native Code (Kotlin ↔ Flutter)

### MethodChannel Pattern

Flutter dan Kotlin berkomunikasi via `MethodChannel`. Setiap channel punya namespace:

| Channel | Fungsi |
|---------|--------|
| `com.meowagent/device_context` | Battery, network, storage, time, locale, foreground app, usage stats |
| `com.meowagent/app_control` | Open app, list apps, open settings, open URL |
| `com.meowagent/services` | Start/stop foreground services, permissions |
| `com.meowagent/share` | Share intent handling |

### Cara Menambah Native Method Baru

#### Flutter side (`device_context_service.dart` atau service baru):

```dart
static const _channel = MethodChannel('com.meowagent/my_channel');

Future<MyResult?> getMyData() async {
  try {
    final raw = await _channel.invokeMethod<Map>('getMyData');
    if (raw == null) return null;
    return MyResult.fromMap(raw);
  } on PlatformException {
    return null;  // SELALU handle gracefully, jangan crash
  }
}
```

#### Kotlin side (`DeviceContextPlugin.kt` atau plugin baru):

```kotlin
override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    try {
        when (call.method) {
            "getMyData" -> result.success(getMyData())
            // ... existing methods
            else -> result.notImplemented()
        }
    } catch (e: Exception) {
        result.error("MY_ERROR", e.message, null)
    }
}

private fun getMyData(): Map<String, Any?> {
    // Native Android API calls here
    return mapOf(
        "key1" to value1,
        "key2" to value2
    )
}
```

#### Register channel di `MainActivity.kt`:

```kotlin
// Di configureFlutterEngine():
MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.meowagent/my_channel")
    .setMethodCallHandler(MyPlugin(this))
```

### Aturan Native Code

1. **SELALU return Map<String, Any?>** — Flutter expects Map
2. **SELALU wrap dalam try-catch** — jangan crash app
3. **Permission check di native** — return `mapOf("available" to false, "reason" to "permission_required")` jika permission belum granted
4. **Log errors** — `Log.e(TAG, "message", exception)`
5. **Jangan block main thread** — heavy work harus async

---

## Confirmation Flow

Tools dengan `requiresConfirmation: true` mengikuti flow ini:

```
LLM picks tool → ToolRouter detects confirmation needed
    │
    ▼
Store as PendingAction → Return waitingConfirmation state
    │
    ▼
UI shows confirmation card (Confirm / Reject buttons)
    │
    ├─ User clicks Confirm → executeConfirmed() → forceExecute()
    ├─ User clicks Reject → clearPendingAction()
    └─ User types text → ConfirmationChecker.check() (keyword matching)
         ├─ "ya/oke/lanjut" → execute
         ├─ "tidak/batal/cancel" → reject
         ├─ "lihat dulu/preview" → show preview
         └─ unclear → let LLM decide with pending context
```

---

## State Management

- **Riverpod** untuk dependency injection dan state
- Provider pattern: `final xProvider = Provider<X>((ref) => X());`
- FutureProvider untuk async data: `final yProvider = FutureProvider<Y>((ref) => ...);`

---

## Checklist: Menambah Tool Baru (Quick Reference)

- [ ] `tool_router.dart` → tambah `ToolDefinition` di `_registry`
- [ ] `tool_router.dart` → tambah case di `_dispatch()`
- [ ] `tool_router.dart` → implement `_executeXxx()` method
- [ ] `workspace_loader.dart` → update `_defaultSkillsBlock` string
- [ ] (Jika sensitive) `tool_router.dart` → update `_humanizeConfirmation()`
- [ ] (Jika perlu native) Flutter service class + Kotlin plugin method
- [ ] (Jika module-gated) Repository class dengan settings check
- [ ] (Jika module baru) `module_model.dart` → tambah di `ModuleRegistry`
- [ ] **Tests** → tulis unit test (lihat section Testing di bawah)

---

## Checklist: Menambah Module Baru (Quick Reference)

- [ ] `module_model.dart` → define `ModuleModel` constant + tambah ke `available` list
- [ ] Buat folder `lib/features/modules/{module_id}/`
- [ ] Buat `{module}_models.dart` — data classes dengan `fromMap()` dan `toJson()`
- [ ] Buat `{module}_service.dart` — MethodChannel wrapper
- [ ] Buat `{module}_repository.dart` — business logic + settings gate
- [ ] (Jika native) Kotlin plugin class + register di `MainActivity.kt`
- [ ] (Jika native) Tambah permissions di `AndroidManifest.xml` jika perlu
- [ ] Register tools di `tool_router.dart` (ikuti checklist tool di atas)
- [ ] Update `_defaultSkillsBlock` di `workspace_loader.dart`
- [ ] **Tests** → tulis unit test (lihat section Testing di bawah)

## Testing (WAJIB)

Setiap tool atau module baru **HARUS** disertai unit test di `test/`.

File test naming: `test/{feature_name}_test.dart`

### Test Cases yang WAJIB Ditulis

Untuk **setiap tool baru**, minimal cover:

| # | Test Case | Tujuan |
|---|-----------|--------|
| 1 | **Success path** — parse response dari native | Pastikan `fromMap()` dan `toJson()` benar |
| 2 | **Empty/null input** — `fromMap({})` | Pastikan tidak crash, return defaults |
| 3 | **Permission missing** — graceful fallback | Pastikan return safe state, bukan throw |
| 4 | **Tool registered** — cek `ToolRouter` | Pastikan risk & confirmation level benar |
| 5 | **Module disabled** — return null/error | Pastikan settings gate berfungsi |

Untuk **module baru**, tambahan:

| # | Test Case | Tujuan |
|---|-----------|--------|
| 6 | **Settings migration** — new keys added | Pastikan existing users dapat default baru |
| 7 | **Summary includes new data** | Pastikan `device.summary` atau equivalent updated |

### Pattern Test

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:meow_agent/features/modules/device_context/device_context_models.dart';
import 'package:meow_agent/services/agent_runtime/tool_router.dart';

void main() {
  group('namespace.tool_name', () {
    test('success — parses info correctly', () {
      final raw = {'key': 'value'};
      final info = MyModel.fromMap(raw);
      expect(info.key, 'value');
    });

    test('fromMap handles empty map gracefully', () {
      final info = MyModel.fromMap({});
      expect(info.key, 'default_value'); // tidak crash
    });

    test('permission missing returns safe fallback', () {
      final raw = {'available': false, 'reason': 'permission_required'};
      final info = MyModel.fromMap(raw);
      expect(info.available, false); // tidak throw
    });

    test('tool is registered with correct risk level', () {
      final router = ToolRouter();
      final def = router.getDefinition('namespace.tool_name');
      expect(def, isNotNull);
      expect(def!.risk, 'safe');
      expect(def.requiresConfirmation, false);
    });
  });
}
```

### Menjalankan Tests

```bash
# Single file
flutter test test/my_feature_test.dart

# All tests
flutter test
```

### Real Device Testing (WAJIB di-include dalam response)

Setelah implementasi selesai, agent **WAJIB menyertakan instruksi testing di real device** dalam response-nya ke user. User harus tahu cara verifikasi fitur baru di HP asli.

Format yang harus disertakan:

```
## Cara Test di Real Device

### Prerequisites
- [permissions yang perlu di-grant manual, jika ada]
- [module yang perlu di-enable di app]

### Steps
1. Build & install: `flutter run`
2. Buka app → [navigasi ke screen yang relevan]
3. [Aksi spesifik untuk trigger tool, misal: "ketik 'cek bluetooth' di chat"]
4. [Expected result yang harus muncul]

### Verifikasi Per-Tool
- **tool.name**: [cara trigger] → [expected output]
- **tool.name**: [cara trigger edge case] → [expected fallback]

### Edge Cases untuk Dicoba
- [ ] [Kondisi X — misal: matikan bluetooth, lalu trigger tool]
- [ ] [Kondisi Y — misal: deny permission, lalu trigger tool]
- [ ] [Kondisi Z — misal: disable module di settings, lalu trigger tool]
```

**Contoh nyata** (untuk device.bluetooth):

```
## Cara Test di Real Device

### Prerequisites
- Grant BLUETOOTH_CONNECT permission (Android 12+): Settings → Apps → Meow Agent → Permissions → Nearby devices
- Enable module: App → Modules → Device Context → Enable → Allow Bluetooth Status: ON

### Steps
1. `flutter run` ke device
2. Buka chat dengan agent
3. Ketik: "cek bluetooth saya"
4. Agent harus respond dengan status bluetooth + connected devices

### Verifikasi
- **device.bluetooth** (normal): "cek bluetooth" → shows enabled: true + list devices
- **device.bluetooth** (no permission): Revoke permission → "cek bluetooth" → shows permissionGranted: false, no crash
- **device.bluetooth** (BT off): Matikan bluetooth → "cek bluetooth" → shows enabled: false

### Edge Cases
- [ ] Deny BLUETOOTH_CONNECT → tool returns safe fallback
- [ ] Disable "Allow Bluetooth Status" di module settings → tool returns module disabled error
- [ ] Bluetooth ON tapi tidak ada device connected → connectedDevices: []
```

**Kenapa ini penting:**
- Unit test hanya cover parsing logic, BUKAN integrasi native
- MethodChannel + native code hanya bisa diverifikasi di real device
- Permission edge cases hanya reproducible di Android asli

---

## Permission-on-Toggle (WAJIB)

Jika sebuah setting toggle membutuhkan permission Android, maka saat user meng-ON-kan toggle tersebut, app **HARUS** request permission-nya.

**Aturan utama:** **PRIORITAS request permission langsung di app (in-app runtime dialog). JANGAN redirect ke settings page kecuali permission tersebut tidak bisa di-grant lewat runtime dialog.**

### Klasifikasi Permission

**1. Runtime/Dangerous Permissions** → request langsung di app (Android native dialog muncul instant):
- `ACCESS_FINE_LOCATION` / `ACCESS_COARSE_LOCATION`
- `READ_PHONE_STATE`
- `BLUETOOTH_CONNECT` / `BLUETOOTH_SCAN`
- `POST_NOTIFICATIONS`
- `RECORD_AUDIO`, `CAMERA`, contacts, calendar, dst.

**2. Special Access Permissions** → harus redirect ke settings (tidak bisa via runtime dialog):
- `PACKAGE_USAGE_STATS` → Usage Access Settings
- `ACCESS_NOTIFICATION_POLICY` → DND Access Settings
- `SYSTEM_ALERT_WINDOW` → Overlay Settings
- `WRITE_SECURE_SETTINGS` → ADB only
- "Notification Listener" → Notification Access Settings

### Pattern 1: In-App Runtime Permission (PREFERRED)

Pakai native handler `requestRuntimePermissions` di `MainActivity.kt`. Multiple permissions bisa di-request sekaligus.

```dart
// Di dalam _toggleSetting(), SEBELUM save toggle:
if (_module!.id == 'my_module' && key == 'allow_feature_x' && value) {
  try {
    await const MethodChannel('com.meowagent/services')
        .invokeMethod<Map<dynamic, dynamic>>(
      'requestRuntimePermissions',
      {
        'permissions': [
          'android.permission.ACCESS_FINE_LOCATION',
          'android.permission.READ_PHONE_STATE',
        ],
      },
    );
  } catch (_) {
    // If denied or error, toggle still saves; tools degrade gracefully.
  }
}
```

Native handler otomatis:
- Skip permissions yang udah granted
- Skip request kalau SDK < 23 (auto-granted at install time)
- Return `Map<String, Boolean>` per permission
- Reentrancy guard (gak bisa overlapping requests)

### Pattern 2: Settings Redirect (FALLBACK only untuk Special Access)

Pakai pattern ini HANYA kalau permission masuk kategori Special Access. Tampilkan dialog explain dulu, baru redirect.

```dart
if (_module!.id == 'my_module' && key == 'allow_special_x' && value) {
  if (mounted) {
    final goSettings = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Permission Required'),
        content: const Text(
          'Fitur X butuh "Special Access Y".\n\n'
          'Tap "Open Settings" untuk mengaktifkan.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
    if (goSettings != true) return;
    await const MethodChannel('com.meowagent/app_control')
        .invokeMethod<bool>(
      'openSettings',
      {'action': 'android.settings.RELEVANT_SETTINGS_ACTION'},
    );
  }
}
```

### Mapping Permission → Pattern

| Permission | Pattern | Method |
|-----------|---------|--------|
| ACCESS_FINE_LOCATION | In-app | `requestRuntimePermissions` |
| ACCESS_COARSE_LOCATION | In-app | `requestRuntimePermissions` |
| READ_PHONE_STATE | In-app | `requestRuntimePermissions` |
| BLUETOOTH_CONNECT | In-app | `requestRuntimePermissions` |
| POST_NOTIFICATIONS | In-app | `requestNotificationPermission` |
| PACKAGE_USAGE_STATS | Settings redirect | `android.settings.USAGE_ACCESS_SETTINGS` |
| ACCESS_NOTIFICATION_POLICY | Settings redirect | `android.settings.NOTIFICATION_POLICY_ACCESS_SETTINGS` |
| SYSTEM_ALERT_WINDOW | Settings redirect | `android.settings.action.MANAGE_OVERLAY_PERMISSION` |

### Aturan

- **PRIORITAS pakai in-app runtime request** — UX paling smooth, user gak perlu keluar app
- **JANGAN redirect ke settings** kalau permission bisa di-request runtime
- **JANGAN block toggle** kalau permission denied — save toggle, tool handle gracefully (degraded data, bukan crash)
- **SELALU** tambahkan subtitle di setting label yang menyebutkan permission requirement
- **SELALU** wrap permission request in `try/catch` — toggle tetap save kalau error
- **Tool-side native code** tetap defensive: per-call try/catch, return safe fallback (`null`, `"unknown"`, `permissionGranted: false`) bukan crash
- **Tambahkan permission ke** `AndroidManifest.xml` (semua permission, runtime maupun special)



---

## Konvensi & Aturan

1. **Tool naming:** `namespace.action` (lowercase, dot-separated)
2. **Error handling:** SELALU return `ToolExecutionResult` — jangan throw
3. **Module gating:** Cek `module.enabled` DAN `module.settings[key]` sebelum execute
4. **Native returns:** Selalu `Map<String, Any?>`, selalu handle null/error gracefully
5. **LLM prompts:** Selalu minta JSON-only response, selalu handle parse failure
6. **User-facing text:** Bahasa Indonesia untuk confirmations dan responses
7. **No tool names exposed to user:** `_humanizeConfirmation()` translates to natural language
8. **Risk comes from registry, NOT from LLM output** — security enforcement
9. **Testing:** SELALU tulis test setelah nambah tool/module baru — no exceptions
10. **Permission-on-toggle:** Jika setting butuh permission, WAJIB cek/minta saat toggle ON — lihat section di atas
