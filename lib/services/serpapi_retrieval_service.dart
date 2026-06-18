import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;

import 'package:http/http.dart' as http;

import '../config/serpapi_config.dart';
import '../models/tool_result.dart';
import 'cancellation_token.dart';

class SerpApiRetrievalService {
  static String get _configuredRetrievalEndpoint =>
      SerpApiConfig.retrievalEndpoint;

  static const Duration _timeout = Duration(seconds: 18);

  static bool get isAvailable => _configuredRetrievalEndpoint.isNotEmpty;

  static Future<ToolResult> retrieve({
    required String prompt,
    required String mode,
    required CancellationToken cancellationToken,
  }) async {
    final stopwatch = Stopwatch()..start();
    if (cancellationToken.isCancelled) {
      return const ToolResult(
        toolId: 'serpapi-retrieval',
        title: 'Live Search',
        status: ToolResultStatus.skipped,
      );
    }

    if (!isAvailable) {
      return const ToolResult(
        toolId: 'serpapi-retrieval',
        title: 'Live Search',
        status: ToolResultStatus.unavailable,
        error: 'SerpApi retrieval is not configured.',
      );
    }

    final client = http.Client();
    cancellationToken.onCancel(client.close);

    try {
      final response = await client
          .post(
            Uri.parse(_configuredRetrievalEndpoint),
            headers: _proxyHeaders(),
            body: jsonEncode({
              'query': prompt,
              'mode': mode,
              'max_results': 5,
            }),
          )
          .timeout(_timeout);
      stopwatch.stop();
      dev.log(
        'SerpApi retrieval completed in ${stopwatch.elapsedMilliseconds}ms',
      );

      if (cancellationToken.isCancelled) {
        return const ToolResult(
          toolId: 'serpapi-retrieval',
          title: 'Live Search',
          status: ToolResultStatus.skipped,
        );
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return ToolResult(
          toolId: 'serpapi-retrieval',
          title: 'Live Search',
          status: ToolResultStatus.failed,
          error: 'Retrieval endpoint returned ${response.statusCode}.',
        );
      }

      return _parseProxyResponse(response.body);
    } on TimeoutException {
      stopwatch.stop();
      dev.log(
        'SerpApi retrieval timed out after ${stopwatch.elapsedMilliseconds}ms',
      );
      return const ToolResult(
        toolId: 'serpapi-retrieval',
        title: 'Live Search',
        status: ToolResultStatus.failed,
        error: 'Retrieval timed out.',
      );
    } catch (_) {
      stopwatch.stop();
      if (cancellationToken.isCancelled) {
        return const ToolResult(
          toolId: 'serpapi-retrieval',
          title: 'Live Search',
          status: ToolResultStatus.skipped,
        );
      }
      return const ToolResult(
        toolId: 'serpapi-retrieval',
        title: 'Live Search',
        status: ToolResultStatus.failed,
        error: 'Retrieval endpoint is unavailable.',
      );
    } finally {
      client.close();
    }
  }

  static ToolResult _parseProxyResponse(String responseBody) {
    final decoded = jsonDecode(responseBody);
    if (decoded is! Map<String, dynamic>) {
      return const ToolResult(
        toolId: 'serpapi-retrieval',
        title: 'Live Search',
        status: ToolResultStatus.failed,
        error: 'Retrieval response was invalid.',
      );
    }

    final sources = <ToolSource>[];
    final results = decoded['results'];
    if (results is List) {
      for (final item in results) {
        if (item is Map<String, dynamic>) {
          sources.add(ToolSource.fromJson(item));
        }
      }
    }

    final answer = decoded['answer'] as String?;
    final summary = decoded['summary'] as String?;
    final content = [
      if (answer != null && answer.trim().isNotEmpty) answer.trim(),
      if (summary != null && summary.trim().isNotEmpty) summary.trim(),
      for (final source in sources.take(5))
        [
          source.title,
          if (source.snippet != null) source.snippet!,
          source.url,
        ].join('\n'),
    ].join('\n\n').trim();

    if (content.isEmpty) {
      return const ToolResult(
        toolId: 'serpapi-retrieval',
        title: 'Live Search',
        status: ToolResultStatus.failed,
        error: 'Retrieval response was empty.',
      );
    }

    return ToolResult(
      toolId: 'serpapi-retrieval',
      title: 'Live Search',
      status: ToolResultStatus.success,
      content: content,
      sources: sources,
    );
  }

  static Map<String, String> _proxyHeaders() {
    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'X-OmniCore-Client': 'flutter-web',
    };
  }
}
