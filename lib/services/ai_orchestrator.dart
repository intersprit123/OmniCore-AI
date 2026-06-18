import 'dart:async';
import 'dart:developer' as dev;

import '../models/ai_memory.dart';
import '../models/ai_provider.dart';
import '../models/tool_result.dart';
import 'ai_generation.dart';
import 'cancellation_token.dart';
import 'groq_service.dart';
import 'memory_intelligence_service.dart';
import 'runtime_diagnostics.dart';
import 'tool_registry.dart';

class AIOrchestrator {
  static final ToolRegistry _toolRegistry = ToolRegistry();

  static AIGeneration streamMessage({
    required String prompt,
    required String mode,
    required AIRoute primaryRoute,
    AIRoute? fallbackRoute,
    List<OmniMemory> memories = const [],
    RetrievalPreference retrievalPreference = RetrievalPreference.auto,
  }) {
    final cancellationToken = CancellationToken();
    AIGeneration? activeGeneration;
    StreamSubscription<String>? activeSubscription;
    late StreamController<String> controller;
    var closed = false;
    var cancelled = false;

    Future<void> closeController() async {
      if (closed || controller.isClosed) return;
      closed = true;
      await controller.close();
    }

    Future<void> cancel() async {
      if (cancelled) return;
      cancelled = true;
      cancellationToken.cancel();
      RuntimeDiagnostics.streamingCancelled();
      await activeSubscription?.cancel();
      await activeGeneration?.cancel();
      await closeController();
    }

    controller = StreamController<String>(
      onListen: () async {
        var emitted = false;
        AIServiceException? serviceError;

        try {
          RuntimeDiagnostics.startRequest(
            mode: mode,
            retrievalPreference: retrievalPreference,
          );
          final requestStopwatch = Stopwatch()..start();
          dev.log('AIOrchestrator: request started');
          final tools = await _toolRegistry.executeRelevant(
            ToolExecutionRequest(
              prompt: prompt,
              mode: mode,
              cancellationToken: cancellationToken,
              retrievalPreference: retrievalPreference,
            ),
          );
          dev.log(
            'AIOrchestrator: retrieval finished in ${requestStopwatch.elapsedMilliseconds}ms',
          );
          final retrievedTools = tools.where((tool) => tool.hasContext).toList();
          final retrievedSources =
              retrievedTools.expand((tool) => tool.sources).toList();
          final injectedContext = retrievedTools
              .map((tool) => tool.toContextBlock())
              .join('\n\n---\n\n');
          dev.log(
            'AIOrchestrator diagnostics: retrieval executed=${tools.isNotEmpty}, results count=${tools.length}, retrieved sources=${retrievedSources.length}, injected context length=${injectedContext.length}',
          );
          if (tools.isNotEmpty) {
            dev.log(
              'AIOrchestrator retrieved sources: ${retrievedSources.map((source) => '${source.title} | ${source.url}').join(' || ')}',
            );
            dev.log(
              'AIOrchestrator retrieved snippets:\n${_safeLogText(retrievedTools.map((tool) => tool.content.trim()).join('\n\n'))}',
            );
          }
          if (cancelled || cancellationToken.isCancelled) return;

          final enrichedPrompt = composePrompt(
            prompt: prompt,
            mode: mode,
            memories: memories,
            toolResults: tools,
          );
          dev.log(
            'AIOrchestrator final prompt to Groq (${enrichedPrompt.length} chars):\n${_safeLogText(enrichedPrompt)}',
          );
          if (tools.any((tool) => tool.hasContext)) {
            RuntimeDiagnostics.contextInjected(_contextPreview(tools));
          } else {
            RuntimeDiagnostics.contextNotInjected();
          }

          final primaryResult = await _forwardGeneration(
            route: primaryRoute,
            prompt: enrichedPrompt,
            controller: controller,
            cancellationToken: cancellationToken,
            onGeneration: (generation, subscription) {
              activeGeneration = generation;
              activeSubscription = subscription;
            },
          );
          emitted = primaryResult.emitted;
          serviceError = primaryResult.error;

          if (!emitted && fallbackRoute != null && !cancelled) {
            dev.log(
              'AIOrchestrator: primary provider failed or emitted no content; trying fallback.',
            );
            final fallbackResult = await _forwardGeneration(
              route: fallbackRoute,
              prompt: enrichedPrompt,
              controller: controller,
              cancellationToken: cancellationToken,
              onGeneration: (generation, subscription) {
                activeGeneration = generation;
                activeSubscription = subscription;
              },
            );
            emitted = fallbackResult.emitted;
            serviceError = fallbackResult.error;
          }

          if (!cancelled && serviceError != null) {
            RuntimeDiagnostics.streamingFailed(serviceError.message);
            throw serviceError;
          }

          if (!cancelled && !emitted) {
            RuntimeDiagnostics.streamingFailed('Groq emitted no content.');
            throw const AIServiceException(
              'Sorry, the AI response was empty. Please try again.',
            );
          }

          if (!cancelled) {
            RuntimeDiagnostics.streamingFinished();
          }
        } on AIServiceException catch (error) {
          if (!cancelled) {
            RuntimeDiagnostics.streamingFailed(error.message);
            controller.addError(error);
          }
        } catch (error, stackTrace) {
          if (!cancelled) {
            dev.log(
              'AIOrchestrator failed',
              error: error,
              stackTrace: stackTrace,
            );
            controller.addError(
              const AIServiceException(
                'Sorry, OmniCore could not complete this request. Please try again.',
              ),
            );
            RuntimeDiagnostics.streamingFailed(
              'OmniCore could not complete this request.',
            );
          }
        } finally {
          await activeSubscription?.cancel();
          await activeGeneration?.cancel();
          await closeController();
        }
      },
      onCancel: cancel,
    );

    return AIGeneration(
      stream: controller.stream,
      cancel: cancel,
      provider: primaryRoute.provider.name,
      model: primaryRoute.model,
    );
  }

  static Future<_ForwardResult> _forwardGeneration({
    required AIRoute route,
    required String prompt,
    required StreamController<String> controller,
    required CancellationToken cancellationToken,
    required void Function(
      AIGeneration generation,
      StreamSubscription<String> subscription,
    ) onGeneration,
  }) async {
    if (cancellationToken.isCancelled) {
      return const _ForwardResult(emitted: false);
    }

    final generation = _startProviderGeneration(route, prompt);
    RuntimeDiagnostics.generationTimingStarted();
    final generationStopwatch = Stopwatch()..start();
    RuntimeDiagnostics.streamingStarted();
    RuntimeDiagnostics.streamTimingStarted();
    final completer = Completer<_ForwardResult>();
    var emitted = false;

    late StreamSubscription<String> subscription;
    subscription = generation.stream.listen(
      (chunk) {
        if (cancellationToken.isCancelled) return;
        emitted = true;
        dev.log(
          'AIOrchestrator: forwarding provider chunk length=${chunk.length}',
        );
        RuntimeDiagnostics.recordChunk(chunk);
        controller.add(chunk);
      },
      onError: (Object error) {
        if (completer.isCompleted) return;
        if (error is AIServiceException && error.isTimeout) {
          RuntimeDiagnostics.timeoutRecorded(
            'Groq stream after ${generationStopwatch.elapsedMilliseconds}ms',
          );
          dev.log(
            'AIOrchestrator: Groq stream timeout after ${generationStopwatch.elapsedMilliseconds}ms',
          );
        }
        completer.complete(
          _ForwardResult(
            emitted: emitted,
            error: error is AIServiceException
                ? error
                : const AIServiceException(
                    'Sorry, the AI service is unavailable right now. Please try again.',
                  ),
          ),
        );
      },
      onDone: () {
        if (!completer.isCompleted) {
          dev.log(
            'AIOrchestrator: Groq stream completed in ${generationStopwatch.elapsedMilliseconds}ms',
          );
          RuntimeDiagnostics.streamTimingFinished();
          completer.complete(_ForwardResult(emitted: emitted));
        }
      },
      cancelOnError: true,
    );
    onGeneration(generation, subscription);
    cancellationToken.onCancel(() {
      if (!completer.isCompleted) {
        completer.complete(_ForwardResult(emitted: emitted));
      }
      subscription.cancel();
      generation.cancel();
    });

    try {
      return await completer.future;
    } finally {
      await subscription.cancel();
      await generation.cancel();
      RuntimeDiagnostics.streamTimingFinished();
    }
  }

  static AIGeneration _startProviderGeneration(AIRoute route, String prompt) {
    switch (route.provider) {
      case AIProviderType.groq:
        return GroqService.streamMessageWithModel(prompt, route.model);
    }
  }

  static String composePrompt({
    required String prompt,
    required String mode,
    required List<OmniMemory> memories,
    required List<ToolResult> toolResults,
  }) {
    final relevantMemories =
        MemoryIntelligenceService.formatForPrompt(memories);
    final contextBlocks = toolResults
        .where((result) => result.hasContext)
        .map((result) => result.toContextBlock())
        .toList();

    final buffer = StringBuffer()
      ..writeln('You are OmniCore AI, a modular AI operating system.')
      ..writeln('Current mode: $mode.')
      ..writeln(
        'Answer conversationally, be precise, and preserve useful formatting.',
      )
      ..writeln(
        'Behave as an answer engine and research synthesizer, not a search tutor or website navigator.',
      );

    if (relevantMemories.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Relevant user memory:')
        ..writeln(relevantMemories);
    }

    if (contextBlocks.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Retrieval-grounded answer requirements:')
        ..writeln(
          '- Treat the external context below as evidence to synthesize into the final answer.',
        )
        ..writeln(
          '- If the context contains relevant facts, answer the user directly using those facts.',
        )
        ..writeln(
          '- Summarize, rank, and combine the retrieved results instead of listing search instructions.',
        )
        ..writeln(
          '- Do not tell the user to visit a website, search manually, check an official page, or look something up when the answer can be inferred from the context.',
        )
        ..writeln(
          '- Cite or mention source names and URLs naturally when they support the answer.',
        )
        ..writeln(
          '- Only say where to search next if the retrieved context is empty, irrelevant, failed, or does not contain enough information to answer.',
        )
        ..writeln()
        ..writeln('Retrieved evidence, ranked by retrieval order:')
        ..writeln(contextBlocks.join('\n\n---\n\n'));
    } else {
      buffer
        ..writeln()
        ..writeln(
          'No useful retrieval evidence is available. If current facts are needed, be transparent about the limitation and suggest the most relevant official source to check.',
        );
    }

    buffer
      ..writeln()
      ..writeln('User request:')
      ..writeln(prompt);

    return buffer.toString();
  }

  static String _contextPreview(List<ToolResult> toolResults) {
    final context = toolResults
        .where((result) => result.hasContext)
        .map((result) => result.content.trim())
        .join('\n\n');
    if (context.length <= 700) return context;
    return '${context.substring(0, 700)}...';
  }

  static String _safeLogText(String text) {
    var sanitized = text;
    final patterns = <RegExp>[
      RegExp(r'Bearer\s+[A-Za-z0-9._\-]+', caseSensitive: false),
      RegExp(r'(?<=api[_-]?key[=:]\s*)([^\s]+)', caseSensitive: false),
      RegExp(r'(?<=Authorization:\s*)([^\r\n]+)', caseSensitive: false),
    ];
    for (final pattern in patterns) {
      sanitized = sanitized.replaceAllMapped(pattern, (match) => '[REDACTED]');
    }
    return sanitized;
  }
}

class _ForwardResult {
  const _ForwardResult({
    required this.emitted,
    this.error,
  });

  final bool emitted;
  final AIServiceException? error;
}
