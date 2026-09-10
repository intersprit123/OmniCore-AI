import 'dart:developer' as dev;

import '../models/ai_memory.dart';
import '../models/ai_provider.dart';
import '../models/file_attachment.dart';
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

    final enrichedPrompt = _enrichFileAttachments(prompt);

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
      prompt: enrichedPrompt,
      mode: route.mode,
      primaryRoute: route,
      fallbackRoute: _fallbackRouteFor(route),
      memories: memories,
      retrievalPreference: retrievalPreference,
    );
  }

  /// Adds the locally captured contents of supported text attachments to the
  /// prompt. Binary/unsupported files remain metadata-only rather than being
  /// misrepresented as readable text.
  static String _enrichFileAttachments(String prompt) {
    if (!prompt.contains('Attached files:')) return prompt;

    final lines = prompt.split('\n');
    final enriched = StringBuffer(prompt);
    var addedContent = false;

    for (final line in lines) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('- ')) continue;
      if (!trimmed.endsWith(')')) continue;

      final separator = trimmed.lastIndexOf(' (');
      if (separator <= 2) continue;

      final fileName = trimmed.substring(2, separator).trim();
      if (fileName.isEmpty) continue;

      final content = FileAttachment.contentForName(fileName);
      if (content == null) continue;

      if (!addedContent) {
        enriched.write('\n\n--- ATTACHED FILE CONTENT ---');
        addedContent = true;
      }
      enriched.write('\n\n[File: $fileName]\n');
      enriched.write(content);
      enriched.write('\n[End file: $fileName]');
    }

    return enriched.toString();
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
        return 'openai/gpt-oss-20b';
      case 'Creative':
      case 'Smart':
      case 'Code':
      case 'Auto':
      default:
        return 'openai/gpt-oss-120b';
    }
  }
}
