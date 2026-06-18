import 'dart:developer' as dev;

import '../models/ai_memory.dart';
import '../models/ai_provider.dart';
import 'ai_generation.dart';
import 'ai_orchestrator.dart';
import 'groq_service.dart';
import 'runtime_diagnostics.dart';

/// Router to dispatch prompts to the selected AI provider while preserving the
/// existing OmniCore modes.
class AIRouter {
  static const String _providerPreference = String.fromEnvironment(
    'OMNICORE_AI_PROVIDER',
    defaultValue: 'auto',
  );

  static AIGeneration streamMessage(
    String prompt,
    String mode, {
    List<OmniMemory> memories = const [],
    RetrievalPreference retrievalPreference = RetrievalPreference.auto,
  }) {
    final route = _routeForMode(mode);
    if (route == null) {
      return AIGeneration.error(
        'No AI provider is configured. Start the local backend or set GROQ_API_KEY.',
        provider: 'OmniCore',
      );
    }

    dev.log(
      'AIRouter: mode=${route.mode}, provider=${route.provider.name}, model=${route.model}',
    );
    RuntimeDiagnostics.routeSelected(
      model: route.model,
      backendUrl: GroqService.endpoint,
      decision:
          'Groq -> ${route.model} (${route.mode}); retrieval ${retrievalPreference.label}',
    );

    return AIOrchestrator.streamMessage(
      prompt: prompt,
      mode: route.mode,
      primaryRoute: route,
      fallbackRoute: _fallbackRouteFor(route),
      memories: memories,
      retrievalPreference: retrievalPreference,
    );
  }

  /// Backward-compatible non-streaming entry point.
  static Future<String> sendMessage(
    String prompt,
    String mode, {
    List<OmniMemory> memories = const [],
    RetrievalPreference retrievalPreference = RetrievalPreference.auto,
  }) async {
    final generation = streamMessage(
      prompt,
      mode,
      memories: memories,
      retrievalPreference: retrievalPreference,
    );
    final buffer = StringBuffer();
    try {
      await for (final chunk in generation.stream) {
        buffer.write(chunk);
      }
      final response = buffer.toString().trim();
      return response.isEmpty
          ? 'Sorry, the AI response was empty. Please try again.'
          : response;
    } on AIServiceException catch (error) {
      return error.message;
    } finally {
      await generation.cancel();
    }
  }

  static AIRoute? _routeForMode(String mode) {
    final normalizedMode = _normalizeMode(mode);
    final preference = _providerPreference.toLowerCase().trim();

    if (preference != 'auto' && preference != 'groq') {
      dev.log(
        'AIRouter: "$preference" is not a generation provider; using Groq when configured.',
      );
    }

    if (!GroqService.isConfigured) {
      return null;
    }

    switch (normalizedMode) {
      case 'Fast':
      case 'Creative':
      case 'Smart':
      case 'Code':
      case 'Auto':
        return _groqRoute(normalizedMode);
      default:
        return _groqRoute('Smart');
    }
  }

  static AIRoute? _fallbackRouteFor(AIRoute primaryRoute) {
    switch (primaryRoute.provider) {
      case AIProviderType.groq:
        return null;
    }
  }

  static AIRoute _groqRoute(String mode) {
    return AIRoute(
      provider: AIProviderType.groq,
      model: _groqModelForMode(mode),
      mode: mode,
    );
  }

  static String _normalizeMode(String mode) {
    switch (mode) {
      case 'Fast':
      case 'Smart':
      case 'Code':
      case 'Creative':
      case 'Auto':
        return mode;
      default:
        return 'Smart';
    }
  }

  static String _groqModelForMode(String mode) {
    switch (mode) {
      case 'Fast':
        return 'llama-3.1-8b-instant';
      case 'Creative':
        return 'llama-3.3-70b-versatile';
      case 'Smart':
      case 'Code':
      case 'Auto':
      default:
        return 'llama-3.3-70b-versatile';
    }
  }
}
