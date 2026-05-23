# PROGRESS.md — Meow Agent Development Progress

> Last updated: 2026-05-24

---

## Project Overview

**Meow Agent** is an Android-native agentic AI companion app built with Flutter. It connects to any OpenAI-compatible LLM provider and offers modular AI-powered automation inspired by iOS Shortcuts.

---

## Architecture

```
lib/
├── app/
│   ├── router.dart          # GoRouter with all routes
│   ├── shell.dart           # Bottom navigation shell (floating dock)
│   ├── theme.dart           # MeowTheme (dark-first, Material 3)
│   └── theme_mode_provider.dart
├── core/
│   └── storage/
│       ├── local_storage_service.dart   # SharedPreferences wrapper
│       └── secure_storage_service.dart  # flutter_secure_storage wrapper
├── features/
│   ├── activity/            # Activity/logs screen (placeholder)
│   ├── agents/              # Agent CRUD (create, edit, list)
│   ├── chat/                # Chat UI + SQLite persistence
│   ├── home/                # Home screen with module grid
│   ├── modules/             # Module system + Clipboard AI
│   ├── providers/           # LLM provider CRUD
│   └── settings/            # App settings
├── services/
│   └── llm/
│       └── openai_compatible_client.dart  # Dio-based LLM client
└── main.dart                # Entry point + share intent listener
```

---

## Completed Features

### Phase 1: Foundation ✅

| Feature | Status | Notes |
|---------|--------|-------|
| Project scaffold | ✅ | Flutter, Riverpod, GoRouter, Material 3 |
| Dark theme system | ✅ | Custom `MeowTheme` with extras (card, subtleBorder, gradientEnd) |
| Bottom navigation (floating dock) | ✅ | Home, Activity, Chat FAB, Agent, Settings |
| Edge-to-edge Android support | ✅ | Transparent system bars, SafeArea handling |

### Phase 2: Provider & Agent System ✅

| Feature | Status | Notes |
|---------|--------|-------|
| Provider CRUD | ✅ | nickname, baseUrl, apiKey (secure), model |
| Agent CRUD | ✅ | name, linked providerId |
| Provider list screen | ✅ | View/edit/delete providers |
| Agent list screen | ✅ | View/edit/delete agents |
| OpenAI-compatible client | ✅ | Dio-based, supports any OpenAI-compatible endpoint |

### Phase 3: Chat System ✅

| Feature | Status | Notes |
|---------|--------|-------|
| Chat UI | ✅ | Bubbles, thinking indicator, markdown rendering |
| SQLite persistence | ✅ | `sqflite`, per-agent message history |
| Paginated loading | ✅ | Latest 30 messages, scroll-to-top loads older |
| Loading indicators | ✅ | Initial load spinner, older messages spinner |
| Agent switching (drawer) | ✅ | Side drawer to switch active agent |
| Slash commands | ✅ | /clear, /help, /reset, /model, /compact, /cron |
| Command auto-suggest | ✅ | Typing `/` shows filtered command list |
| Markdown rendering | ✅ | `flutter_markdown` for bold, italic, lists, code |
| System prompt | ✅ | Dynamic prompt with first-chat introduction rule |
| Context window optimization | ✅ | Only last 20 messages sent to LLM |
| Keyboard dismiss | ✅ | On send + tap outside |
| File attachment button | ✅ | `file_picker`, 1MB max, any file type |
| Scroll-to-bottom fix | ✅ | Two-phase scroll for markdown layout |
| RepaintBoundary | ✅ | Per-bubble paint isolation |
| Empty states | ✅ | No agent, no messages, loading |

### Phase 4: Module System ✅

| Feature | Status | Notes |
|---------|--------|-------|
| Module data model | ✅ | id, name, description, icon, enabled, settings map |
| Module repository | ✅ | SharedPreferences persistence |
| Module store screen | ✅ | Browse & install available modules |
| Module detail screen | ✅ | Settings toggles wired to native services |
| Home screen integration | ✅ | Shows installed modules + "Add" button |
| Module card navigation | ✅ | Tap → detail screen |

### Phase 5: Clipboard AI Module ✅

| Feature | Status | Notes |
|---------|--------|-------|
| Share Intent | ✅ | AndroidManifest intent-filter + MainActivity handler |
| Platform channel (share) | ✅ | `com.meowagent/share` MethodChannel |
| Auto-navigate on share | ✅ | main.dart checks on start + resume |
| Clipboard Process Screen | ✅ | Agent dropdown, action chips, LLM processing, copy result |
| Actions | ✅ | Translate, Summarize, Rewrite, Explain, Fix Grammar, Draft Reply |
| Agent selector | ✅ | Dropdown with provider info subtitle |
| Persistent Notification | ✅ | ForegroundService + notification action |
| Floating Bubble | ✅ | Draggable overlay via SYSTEM_ALERT_WINDOW |
| Service controller | ✅ | `com.meowagent/services` MethodChannel |
| Toggle wiring | ✅ | Module detail toggles start/stop native services |

---

## Native Android Code

```
android/app/src/main/
├── kotlin/com/meowagent/meow_agent/
│   ├── MainActivity.kt                    # Intent handling + platform channels
│   ├── ClipboardForegroundService.kt      # Persistent notification service
│   └── FloatingBubbleService.kt           # Draggable bubble overlay
├── res/
│   └── drawable/bubble_background.xml
└── AndroidManifest.xml                    # Services, permissions, intent-filters
```

---

## Dependencies

```yaml
# State management
flutter_riverpod: ^2.6.1

# Navigation
go_router: ^14.6.2

# Networking
dio: ^5.7.0

# Storage
flutter_secure_storage: ^9.2.2
shared_preferences: ^2.3.3
path_provider: ^2.1.5
sqflite: ^2.4.1

# Utilities
uuid: ^4.5.1
google_fonts: ^6.2.1
file_picker: ^8.1.6
flutter_markdown: ^0.7.6
```

---

## Known Issues / Pending

| Issue | Priority | Notes |
|-------|----------|-------|
| Clipboard AI provider resolution | HIGH | Debug info added — may be `isComplete` check failing on secure storage read timing |
| `/compact` command | LOW | Placeholder — needs LLM summarization call |
| `/cron` command | LOW | Placeholder — needs HEARTBEAT.md parser |
| Activity screen | LOW | Empty placeholder |
| File attachment sending to LLM | MEDIUM | File picked but not yet encoded/sent in messages |
| Floating bubble icon styling | LOW | Uses placeholder Material icon; can be replaced with branded asset |

---

## Routes

| Route | Screen |
|-------|--------|
| `/` | Home (modules grid) |
| `/activity` | Activity log |
| `/agents` | Agent list |
| `/settings` | Settings |
| `/chat` | Default agent chat |
| `/agents/:id/chat` | Specific agent chat |
| `/agents/new` | Create agent |
| `/agents/:id/edit` | Edit agent |
| `/providers` | Provider list |
| `/providers/new` | Add provider |
| `/providers/:id/edit` | Edit provider |
| `/modules/store` | Module store (browse & install) |
| `/modules/:id` | Module detail (settings) |
| `/modules/clipboard/process` | Clipboard AI processing |

---

## Design System

Follows `AGENTS.md` strictly:
- Background: `#020817`
- Primary: `#3B82F6`
- Surface: `rgba(15,23,42,0.82)`
- Floating surfaces with 20-28px radius
- Soft shadows, translucent cards
- Calm, futuristic, minimal aesthetic

---

## Next Steps (Suggested)

1. **Fix Clipboard AI provider resolution** — verify secure storage timing
2. **File attachment → LLM** — base64 encode images for vision models
3. **SKILL.md execution engine** — tool-calling loop for agents
4. **Context compaction** — implement `/compact` with summarization
5. **HEARTBEAT.md cron** — scheduled task parser + execution
6. **More modules** — Notification Intelligence, Device Control, Quick Actions
7. **Onboarding flow** — first-time user guide
8. **App icon & splash** — branded launch experience
