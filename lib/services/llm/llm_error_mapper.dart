import 'dart:io';

import 'package:dio/dio.dart';

import '../agent_runtime/language_registry.dart';

/// Sentinel that marks an assistant message as a transient provider/network
/// error rather than a real conversational reply.
///
/// Why a sentinel: when an LLM call fails, we still need to surface a
/// user-friendly message in the chat. But on the *next* turn, that message
/// gets loaded back into the conversation history and fed to the LLM as
/// prior context. Without a sentinel the model sees its own past
/// "I can't connect" line and parrots that narrative even after the
/// connection has recovered. The sentinel lets the runtime strip these
/// messages from `recentMessages` before they ever reach the LLM, while the
/// UI strips it before rendering so the user sees clean copy.
const providerErrorSentinel = '[[PROVIDER_ERROR]]';

/// Maps LLM/provider exceptions into user-friendly, localized messages.
///
/// Instead of dumping raw DioException details (status codes, stack traces),
/// this converts HTTP errors from AI providers into clear, actionable copy
/// the user can understand at a glance.
///
/// All phrase keys live in [LanguageRegistry] to support any language.
class LlmErrorMapper {
  LlmErrorMapper._();

  /// Returns a localized, user-friendly error message for the given exception,
  /// prefixed with [providerErrorSentinel] so the runtime can identify and
  /// strip it from future LLM context.
  ///
  /// If [error] is a [DioException], it inspects the status code and type to
  /// select the correct phrase. For all other exception types, falls back to
  /// a generic provider error phrase.
  static String friendlyMessage(Object error, String languageCode) {
    final body = _resolveBody(error, languageCode);
    return '$providerErrorSentinel$body';
  }

  /// True if [content] starts with the provider-error sentinel.
  ///
  /// Used by the runtime to filter these messages out of `recentMessages`
  /// before they're sent to the LLM as context.
  static bool isProviderErrorMessage(String content) =>
      content.startsWith(providerErrorSentinel);

  /// Strips the provider-error sentinel from [content] for display.
  ///
  /// Returns the original string unchanged if the sentinel is not present.
  static String stripSentinel(String content) {
    if (!content.startsWith(providerErrorSentinel)) return content;
    return content.substring(providerErrorSentinel.length);
  }

  // ---------------------------------------------------------------------------

  static String _resolveBody(Object error, String languageCode) {
    if (error is DioException) {
      final key = _phraseKeyForDio(error);
      return LanguageRegistry.phrase(key, languageCode);
    }

    // SocketException / HandshakeException from dart:io (network layer).
    if (error is SocketException || error is HandshakeException) {
      return LanguageRegistry.phrase(
        'runtime_provider_network_error',
        languageCode,
      );
    }

    // Generic fallback.
    return LanguageRegistry.phrase(
      'runtime_provider_unknown_error',
      languageCode,
    );
  }

  /// Determines the [LanguageRegistry] phrase key from a [DioException].
  static String _phraseKeyForDio(DioException e) {
    // Connection-level failures (no response received).
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'runtime_provider_timeout';
      case DioExceptionType.connectionError:
        return 'runtime_provider_network_error';
      case DioExceptionType.cancel:
        return 'runtime_provider_cancelled';
      default:
        break;
    }

    // Response-level failures (HTTP status code present).
    final statusCode = e.response?.statusCode;
    if (statusCode == null) {
      return 'runtime_provider_network_error';
    }

    switch (statusCode) {
      case 401:
        return 'runtime_provider_auth_failed';
      case 403:
        return 'runtime_provider_forbidden';
      case 404:
        return 'runtime_provider_model_not_found';
      case 400:
        return 'runtime_provider_bad_request';
      case 429:
        return 'runtime_provider_rate_limited';
      default:
        if (statusCode >= 500) {
          return 'runtime_provider_server_error';
        }
        return 'runtime_provider_unknown_error';
    }
  }
}
