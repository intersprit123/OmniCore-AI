import '../models/tool_result.dart';
import 'cancellation_token.dart';
import 'runtime_diagnostics.dart';
import 'serpapi_retrieval_service.dart';

class ToolExecutionRequest {
  const ToolExecutionRequest({
    required this.prompt,
    required this.mode,
    required this.cancellationToken,
    this.retrievalPreference = RetrievalPreference.auto,
  });

  final String prompt;
  final String mode;
  final CancellationToken cancellationToken;
  final RetrievalPreference retrievalPreference;
}

abstract class OmniTool {
  const OmniTool({
    required this.id,
    required this.name,
    required this.description,
  });

  final String id;
  final String name;
  final String description;

  bool shouldRun(ToolExecutionRequest request);

  Future<ToolResult> run(ToolExecutionRequest request);
}

class SerpApiRetrievalTool extends OmniTool {
  const SerpApiRetrievalTool()
      : super(
          id: 'serpapi-retrieval',
          name: 'Live Search',
          description:
              'Searches live web results for current/factual requests.',
        );

  @override
  bool shouldRun(ToolExecutionRequest request) {
    if (request.retrievalPreference == RetrievalPreference.disabled) {
      return false;
    }
    if (request.retrievalPreference == RetrievalPreference.force) {
      return true;
    }

    final prompt = request.prompt.toLowerCase();
    if (_urlPattern.hasMatch(prompt)) return true;
    return _retrievalSignals.any(prompt.contains);
  }

  @override
  Future<ToolResult> run(ToolExecutionRequest request) {
    return SerpApiRetrievalService.retrieve(
      prompt: request.prompt,
      mode: request.mode,
      cancellationToken: request.cancellationToken,
    );
  }

  static final _urlPattern = RegExp(r'https?://\S+', caseSensitive: false);

  static const _retrievalSignals = [
    'latest',
    'today',
    'current',
    'recent',
    'news',
    'price',
    'prices',
    'search',
    'look up',
    'web',
    'internet',
    'source',
    'sources',
    'citation',
    'citations',
    'verify',
    'fact check',
    'summarize this url',
    'compare current',
    'what happened',
    'this week',
    'this month',
    '2026',
  ];
}

class ToolRegistry {
  ToolRegistry({List<OmniTool>? tools})
      : tools = tools ?? const [SerpApiRetrievalTool()];

  final List<OmniTool> tools;

  static const futureTools = [
    FutureToolDefinition(
      id: 'file-analysis',
      name: 'File Analysis',
      description: 'Parse and summarize uploaded documents.',
      iconName: 'upload_file',
    ),
    FutureToolDefinition(
      id: 'image-analysis',
      name: 'Image Analysis',
      description: 'Inspect visual content and multimodal attachments.',
      iconName: 'image_search',
    ),
    FutureToolDefinition(
      id: 'calculator',
      name: 'Calculator',
      description: 'Run deterministic math and unit conversions.',
      iconName: 'calculate',
    ),
    FutureToolDefinition(
      id: 'url-summarizer',
      name: 'URL Summarizer',
      description: 'Fetch and compress web pages into focused context.',
      iconName: 'link',
    ),
    FutureToolDefinition(
      id: 'workflow-automation',
      name: 'Workflow Automation',
      description: 'Coordinate repeated tasks and external operations.',
      iconName: 'account_tree',
    ),
    FutureToolDefinition(
      id: 'ai-agents',
      name: 'AI Agents',
      description: 'Delegate long-running work to specialized agent loops.',
      iconName: 'hub',
    ),
    FutureToolDefinition(
      id: 'multimodal-tools',
      name: 'Multimodal Tools',
      description: 'Unify text, images, files, and structured tool outputs.',
      iconName: 'auto_awesome_motion',
    ),
  ];

  List<OmniTool> plan(ToolExecutionRequest request) {
    if (request.retrievalPreference == RetrievalPreference.disabled) {
      RuntimeDiagnostics.retrievalSkipped(
          'Retrieval disabled for this message');
      return const [];
    }

    return tools.where((tool) => tool.shouldRun(request)).toList();
  }

  Future<List<ToolResult>> executeRelevant(ToolExecutionRequest request) async {
    final selectedTools = plan(request);
    if (selectedTools.isEmpty) {
      if (request.retrievalPreference != RetrievalPreference.disabled) {
        RuntimeDiagnostics.retrievalSkipped(
          'No live-search trigger matched this prompt',
        );
      }
      return const [];
    }

    final results = <ToolResult>[];
    RuntimeDiagnostics.retrievalTimingStarted();
    for (final tool in selectedTools) {
      if (request.cancellationToken.isCancelled) break;
      RuntimeDiagnostics.retrievalStarted(_triggerReason(request));
      late final ToolResult result;
      try {
        result = await tool.run(request);
      } catch (error) {
        result = ToolResult(
          toolId: tool.id,
          title: tool.name,
          status: ToolResultStatus.failed,
          error: 'Tool failed silently; continuing with Groq.',
        );
      }
      if (request.cancellationToken.isCancelled) break;
      results.add(result);
      RuntimeDiagnostics.retrievalFinished(result);
    }
    RuntimeDiagnostics.retrievalTimingFinished();
    return results;
  }

  static String _triggerReason(ToolExecutionRequest request) {
    if (request.retrievalPreference == RetrievalPreference.force) {
      return 'Manual live search enabled';
    }
    final prompt = request.prompt.toLowerCase();
    if (SerpApiRetrievalTool._urlPattern.hasMatch(prompt)) {
      return 'URL detected in prompt';
    }
    final signal = SerpApiRetrievalTool._retrievalSignals.firstWhere(
      prompt.contains,
      orElse: () => 'current information',
    );
    return 'Matched "$signal" retrieval signal';
  }
}

class FutureToolDefinition {
  const FutureToolDefinition({
    required this.id,
    required this.name,
    required this.description,
    required this.iconName,
  });

  final String id;
  final String name;
  final String description;
  final String iconName;
}
