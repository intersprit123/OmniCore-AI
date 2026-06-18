import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omnicore_ai/services/chat_completion_stream_client.dart';

void main() {
  test('stream client cancels an active SSE response cleanly', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverSubscription = server.listen((request) {
      unawaited(_writeSlowStream(request));
    });

    StreamSubscription<String>? streamSubscription;
    try {
      final generation = ChatCompletionStreamClient.stream(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/chat'),
        headers: const {'Content-Type': 'application/json'},
        body: const {
          'model': 'mock-model',
          'messages': [
            {'role': 'user', 'content': 'stream please'}
          ],
        },
        provider: 'Mock',
        model: 'mock-model',
        timeout: const Duration(seconds: 3),
      );

      final chunks = <String>[];
      final firstChunk = Completer<void>();
      streamSubscription = generation.stream.listen((chunk) {
        chunks.add(chunk);
        if (!firstChunk.isCompleted) firstChunk.complete();
      });

      await firstChunk.future.timeout(const Duration(seconds: 3));
      await generation.cancel();
      await streamSubscription.cancel();
      final countAfterCancel = chunks.length;
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(chunks.first, 'mock ');
      expect(chunks.length, countAfterCancel);
    } finally {
      await streamSubscription?.cancel();
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });
}

Future<void> _writeSlowStream(HttpRequest request) async {
  try {
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    );

    for (final chunk in const ['mock ', 'stream ', 'partial']) {
      request.response.write(
        'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': chunk}
                }
              ]
            })}\n\n',
      );
      await request.response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }

    request.response.write('data: [DONE]\n\n');
    await request.response.close();
  } catch (_) {
    // The client closing the connection is the expected cancellation path.
  }
}
