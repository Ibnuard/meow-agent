import '../../features/settings/data/llm_provider_config.dart';
import 'openai_compatible_client.dart';

/// Lazy vision capability probe — validates actual image comprehension.
///
/// Sends a solid red 1x1 PNG and asks the model to identify the color.
/// If the model responds with "red", it truly sees the image content.
/// This distinguishes models that accept image_url format but ignore
/// the image from models that actually process visual input.
class VisionProbeService {
  VisionProbeService._();
  static final VisionProbeService instance = VisionProbeService._();

  /// A 1x1 solid red PNG (RGB 255,0,0) encoded as base64 data URL.
  static const String _probeRedImageDataUrl =
      'data:image/png;base64,'
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4'
      '2mP8z8BQDwADhQGAWjR9awAAAABJRU5ErkJggg==';

  static const String _probePrompt =
      'What is the dominant color of this image? Reply with exactly one word.';

  /// Probe whether the model truly supports vision by verifying it can
  /// identify the color of a red pixel. Returns `true` only if the model
  /// responds with "red". Never throws.
  Future<bool> probe({
    required OpenAiCompatibleClient client,
    required LlmProviderConfig config,
  }) async {
    try {
      final reply = await client.chatWithImage(
        config: config,
        prompt: _probePrompt,
        imageDataUrl: _probeRedImageDataUrl,
        phase: 'vision_probe',
      );

      final normalized = reply.trim().toLowerCase();

      // Model must prove it saw the image by identifying the color.
      if (normalized.contains('red')) {
        return true;
      }

      // Request succeeded but model didn't see/understand the image.
      return false;
    } catch (_) {
      // API error (400, 422, timeout) — no vision support.
      return false;
    }
  }
}
