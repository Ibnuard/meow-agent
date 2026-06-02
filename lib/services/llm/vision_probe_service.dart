import '../../features/settings/data/llm_provider_config.dart';
import 'openai_compatible_client.dart';

/// Lazy vision capability probe with in-memory + persistent cache.
///
/// Instead of checking vision support at model-add time (which produced
/// many false positives due to unreliable provider metadata), this service
/// probes at runtime — only when the user actually attaches an image.
///
/// The probe sends a tiny 1x1 red pixel PNG and asks the model to identify
/// the color. If the API call succeeds AND the response contains "red",
/// the model definitively supports vision. Results are cached per
/// `baseUrl|model` so the probe only runs once per model.
class VisionProbeService {
  VisionProbeService._();
  static final VisionProbeService instance = VisionProbeService._();

  final Map<String, bool> _cache = {};

  /// A 1x1 solid red PNG encoded as base64 data URL.
  /// Chosen because "red" is unambiguous across languages and models.
  static const String _redPixelDataUrl =
      'data:image/png;base64,'
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
      'z8BQDwADhQGAWjR9awAAAABJRU5ErkJggg==';

  static const String _probePrompt =
      'What color is this image? Reply with exactly one word.';

  /// Returns the cache key for a given provider config.
  static String _cacheKey(LlmProviderConfig config) =>
      '${config.baseUrl}|${config.model}';

  /// Check if the model supports vision. Returns cached result if available,
  /// otherwise runs a live probe.
  ///
  /// [client] — the LLM client to use for the probe call.
  /// [config] — provider config (baseUrl, apiKey, model).
  ///
  /// Returns `true` if the model can process images, `false` otherwise.
  /// Never throws — failures are treated as "not supported".
  Future<bool> probe({
    required OpenAiCompatibleClient client,
    required LlmProviderConfig config,
  }) async {
    final key = _cacheKey(config);

    // Return cached result immediately.
    if (_cache.containsKey(key)) return _cache[key]!;

    // Run the probe: send a red pixel and check if response mentions "red".
    try {
      final response = await client.chatWithImage(
        config: config,
        prompt: _probePrompt,
        imageDataUrl: _redPixelDataUrl,
        phase: 'vision_probe',
      );
      // Check if the model's response contains "red" (case-insensitive).
      // This confirms the model actually processed the image content,
      // not just accepted the API call without error.
      final supportsVision =
          response.toLowerCase().contains('red');
      _cache[key] = supportsVision;
      return supportsVision;
    } catch (_) {
      // Any error (400, 422, timeout, etc.) means no vision support.
      _cache[key] = false;
      return false;
    }
  }

  /// Check cached result without running a probe. Returns `null` if
  /// no cached result exists for this config.
  bool? getCached(LlmProviderConfig config) => _cache[_cacheKey(config)];

  /// Manually set cache (useful for testing or explicit override).
  void setCache(LlmProviderConfig config, bool value) {
    _cache[_cacheKey(config)] = value;
  }

  /// Clear all cached results.
  void clearCache() => _cache.clear();
}
