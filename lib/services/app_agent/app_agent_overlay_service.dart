import 'package:flutter/services.dart';

/// Bridge to the native [AppAgentOverlayService] which renders a colored
/// border around the screen plus a narrator bar pinned ~10% from the bottom.
///
/// Calls are fire-and-forget so the runtime never blocks on overlay UX.
class AppAgentOverlayService {
  AppAgentOverlayService._();

  static const _channel = MethodChannel('com.meowagent/app_agent_overlay');

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
    _channel.invokeMethod<void>('hide').catchError((_) => null);
  }
}
