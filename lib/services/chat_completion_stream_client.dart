import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;

import 'package:http/http.dart' as http;

import 'ai_generation.dart';
import 'runtime_diagnostics.dart';

class ChatCompletionStreamClient {
  static const Duration _requestTimeout = Duration(seconds: 90);
  static const Duration _streamIdleTimeout = Duration(seconds: 120);

  static Duration _maxDuration(Duration a, Duration b) {
    return a.inMicroseconds >= b.inMicroseconds ? a : b;
  }

  static AIGeneration stream({
    required Uri endpoint,
    required Map<String, String> headers,
    required Map<String, dynamic> body,
    required String provider,
    required String model,
    Duration timeout = const Duration(seconds: 90),
  }) {
    final client = http.Client();
    late StreamController<String> controller;
    var cancelled = false;
    var closed = false;
    final requestStopwatch = Stopwatch()..start();
    final streamStopwatch = Stopwatch();

    Future<void> closeController() async {
      if (closed || controller.isClosed) return;
      closed = true;
      await controller.close();
    }

    Future<void> cancel() async {
      if (cancelled) return;
      cancelled = true;
      client.close();
      await closeController();
    }

    controller = StreamController<String>(
      onListen: () async {
        var emittedText = false;
        var chunkCount = 0;
        try {
          final requestBody = Map<String, dynamic>.from(body)
            ..['stream'] = true;
          dev.log(
            '$provider stream opened to ${endpoint.toString()} with model=$model',
          );
          final request = http.Request('POST', endpoint)
            ..headers.addAll(headers)
            ..body = jsonEncode(requestBody);

          final response = await client
              .send(request)
              .timeout(_maxDuration(timeout, _requestTimeout));
          if (cancelled) return;
          streamStopwatch.start();
          dev.log(
            '$provider request headers received in ${requestStopwatch.elapsedMilliseconds}ms',
          );

          if (response.statusCode < 200 || response.statusCode >= 300) {
            final errorBody = await _safeReadErrorBody(response);
            RuntimeDiagnostics.providerResponse(
              provider: provider,
              statusCode: response.statusCode,
              details: _trimDetails(errorBody),
            );
            throw AIServiceException(
              _statusMessage(provider, response.statusCode),
              statusCode: response.statusCode,
              details: _trimDetails(errorBody),
            );
          }

          RuntimeDiagnostics.providerResponse(
            provider: provider,
            statusCode: response.statusCode,
          );

          final lines = response.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .timeout(_maxDuration(timeout, _streamIdleTimeout));

          await for (final rawLine in lines) {
            if (cancelled) break;
            final line = rawLine.trim();
            dev.log('$provider stream raw line: ${_preview(line)}');
            if (line.isEmpty || line.startsWith(':')) continue;

            final payload =
                line.startsWith('data:') ? line.substring(5).trim() : line;

            if (payload == '[DONE]') break;

            final text = _extractText(payload);
            dev.log(
              '$provider stream parsed payload; deltaLength=${text?.length ?? 0}',
            );
            if (text == null || text.isEmpty) continue;

            emittedText = true;
            chunkCount++;
            dev.log(
              '$provider chunk received #$chunkCount size=${text.length} text=${_preview(text)}',
            );
            controller.add(text);
            dev.log('$provider chunk forwarded #$chunkCount');
          }

          if (!cancelled && !emittedText) {
            throw const AIServiceException(
              'Sorry, the AI response was empty. Please try again.',
            );
          }
          if (!cancelled) {
            dev.log(
              '$provider stream completed in ${streamStopwatch.elapsedMilliseconds}ms with $chunkCount chunks',
            );
          }
        } on TimeoutException {
          if (!cancelled) {
            final elapsed = requestStopwatch.elapsedMilliseconds;
            final source = streamStopwatch.isRunning
                ? 'stream idle timeout after ${streamStopwatch.elapsedMilliseconds}ms'
                : 'request timeout after ${elapsed}ms';
            RuntimeDiagnostics.timeoutRecorded(source);
            dev.log('$provider timed out: $source');
            controller.addError(
              AIServiceException(
                '$provider took too long to respond. Please try again.',
                isTimeout: true,
              ),
            );
          }
        } on AIServiceException catch (error) {
          if (!cancelled) controller.addError(error);
        } catch (error, stackTrace) {
          if (!cancelled) {
            dev.log(
              '$provider streaming request failed',
              error: error,
              stackTrace: stackTrace,
            );
            controller.addError(
              AIServiceException(
                'Sorry, $provider is unavailable right now. Please try again.',
              ),
            );
          }
        }
      finally {
        client.close();
        if (streamStopwatch.isRunning) {
          streamStopwatch.stop();
          RuntimeDiagnostics.streamTimingFinished();
        }
        await closeController();
      }
    },
      onCancel: () {
        cancelled = true;
        client.close();
      },
    );

    return AIGeneration(
      stream: controller.stream,
      cancel: cancel,
      provider: provider,
      model: model,
    );
  }

  static Future<String> complete({
    required Uri endpoint,
    required Map<String, String> headers,
    required Map<String, dynamic> body,
    required String provider,
    required String model,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final client = http.Client();
    final requestBody = Map<String, dynamic>.from(body)..['stream'] = false;
    final stopwatch = Stopwatch()..start();
    dev.log(
      '$provider non-stream request opened to ${endpoint.toString()} with model=$model',
    );

    try {
      final response = await client
          .post(
            endpoint,
            headers: headers,
            body: jsonEncode(requestBody),
          )
          .timeout(timeout);

      dev.log(
        '$provider non-stream response status=${response.statusCode} in ${stopwatch.elapsedMilliseconds}ms',
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        RuntimeDiagnostics.providerResponse(
          provider: provider,
          statusCode: response.statusCode,
          details: _trimDetails(response.body),
        );
        throw AIServiceException(
          _statusMessage(provider, response.statusCode),
          statusCode: response.statusCode,
          details: _trimDetails(response.body),
        );
      }

      RuntimeDiagnostics.providerResponse(
        provider: provider,
        statusCode: response.statusCode,
      );

      final text = _extractText(response.body) ?? '';
      dev.log('$provider non-stream extracted text length=${text.length}');
      return text.trim();
    } finally {
      client.close();
    }
  }

  static Future<String> _safeReadErrorBody(http.StreamedResponse response) {
    return response.stream.bytesToString().timeout(
          const Duration(seconds: 8),
          onTimeout: () => '',
        );
  }

  static String _statusMessage(String provider, int statusCode) {
    if (statusCode == 401 || statusCode == 403) {
      return '$provider could not authenticate. Check the API key configuration.';
    }
    if (statusCode == 408 || statusCode == 504) {
      return '$provider took too long to respond. Please try again.';
    }
    if (statusCode == 429) {
      return '$provider is rate limited right now. Please wait a moment and try again.';
    }
    if (statusCode >= 500) {
      return '$provider is temporarily unavailable. Please try again shortly.';
    }
    return '$provider returned an invalid request response. Please try again.';
  }

  static String? _extractText(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) return null;

      final choices = decoded['choices'];
      if (choices is List && choices.isNotEmpty) {
        final first = choices.first;
        if (first is Map<String, dynamic>) {
          final delta = first['delta'];
          final deltaText = _contentFromMap(delta);
          if (deltaText != null) return deltaText;

          final message = first['message'];
          final messageText = _contentFromMap(message);
          if (messageText != null) return messageText;

          final text = first['text'];
          if (text is String) return text;
        }
      }

      final outputText = decoded['output_text'];
      if (outputText is String) return outputText;
    } on FormatException {
      return null;
    }

    return null;
  }

  static String? _contentFromMap(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final content = value['content'];
    if (content is String) return content;
    if (content is List) {
      final buffer = StringBuffer();
      for (final part in content) {
        if (part is Map<String, dynamic>) {
          final text = part['text'];
          if (text is String) buffer.write(text);
        }
      }
      final result = buffer.toString();
      return result.isEmpty ? null : result;
    }
    return null;
  }

  static String? _trimDetails(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return trimmed.length > 500 ? trimmed.substring(0, 500) : trimmed;
  }

  static String _preview(String text) {
    final normalized = text.replaceAll('\n', r'\n');
    return normalized.length <= 120
        ? normalized
        : '${normalized.substring(0, 120)}...';
  }
}
