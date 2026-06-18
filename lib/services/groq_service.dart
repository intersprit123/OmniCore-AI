import 'dart:async';
import 'dart:developer' as dev;

import '../config/backend_config.dart';
import '../config/groq_config.dart';
import 'ai_generation.dart';
import 'chat_completion_stream_client.dart';

/// Service class for interacting with the Groq API.
class GroqService {
  static final String _apiKey =
      const String.fromEnvironment('GROQ_API_KEY').isNotEmpty
          ? const String.fromEnvironment('GROQ_API_KEY')
          : GroqConfig.apiKey;

  static const String _defaultEndpoint =
      'https://api.groq.com/openai/v1/chat/completions';
  static const String _envEndpoint = String.fromEnvironment(
    'GROQ_API_ENDPOINT',
    defaultValue: '',
  );

  static final String _endpoint = GroqConfig.endpoint.isNotEmpty
      ? GroqConfig.endpoint
      : _envEndpoint.isNotEmpty
          ? _envEndpoint
          : BackendConfig.groqEndpoint;

  static bool get _usesProxyEndpoint => _endpoint != _defaultEndpoint;

  static bool get isConfigured => _apiKey.isNotEmpty || _usesProxyEndpoint;
  static String get endpoint => _endpoint;
  static bool get usesProxyEndpoint => _usesProxyEndpoint;

  static const bool _forceNonStreaming = bool.fromEnvironment(
    'OMNICORE_FORCE_NON_STREAMING',
    defaultValue: false,
  );

  static AIGeneration streamMessageWithModel(
    String prompt,
    String model, {
    double temperature = 0.7,
    int maxTokens = 1024,
    Duration timeout = const Duration(seconds: 60),
  }) {
    if (_apiKey.isEmpty && !_usesProxyEndpoint) {
      return AIGeneration.error(
        'Groq API key not configured. Set GROQ_API_KEY or use the local backend.',
        provider: 'Groq',
        model: model,
      );
    }

    if (_forceNonStreaming) {
      dev.log('Groq debug mode: forcing non-streaming completion path');
      final controller = StreamController<String>();
      var cancelled = false;

      controller.onListen = () async {
        try {
          final response = await sendMessageWithModel(prompt, model);
          if (!cancelled && response.isNotEmpty) {
            dev.log(
              'Groq debug mode: non-stream response forwarded as one chunk length=${response.length}',
            );
            controller.add(response);
          }
        } catch (error, stackTrace) {
          if (!cancelled) {
            dev.log(
              'Groq debug mode: non-stream completion failed',
              error: error,
              stackTrace: stackTrace,
            );
            controller.addError(error);
          }
        } finally {
          if (!controller.isClosed) await controller.close();
        }
      };

      Future<void> cancel() async {
        cancelled = true;
        if (!controller.isClosed) await controller.close();
      }

      return AIGeneration(
        stream: controller.stream,
        cancel: cancel,
        provider: 'Groq',
        model: model,
      );
    }

    return ChatCompletionStreamClient.stream(
      endpoint: Uri.parse(_endpoint),
      headers: _headers(),
      body: {
        'model': model,
        'messages': [
          {'role': 'user', 'content': prompt},
        ],
        'temperature': temperature,
        'max_tokens': maxTokens,
      },
      provider: 'Groq',
      model: model,
      timeout: timeout,
    );
  }

  /// Sends a user [prompt] to the Groq model with a specific model and returns
  /// the response. Kept for backward compatibility with older router callers.
  static Future<String> sendMessageWithModel(
      String prompt, String model) async {
    if (_apiKey.isEmpty && !_usesProxyEndpoint) {
      return 'Groq API key not configured. Set GROQ_API_KEY or use the local backend.';
    }

    try {
      final response = await ChatCompletionStreamClient.complete(
        endpoint: Uri.parse(_endpoint),
        headers: _headers(),
        body: {
          'model': model,
          'messages': [
            {'role': 'user', 'content': prompt},
          ],
          'temperature': 0.7,
          'max_tokens': 1024,
        },
        provider: 'Groq',
        model: model,
      );
      return response.isEmpty
          ? 'Sorry, the AI response was empty. Please try again.'
          : response;
    } on AIServiceException catch (error) {
      return error.message;
    }
  }

  /// Existing method kept for backward compatibility.
  static Future<String> sendMessage(String prompt) async {
    return sendMessageWithModel(prompt, 'llama-3.3-70b-versatile');
  }

  static Map<String, String> _headers() {
    final headers = {
      'Accept': 'text/event-stream',
      'Content-Type': 'application/json',
    };
    if (_apiKey.isNotEmpty) {
      headers['Authorization'] = 'Bearer $_apiKey';
    }
    return headers;
  }
}
