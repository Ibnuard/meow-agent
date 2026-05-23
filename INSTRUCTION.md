# INSTRUCTION.md — Meow Agent

## Project Goal

Build **Meow Agent**, an Android-native agentic AI app built with **Flutter**.

Meow Agent is designed as a background AI agent platform for Android. The main concept is:

> The agent should be able to work in the background using internal modules without taking over or disturbing the user's main Android activity.

For example, instead of controlling the user's real Chrome app directly, the agent should use an internal **Browser Module**. Instead of requiring a laptop or VPS for development tasks, the agent can use a **VM Module** powered by proot Ubuntu.

The first MVP should focus on a clean architecture, modular permissions, LLM provider setup, and a minimal working chat-agent flow.

---

## Core Product Concept

Meow Agent consists of:

1. **Core Agent**
   - Receives user messages.
   - Talks to an OpenAI-compatible LLM provider.
   - Decides which module/tool to use.
   - Executes safe actions through enabled modules only.
   - Returns result to the user.

2. **Module System**
   - Modules are optional capabilities.
   - User can turn each module permission on or off.
   - Disabled modules must not be accessible by the agent.
   - Each module should expose a clear tool schema.

3. **Permission Control**
   - User chooses which permissions/modules are active.
   - Every module should have:
     - name
     - description
     - enabled status
     - permission scope
     - action log

4. **BYOK LLM Provider**
   - For now, only support **OpenAI-compatible API**.
   - Do not support Ollama/local model yet.
   - User must input:
     - Base URL
     - API Key
     - Model Name

---

## Tech Stack

Use:

- Flutter
- Dart
- Provider / Riverpod / Bloc, choose one and keep consistent
- `http` or `dio` for API calls
- `shared_preferences` or `flutter_secure_storage` for storing settings
- `permission_handler` for Android permissions
- `webview_flutter` or equivalent for Browser Module
- Platform channels when native Android capability is needed

Recommended for MVP:

- State management: **Riverpod**
- API client: **Dio**
- Sensitive storage: **flutter_secure_storage**
- Local non-sensitive config: **shared_preferences**

---

## Main Screens

Based on the sketch, create these main screens:

### 1. Home Screen

Purpose:
Show available modules and quick access to chat/settings.

Layout:

- Top logo area
- Grid/list of modules
- Bottom navigation:
  - Home
  - Chat
  - Settings

Example modules:

- Browser Module
- Notification Listener Module
- VM Module
- File Module
- Webhook/API Module
- Intent Module

Each module card should show:

- icon
- module name
- short description
- enabled/disabled status

---

### 2. Agent List Screen

Purpose:
Show all available agents.

For MVP, support one default agent first.

Layout:

- Back button
- Add New Agent button
- List of agents
- Each agent card:
  - Agent name
  - Short description
  - Active model
  - Enabled modules count

MVP requirement:

- Create default agent: `Agent 1`
- Add New Agent can be placeholder for now

---

### 3. Chat Screen

Purpose:
Main chat interface between user and agent.

Layout:

- Top app bar:
  - back button
  - agent name
- Chat bubbles
- Input field
- Send button

MVP behavior:

- User sends message
- App sends request to configured OpenAI-compatible provider
- Agent replies
- Store chat history locally

---

### 4. Settings Screen

Purpose:
Configure LLM provider and permissions.

Sections:

#### LLM Provider Settings

Fields:

- Base URL
- API Key
- Model Name
- Test Connection button

Example defaults:

```txt
Base URL: https://api.openai.com/v1
Model: gpt-4.1-mini
```

Do not hardcode API key.

#### Module Permissions

Show list of modules with toggle:

- Browser Module: on/off
- Notification Listener Module: on/off
- VM Module: on/off
- File Module: on/off
- Webhook/API Module: on/off
- Intent Module: on/off

#### Safety Mode

Add option:

- Read Only
- Approval Required
- Autonomous

MVP default:

```txt
Approval Required
```

---

## Suggested Folder Structure

```txt
lib/
  main.dart

  app/
    app.dart
    router.dart
    theme.dart

  core/
    config/
      app_config.dart
    storage/
      secure_storage_service.dart
      local_storage_service.dart
    network/
      dio_client.dart
    utils/
      result.dart
      logger.dart

  features/
    home/
      presentation/
        home_screen.dart
        widgets/
          module_card.dart

    agents/
      data/
        agent_model.dart
        agent_repository.dart
      presentation/
        agent_list_screen.dart
        widgets/
          agent_card.dart

    chat/
      data/
        chat_message_model.dart
        chat_repository.dart
      domain/
        agent_orchestrator.dart
      presentation/
        chat_screen.dart
        widgets/
          chat_bubble.dart
          chat_input.dart

    settings/
      data/
        llm_provider_config.dart
        settings_repository.dart
      presentation/
        settings_screen.dart
        widgets/
          llm_settings_form.dart
          module_permission_tile.dart
          safety_mode_selector.dart

    modules/
      core/
        agent_module.dart
        module_registry.dart
        module_permission.dart

      browser/
        browser_module.dart
        browser_module_screen.dart

      notification_listener/
        notification_listener_module.dart

      vm/
        vm_module.dart

      file/
        file_module.dart

      webhook/
        webhook_module.dart

      intent/
        intent_module.dart

  services/
    llm/
      openai_compatible_client.dart
      llm_message.dart
      llm_response.dart

    permissions/
      permission_service.dart

    logs/
      action_log_service.dart
```

---

## Module Interface

Every module should implement a common interface.

```dart
abstract class AgentModule {
  String get id;
  String get name;
  String get description;
  bool get requiresApproval;

  Future<bool> isEnabled();
  Future<ModuleResult> execute(ModuleCommand command);
}
```

Example command:

```dart
class ModuleCommand {
  final String action;
  final Map<String, dynamic> params;

  ModuleCommand({
    required this.action,
    required this.params,
  });
}
```

Example result:

```dart
class ModuleResult {
  final bool success;
  final String message;
  final Map<String, dynamic>? data;

  ModuleResult({
    required this.success,
    required this.message,
    this.data,
  });
}
```

---

## Initial Modules

### 1. Browser Module

Goal:
Allow agent to browse using internal app browser/WebView without disturbing user's real browser.

MVP actions:

```txt
open_url
get_current_url
get_page_title
```

Future actions:

```txt
click_element
fill_input
extract_text
screenshot_page
```

Important:
Do not control external Chrome for MVP.

---

### 2. Notification Listener Module

Goal:
Allow agent to react to Android notifications.

MVP:

- Prepare settings UI
- Explain required Android permission
- Store enabled/disabled state

Future:

- Listen to notifications
- Filter by package/app name
- Trigger agent workflow

Example use case:

```txt
When notification from banking app arrives, summarize it and save to expense log.
```

Safety:
Never expose OTP by default. Add sensitive notification filtering later.

---

### 3. VM Module

Goal:
Provide a proot Ubuntu environment inside Android for dev/automation tasks.

MVP:

- Create placeholder module and UI
- Show status: not installed / installed / running
- Add install button placeholder

Future:

- Install Ubuntu rootfs
- Run shell command
- Install Node.js/Python
- Serve local web preview
- Let agent create files and run scripts

Example use case:

```txt
User asks agent to create a simple landing page.
Agent writes files inside VM module, runs dev server, and returns preview URL.
```

Safety:
Commands that modify files, install packages, or expose server should require approval.

---

### 4. File Module

Goal:
Allow agent to manage files inside app sandbox.

MVP actions:

```txt
write_text_file
read_text_file
list_files
```

Default scope:

```txt
App sandbox only
```

Do not access full Android storage in MVP.

---

### 5. Webhook/API Module

Goal:
Allow agent to call external APIs or webhooks.

MVP:

```txt
http_get
http_post
```

Safety:

- Require approval by default.
- Hide API keys from chat logs.
- Do not log full Authorization headers.

---

### 6. Intent Module

Goal:
Allow agent to trigger Android intents.

MVP:

- Placeholder only

Future:

```txt
open_app
share_text
send_email_draft
open_maps
```

Safety:
Any action that sends data outside the app requires approval.

---

## LLM Client Requirement

Create OpenAI-compatible client.

Request format:

```http
POST {baseUrl}/chat/completions
Authorization: Bearer {apiKey}
Content-Type: application/json
```

Body:

```json
{
  "model": "MODEL_NAME",
  "messages": [
    {
      "role": "system",
      "content": "You are Meow Agent, an Android-native AI agent..."
    },
    {
      "role": "user",
      "content": "User message"
    }
  ]
}
```

Response parsing:

Use:

```txt
choices[0].message.content
```

The client must support custom base URL, API key, and model name.

---

## Agent System Prompt

Use this as the initial system prompt:

```txt
You are Meow Agent, an Android-native AI agent.

You can help the user through enabled Android modules only.
You must not assume a module is available unless it is enabled.
You must not perform sensitive actions without approval.
You must explain what action you want to take before using dangerous tools.

Available safety modes:
- Read Only: never execute actions, only explain.
- Approval Required: ask before executing sensitive actions.
- Autonomous: execute allowed safe actions automatically.

Current rule:
When unsure, ask for confirmation.
```

---

## MVP Behavior

The first working version should support:

1. User opens app
2. User goes to Settings
3. User enters:
   - OpenAI-compatible Base URL
   - API Key
   - Model Name
4. User toggles modules on/off
5. User opens Chat
6. User sends message
7. App sends message to LLM provider
8. LLM response appears in chat
9. Chat history is stored locally
10. Module list reflects enabled/disabled state

---

## Minimal UI Style

Use a simple soft mobile UI based on the sketch.

Style direction:

- clean
- rounded cards
- soft blue/white background
- minimal icon set
- friendly but still developer-focused
- logo placeholder text: `MEOW AGENT`

Suggested colors:

```txt
Background: #F4FAFF
Card: #EAF6FF
Primary: #7DB9E8
Text: #1F2937
Muted Text: #6B7280
Border: #BFD7EA
Danger: #EF4444
Success: #22C55E
```

---

## Data Models

### LLM Provider Config

```dart
class LlmProviderConfig {
  final String baseUrl;
  final String apiKey;
  final String model;

  LlmProviderConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });
}
```

### Agent

```dart
class AgentModel {
  final String id;
  final String name;
  final String description;
  final String model;
  final List<String> enabledModuleIds;

  AgentModel({
    required this.id,
    required this.name,
    required this.description,
    required this.model,
    required this.enabledModuleIds,
  });
}
```

### Chat Message

```dart
class ChatMessageModel {
  final String id;
  final String role;
  final String content;
  final DateTime createdAt;

  ChatMessageModel({
    required this.id,
    required this.role,
    required this.content,
    required this.createdAt,
  });
}
```

### Module Permission

```dart
class ModulePermission {
  final String moduleId;
  final bool enabled;
  final String safetyLevel;

  ModulePermission({
    required this.moduleId,
    required this.enabled,
    required this.safetyLevel,
  });
}
```

---

## Development Phases

### Phase 1 — App Skeleton

Build:

- Flutter project
- App theme
- Router
- Home screen
- Agent list screen
- Chat screen
- Settings screen
- Dummy module registry

Done when:
User can navigate all screens.

---

### Phase 2 — LLM BYOK

Build:

- LLM provider settings form
- Secure API key storage
- OpenAI-compatible chat completion client
- Test connection button
- Basic chat response

Done when:
User can chat with configured provider.

---

### Phase 3 — Module Permission System

Build:

- Module registry
- Module toggles
- Safety mode setting
- Enabled module state
- Module status display on Home

Done when:
User can enable/disable modules and see status.

---

### Phase 4 — Basic Tool Execution

Build:

- File Module MVP
- Browser Module MVP
- Agent orchestrator that can call module commands
- Action logs

Done when:
Agent can use enabled module actions safely.

---

### Phase 5 — Android Native Modules

Build:

- Notification Listener permission flow
- Intent module placeholder to real Android intent execution
- Background service exploration

Done when:
Agent can react to simple Android events.

---

### Phase 6 — VM Module

Build:

- VM install screen
- proot Ubuntu integration research
- command runner
- local web preview

Done when:
Agent can create and run a small web project inside VM environment.

---

## Important Safety Rules

Implement these rules early:

1. Module disabled = agent cannot use it.
2. API key must be stored securely.
3. Sensitive actions require approval.
4. Action logs must be visible.
5. Notification content may contain private data.
6. OTP/password/token should be filtered by default.
7. External network calls should require approval unless user marks domain as trusted.
8. File access should start from app sandbox only.
9. VM shell command should require approval.
10. Never silently send messages, delete files, make payments, or expose private data.

---

## Minimal Acceptance Criteria

The project is considered MVP-ready when:

- App runs on Android.
- User can configure OpenAI-compatible LLM provider.
- API key is stored securely.
- User can chat with the agent.
- User can enable/disable modules.
- Home screen shows module status.
- Settings screen shows provider and permission controls.
- App has at least one working module, preferably File Module or Browser Module.
- Code structure is modular enough for future modules.

---

## First Task for Coding Agent

Start by creating the Flutter app skeleton.

Required output:

1. Create Flutter project structure.
2. Implement app theme.
3. Implement navigation.
4. Implement these screens:
   - HomeScreen
   - AgentListScreen
   - ChatScreen
   - SettingsScreen
5. Implement dummy module registry.
6. Implement LLM settings model.
7. Implement placeholder OpenAI-compatible client.
8. Add README section explaining how to run.

Do not implement proot Ubuntu yet.
Do not implement Ollama/local LLM yet.
Do not implement full Android automation yet.

Focus on clean foundation first.
