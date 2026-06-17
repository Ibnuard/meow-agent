import 'package:flutter/services.dart';

/// Bridge to the native [AppAgentOverlayService] which renders a colored
/// border around the screen plus a narrator bar pinned ~10% from the bottom.
///
/// Calls are fire-and-forget so the runtime never blocks on overlay UX.
class AppAgentOverlayService {
  AppAgentOverlayService._();

  static const _channel = MethodChannel('com.meowagent/app_agent_overlay');
  static const _appControlChannel = MethodChannel('com.meowagent/app_control');
  static const _selfPackage = 'com.meowagent.meow_agent';

  /// Whether the overlay is currently shown — i.e. the agent is mid-flight
  /// driving an external app. Used by abort/error paths to decide whether the
  /// user must be returned to Meow Agent (RTB) on top of hiding the border.
  static bool get isActive => _active;
  static bool _active = false;

  /// Callback invoked when the user presses the stop button on the overlay.
  /// Registered by the chat runtime manager on init.
  static void Function()? onStopPressed;

  /// Must be called once during app init to wire up native → Dart events.
  static void initialize() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onStopPressed') {
        onStopPressed?.call();
      }
    });
  }

  /// Show or refresh the overlay with the given operation tag and narrative.
  ///
  /// The [operation] tag drives the border color (e.g. `inspect`, `click`,
  /// `set_text`, `scroll`, `open`, `review`). [narrative] is a short, casual
  /// progress sentence in the user's language.
  static void show({String? operation, String? narrative}) {
    _active = true;
    final text = narrative?.trim() ?? '';
    // Fire-and-forget: do not await, do not surface errors.
    _channel
        .invokeMethod<void>('show', {
          'narrative': text,
          ...?(operation == null ? null : {'operation': operation}),
        })
        .catchError((_) {
          // Overlay is optional; automation must continue without it.
          return null;
        });
  }

  /// Tear down the overlay. Safe to call when nothing is showing.
  static void hide() {
    _active = false;
    _channel.invokeMethod<void>('hide').catchError((_) => null);
  }

  /// Abort path for agentic mode: hide the border AND, if the overlay was
  /// active (the user is stranded in an external app), navigate back to Meow
  /// Agent. Used when a turn fails/cancels mid-flight — e.g. a provider/LLM
  /// error during app automation — so the user is never left looking at a dead
  /// purple border on someone else's app.
  ///
  /// No-op RTB when the overlay was not active (normal chat-only failures stay
  /// where they are). Fire-and-forget; never throws.
  static void hideAndReturnToBase() {
    final wasActive = _active;
    hide();
    if (!wasActive) return;
    _appControlChannel
        .invokeMethod<bool>('openApp', {'package': _selfPackage})
        .catchError((_) => false);
  }
}
