# Meow Agent

Android-native agentic AI app, built with Flutter. Bring-your-own-key, modular, and permission-aware.

## Status

This is the Phase 1 skeleton:

- App theme, navigation shell, and bottom-nav.
- First-launch flow: Home → Set Up (Master Agent) → Home (empty modules placeholder).
- OpenAI-compatible LLM client with `Test` and chat support.
- Secure storage for the API key (Android EncryptedSharedPreferences).

## Initial Flow

1. User opens the app for the first time.
2. Home shows the logo, the bottom bar, and a centered **Set Up** button.
3. Tapping **Set Up** opens the Setup screen, where the user enters Base URL, API Key, and Model for an OpenAI-compatible provider.
4. After saving, the user returns to Home, which now shows an empty Modules placeholder (modules will be added in later phases).
5. Chat tab lists `Agent 1` (default) and lets the user chat with the configured provider.
6. Settings tab shows the configured Master Agent with options to Edit or Remove.

## Project Structure

```
lib/
  main.dart
  app/
    app shell, theme, router
  core/
    storage/   (secure + shared_preferences wrappers)
  features/
    home/      (Home screen)
    agents/    (Agent list)
    chat/      (Chat screen)
    settings/  (Setup screen, settings, master agent repo)
  services/
    llm/       (OpenAI-compatible client)
```

## Tech Stack

- Flutter 3.41 / Dart 3.11
- `flutter_riverpod` for state management
- `go_router` for navigation
- `dio` for HTTP
- `flutter_secure_storage` (API key) + `shared_preferences` (non-sensitive config)
- `google_fonts` for Inter typography

## Running

Requirements:

- Flutter SDK installed and on `PATH`
- An Android device or emulator (minSdk 23+)

Install deps:

```sh
flutter pub get
```

Run on a connected device:

```sh
flutter run
```

Run static analysis and tests:

```sh
flutter analyze
flutter test
```

## Configuring the Master Agent

On first launch, tap **Set Up** and provide:

- **Base URL**: e.g. `https://api.openai.com/v1` or any OpenAI-compatible endpoint
- **API Key**: stored in encrypted local storage, never logged
- **Model**: e.g. `gpt-4.1-mini`

Use **Test** to validate credentials before saving.

## What's Not Implemented Yet

Per `INSTRUCTION.md`, the following are intentionally deferred:

- proot Ubuntu / VM Module
- Ollama / local LLM
- Notification listener service
- Real Android Intent execution
- Background service
- Module action logs / approval UI

Future phases will plug these into the existing module registry once it's added.
