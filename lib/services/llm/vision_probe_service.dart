import '../../features/settings/data/llm_provider_config.dart';
import 'openai_compatible_client.dart';

/// Lazy vision capability probe with session cache.
///
/// Sends a known-color 1x1 PNG (solid red) and forces an English single-word
/// answer. Validates that the model actually identifies the color — proving
/// it can see the image, not just accept the API format.
///
/// Cache policy:
///   * Positive results are cached per (baseUrl, model) for the session.
///     Once a model is proven vision-capable, we never re-probe it.
///   * Negative results are NOT cached. Failures may be transient (rate
///     limits, network, provider hiccups), and a future retry could succeed.
///   * Cache resets on app restart by design.
class VisionProbeService {
  VisionProbeService._();
  static final VisionProbeService instance = VisionProbeService._();

  /// 1x1 solid red PNG, base64 encoded.
  static const String _probeRedImageDataUrl =
      'data:image/png;base64,'
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4'
      '2mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==';

  /// English-only prompt forces a deterministic answer. Asking in the user's
  /// language risks color names like "merah"/"红色"/etc. — by pinning the
  /// reply language to English we get a single-token "red" we can validate
  /// reliably across providers.
  static const String _probePrompt =
      'Reply in English with exactly one lowercase word. '
      'What is the dominant color of this image?';

  /// Session-level positive cache. Key: "baseUrl|model".
  final Map<String, bool> _positiveCache = {};

  String _cacheKey(LlmProviderConfig config) =>
      '${config.baseUrl}|${config.model}';

  /// Probe whether the model can actually see images.
  ///
  /// Returns `true` only if the model identified the color of the probe
  /// image (i.e. it can genuinely process visual input, not just accept
  /// the API format). Returns `false` on any other outcome — color
  /// mismatch, API error, or unexpected response. Never throws.
  Future<bool> probe({
    required OpenAiCompatibleClient client,
    required LlmProviderConfig config,
  }) async {
    final key = _cacheKey(config);
    if (_positiveCache[key] == true) return true;

    try {
      final reply = await client.chatWithImage(
        config: config,
        prompt: _probePrompt,
        imageDataUrl: _probeRedImageDataUrl,
        phase: 'vision_probe',
      );
      final normalized = reply.trim().toLowerCase();
      // Word-boundary check so "redirect"/"reduced" don't false-positive.
      final hasRed = RegExp(r'\bred\b').hasMatch(normalized);
      if (hasRed) {
        _positiveCache[key] = true;
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Clear the cache. Useful for tests; not normally called in production.
  void resetCache() => _positiveCache.clear();
}
