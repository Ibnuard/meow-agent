# APP_AGENT_AUTOMATION.md — LLM-Driven Dynamic App Automation

## Overview

Module baru **App Agent** (atau **Automation**) akan menggantikan module `communication` yang saat ini bergantung pada hardcoded resource IDs per-aplikasi (WhatsApp, Telegram, dll).

Pendekatan baru: **LLM membaca accessibility node tree secara dinamis** dan memutuskan action apa yang harus diambil berdasarkan semantik layar, bukan hardcoded selectors.

---

## Motivasi

### Problem dengan Pendekatan Saat Ini (Communication Module)

| Masalah | Dampak |
|---------|--------|
| Resource ID berubah setiap app update | Automation break, perlu manual fix |
| Per-app hardcoding (WA, Telegram, dll) | Tidak scalable, setiap app baru = kode baru |
| Tidak bisa handle UI variants (bahasa, theme, A/B test) | Gagal di device tertentu |
| Typo/fuzzy matching terbatas pada logic manual | Tidak adaptif |

### Solusi: LLM sebagai "Mata" Agent

LLM menerima representasi layar (accessibility tree) dan secara semantik memutuskan:
- Node mana yang relevan untuk tujuan user
- Action apa yang harus dilakukan (click, set_text, scroll)
- Kapan task selesai atau gagal

---

## Arsitektur

```
┌─────────────────────────────────────────────┐
│              Meow Agent Runtime              │
│                                             │
│  User Request → Analyzer → Planner →        │
│  Tool: app_agent.execute                    │
└──────────────────┬──────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────┐
│           App Agent Executor                │
│                                             │
│  1. Launch target app                       │
│  2. Capture accessibility tree              │
│  3. Prune & serialize tree                  │
│  4. Send to LLM with goal context           │
│  5. LLM returns action (click/type/scroll)  │
│  6. Execute action via AccessibilityService │
│  7. Wait for screen change                  │
│  8. Loop until goal achieved or max steps   │
└──────────────────┬──────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────┐
│      MeowAccessibilityService (Native)      │
│                                             │
│  - rootInActiveWindow → node tree           │
│  - performAction(CLICK / SET_TEXT / SCROLL) │
│  - Event listener for screen changes        │
└─────────────────────────────────────────────┘
```

---

## Flow Detail

### Step 1: Tree Capture & Pruning

```kotlin
fun captureScreen(): ScreenState {
    val root = rootInActiveWindow
    val nodes = pruneTree(root) // Hanya clickable, editable, has-text, has-desc
    return ScreenState(
        packageName = root.packageName,
        nodes = nodes.map { it.toCompact() }  // id, class, text, desc, bounds, flags
    )
}
```

**Pruning rules:**
- Skip nodes tanpa text, desc, DAN tidak clickable/editable
- Limit depth (max 6 levels)
- Limit total nodes (max 50 per capture)
- Assign sequential `nodeId` (0, 1, 2...) untuk referensi LLM

### Step 2: LLM Prompt

```
You are an app automation agent. You can see the current screen of an Android app.

GOAL: {user_goal}
APP: {package_name}
STEP: {current_step}/{max_steps}

SCREEN NODES:
[0] Button text="Send" desc="" clickable=true bounds=[800,1200,900,1260]
[1] EditText text="" desc="Type a message" editable=true bounds=[100,1200,780,1260]
[2] TextView text="The Most Secrets" clickable=true bounds=[100,300,600,360]
...

Previous actions this session:
- Step 1: clicked node[5] (search bar)
- Step 2: typed "meeting" in node[1]

Respond with ONE action:
{"action": "click", "node": 2, "reason": "Opening the group chat"}
{"action": "set_text", "node": 1, "text": "Hello", "reason": "Typing message"}
{"action": "scroll", "direction": "down", "reason": "Looking for more chats"}
{"action": "done", "reason": "Message sent successfully"}
{"action": "fail", "reason": "Cannot find target element"}
```

### Step 3: Action Execution

```kotlin
when (action.type) {
    "click" -> nodes[action.nodeId].performAction(ACTION_CLICK)
    "set_text" -> {
        val args = Bundle()
        args.putCharSequence(ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, action.text)
        nodes[action.nodeId].performAction(ACTION_SET_TEXT, args)
    }
    "scroll" -> nodes[action.nodeId].performAction(ACTION_SCROLL_FORWARD)
    "done" -> return AutomationResult.Success
    "fail" -> return AutomationResult.Failed(action.reason)
}
```

### Step 4: Loop Until Done

- Max steps per task: **10** (configurable)
- After each action, wait for `TYPE_WINDOW_STATE_CHANGED` or timeout (2s)
- Re-capture screen, send to LLM again
- LLM decides next action or declares done/fail

---

## API Surface (Tools)

```yaml
app_agent.execute:
  description: "Execute a multi-step automation task on any Android app"
  args:
    goal: "Send WhatsApp message to The Most Secrets saying meeting jam 3"
    app_hint: "com.whatsapp"  # optional, helps with initial launch
  returns:
    success: true/false
    steps_taken: 4
    final_state: "Message sent"

app_agent.inspect:
  description: "Read current screen content without taking action"
  args:
    app_hint: "com.whatsapp"
  returns:
    package_name: "com.whatsapp"
    screen_summary: "WhatsApp main screen with chat list..."
    visible_items: [...]
```

---

## Trade-offs (Diterima)

| Trade-off | Mitigasi |
|-----------|----------|
| **Latency** (~1-3s per step, 5-10 steps = 5-30s total) | Acceptable untuk automation tasks; user sees progress via narrative |
| **Cost** (1 LLM call per step) | Use cheap/fast model (GPT-4o-mini, Gemini Flash); cache common patterns |
| **Privacy** (screen content sent to LLM) | On-device model option (future); clear user consent in module settings |
| **Reliability** (~90-95% vs 99% hardcoded) | Retry logic + fallback to manual; LLM improves over time |
| **Token usage** (pruned tree ~500-1000 tokens per step) | Aggressive pruning; summarize previous steps |

---

## Keunggulan vs Communication Module

| Aspek | Communication (Current) | App Agent (New) |
|-------|------------------------|-----------------|
| App support | WhatsApp only (+ planned Telegram) | ANY app |
| Maintenance | Break on every WA update | Self-healing via LLM |
| Complexity per app | ~300 lines Kotlin per app | 0 lines per app |
| Typo handling | Manual fuzzy match | LLM understands intent |
| Multi-step flows | Hardcoded state machine | Dynamic planning |
| Language support | Manual ID per locale | LLM reads any language |

---

## Module Settings

```dart
ModuleModel(
  id: 'app_agent',
  name: 'App Automation',
  description: 'Control any app with AI-powered screen reading',
  settings: {
    'enabled': true,
    'max_steps_per_task': 10,
    'automation_model': 'fast',  // fast (mini) vs accurate (full)
    'require_confirmation': true,  // confirm before executing on sensitive apps
    'allowed_apps': [],  // empty = all apps; or whitelist
    'blocked_apps': ['com.android.settings'],  // never automate these
  },
)
```

---

## Permission Requirements

| Permission | Alasan |
|-----------|--------|
| Accessibility Service | Core: membaca dan mengontrol UI apps lain |
| SYSTEM_ALERT_WINDOW (optional) | Overlay indicator saat automation berjalan |

---

## Migration Plan

1. **Phase 1** (current): Communication module tetap ada, hardcoded WA automation
2. **Phase 2**: Build App Agent module parallel, test dengan WA sebagai first target
3. **Phase 3**: App Agent stable → deprecate Communication module
4. **Phase 4**: Remove Communication module entirely; App Agent handles all external app interactions

---

## Implementation Priority

1. Tree capture & pruning (Kotlin native)
2. Screen-to-prompt serialization
3. LLM action loop (Flutter ↔ Kotlin bridge)
4. Basic WA flow (send message, send to group) as validation
5. Progress indicator overlay (optional)
6. Caching layer for repeated patterns
7. On-device model support (future)

---

## Catatan

- Module ini BUKAN screen recorder. Ia hanya membaca accessibility node metadata (text, desc, bounds, class) — bukan pixel/visual.
- Untuk apps yang butuh visual understanding (game, image-heavy UI), bisa dikombinasikan dengan screenshot + vision model di masa depan.
- Setiap automation session harus punya clear start/end boundary dan user-visible progress feedback.

---

## Virtual Display Experiment (FAILED — Archived)

**Tested: 2026-06-04 on Android 15 (API 35)**

Hypothesis: Create a virtual display, launch target app headlessly, capture accessibility tree — all without screen being on/unlocked.

Results:
- ✅ `DisplayManager.createVirtualDisplay()` succeeds with `VIRTUAL_DISPLAY_FLAG_PRESENTATION`
- ❌ `startActivity(intent, ActivityOptions.setLaunchDisplayId(id))` → SecurityException
- ❌ `adb shell am start --display <id>` → SecurityException (even UID 2000 blocked)
- Root cause: `SafeActivityOptions.checkPermissions()` requires display to be TRUSTED (system-created) or caller to have `INTERNAL_SYSTEM_WINDOW` (signature permission)

**Conclusion**: Virtual display approach is NOT viable on Android 14+/15 without root. Dead end.

---

## Background & Lock-Screen Execution (Shizuku Approach)

### Overview

App Agent **requires the device to be unlocked** for UI automation (accessibility tree needs active window). For scheduled/background tasks, we use **Shizuku** to programmatically wake and unlock the device.

Shizuku provides ADB shell-level access (UID 2000) from within the app. User grants it once via wireless ADB. Persists across reboots with Shizuku service running.

### Flow

```
Trigger (scheduled task / background event)
  → Check: is device locked?
    → YES:
        1. Shizuku: input keyevent WAKEUP          (screen on)
        2. Shizuku: input swipe 540 1800 540 800    (swipe up to PIN)
        3. Shizuku: input text <encrypted_pin>      (enter PIN)
        4. Shizuku: input keyevent 66               (confirm/ENTER)
        5. Wait 1s for keyguard dismiss
    → NO: proceed directly
  → Normal App Agent automation loop (accessibility-based)
  → After completion:
        6. Shizuku: input keyevent 26               (lock device)
```

### PIN Storage

- User provides device PIN once during setup
- Stored encrypted with AES-256 + Android Keystore
- Decryption requires app to be running (no biometric gate for background tasks)
- If PIN changes → automation fails gracefully, prompts user to update

### Shizuku Integration

```kotlin
// Execute shell command via Shizuku
fun shizukuExec(command: String): String {
    val process = Shizuku.newProcess(arrayOf("sh", "-c", command), null, null)
    val output = process.inputStream.bufferedReader().readText()
    process.waitFor()
    return output
}

// Wake + Unlock sequence
suspend fun wakeAndUnlock(encryptedPin: String) {
    val pin = decryptPin(encryptedPin)
    shizukuExec("input keyevent KEYEVENT_WAKEUP")
    delay(500)
    shizukuExec("input swipe 540 1800 540 800 300")
    delay(500)
    shizukuExec("input text $pin")
    shizukuExec("input keyevent 66")
    delay(1000) // wait for keyguard dismiss
}

// Lock device
fun lockDevice() {
    shizukuExec("input keyevent 26")
}
```

### Permissions / Requirements

| Requirement | How |
|-------------|-----|
| Shizuku app installed | User installs from GitHub/APK |
| Shizuku service running | User starts via wireless ADB once |
| Grant to Meow Agent | Runtime permission prompt (one-time) |
| Device PIN stored | User provides during module setup |
| Foreground service | Keeps LLM calls alive during Doze |
| Battery optimization exempt | `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` |

### Behavior Matrix

| Scenario | Action |
|----------|--------|
| Device unlocked, user active | Accessibility direct (no Shizuku needed) |
| Device locked, scheduled task | Shizuku wake → unlock → automate → lock |
| Shizuku not available | Queue task, notify user to unlock manually |
| PIN incorrect / changed | Fail gracefully, prompt PIN update |
| Automation takes >60s | Keep wakelock, show notification progress |

---

## Multi-Function Floating Bubble (Menggantikan Clipboard Bubble)

### Konsep

Floating bubble yang ada saat ini (`clipboard_ai` module) hanya melayani SATU fungsi: clipboard monitoring. Ini akan di-**deprecate** dan diganti dengan **Meow Bubble** — unified floating overlay yang multi-fungsi.

Meow Bubble adalah "mata dan mulut" agent di luar app Meow Agent. Ia mengambang di atas semua app dan berfungsi sebagai:

1. **Automation Narrator** — menampilkan real-time progress saat App Agent bekerja
2. **Clipboard AI** — fungsi existing (monitor, format, translate clipboard)
3. **Quick Action Trigger** — tap untuk voice command atau quick chat ke agent
4. **Notification Digest** — ringkasan notifikasi penting
5. **Context Awareness** — menampilkan info relevan berdasarkan app yang sedang dibuka

### Visual States

```
┌─────────────────────────────────────────────────┐
│  IDLE (Minimized)                               │
│  ○  ← dot kecil, semi-transparent, draggable   │
└─────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────┐
│  ACTIVE (Pill)                                  │
│  🤖 Mengirim pesan ke grup...                   │
│  ← pill shape, narrative text, auto-dismiss     │
└─────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────┐
│  EXPANDED (Card)                                │
│  ┌─────────────────────────────┐               │
│  │ 🤖 Meow Agent              │               │
│  │                             │               │
│  │ Step 3/5: Mengetik pesan    │               │
│  │ ████████░░ 60%              │               │
│  │                             │               │
│  │ [Cancel]        [Minimize]  │               │
│  └─────────────────────────────┘               │
└─────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────┐
│  QUICK ACTIONS (Radial/Sheet)                   │
│  Long-press bubble → expand ke menu:            │
│                                                 │
│     📋 Clipboard    🎤 Voice                    │
│     💬 Quick Chat   🔔 Notifs                   │
│     ⚡ Last Action  ⚙️ Settings                 │
└─────────────────────────────────────────────────┘
```

### Automation Narrator Mode

Saat App Agent sedang menjalankan task di app lain:

```
Timeline:
─────────────────────────────────────────
t=0s   Bubble muncul (pill): "Membuka WhatsApp..."
t=2s   Update text: "Mencari grup The Most Secrets..."
t=4s   Update text: "Mengetik pesan..."
t=6s   Update text: "Mengirim... ✓"
t=7s   Fade to success state (green tick)
t=9s   Auto-minimize kembali ke dot
─────────────────────────────────────────
```

**Data flow:**
```
LLM Action Response
    → narrative field
        → MethodChannel("com.meowagent/bubble")
            → BubbleService.updateNarrative(text, progress)
                → WindowManager overlay update
```

### Arsitektur Service

```
┌─────────────────────────────────────────────┐
│         MeowBubbleService                   │
│         (Foreground Service)                │
│                                             │
│  ┌───────────────┐  ┌──────────────────┐   │
│  │ WindowManager │  │ MethodChannel    │   │
│  │ Overlay View  │  │ (Flutter ↔ Kt)   │   │
│  └───────┬───────┘  └────────┬─────────┘   │
│          │                    │             │
│          ▼                    ▼             │
│  ┌───────────────────────────────────┐     │
│  │        BubbleStateManager         │     │
│  │                                   │     │
│  │  state: idle | narrating |        │     │
│  │         clipboard | expanded      │     │
│  │  text: "..."                      │     │
│  │  progress: 0.6                    │     │
│  │  actions: [cancel, minimize]      │     │
│  └───────────────────────────────────┘     │
└─────────────────────────────────────────────┘
```

### MethodChannel API

```dart
// Flutter → Native
channel.invokeMethod('showNarrative', {'text': '...', 'progress': 0.5});
channel.invokeMethod('showClipboard', {'content': '...', 'actions': [...]});
channel.invokeMethod('minimize');
channel.invokeMethod('dismiss');
channel.invokeMethod('showQuickActions');

// Native → Flutter (callbacks)
channel.setMethodCallHandler((call) {
  switch (call.method) {
    case 'onQuickAction': // user tapped an action
    case 'onCancel':      // user cancelled automation
    case 'onBubbleTap':   // user tapped the bubble
    case 'onVoiceInput':  // voice command result
  }
});
```

### Migration dari Clipboard Bubble

| Current (clipboard_ai) | New (Meow Bubble) |
|------------------------|-------------------|
| `ClipboardBubbleService` | `MeowBubbleService` |
| Single purpose: clipboard | Multi-purpose: narrator + clipboard + actions |
| Module-specific toggle | Global service, fitur per-module |
| Separate permission flow | Unified SYSTEM_ALERT_WINDOW |
| Hanya muncul saat clipboard change | Always available (minimized dot) |

**Backward compatibility:**
- Clipboard monitoring tetap jalan sebagai salah satu "mode" bubble
- User yang sudah enable clipboard bubble → auto-migrate ke Meow Bubble
- Setting `floating_bubble` di clipboard_ai → deprecated, moved ke global

### Permission

| Permission | Status |
|-----------|--------|
| `SYSTEM_ALERT_WINDOW` | Sudah ada (dari clipboard bubble) |
| `FOREGROUND_SERVICE` | Sudah ada |
| Accessibility Service | Sudah ada (untuk App Agent) |

Tidak butuh permission tambahan — hanya refactor service yang sudah ada.

### Design (Sesuai AGENTS.md)

- Background: `rgba(15,23,42,0.92)` — surface translucent
- Border: `rgba(59,130,246,0.3)` — subtle blue glow saat active
- Text: `#E5E7EB` — primary text
- Corner radius: pill (999px) untuk minimized, 20px untuk expanded card
- Animation: fade + scale, smooth 200ms ease-out
- Shadow: soft ambient, sesuai floating surface language

### Implementation Priority

1. Refactor `ClipboardBubbleService` → `MeowBubbleService` (multi-state)
2. Add narrative update channel dari App Agent executor
3. Implement pill state (auto-show saat automation running)
4. Quick actions radial menu (long-press)
5. Voice input integration
6. Context-aware suggestions based on foreground app
