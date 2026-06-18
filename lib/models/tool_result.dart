enum ToolResultStatus { success, skipped, unavailable, failed }

class ToolSource {
  const ToolSource({
    required this.title,
    required this.url,
    this.snippet,
  });

  final String title;
  final String url;
  final String? snippet;

  Map<String, dynamic> toJson() => {
        'title': title,
        'url': url,
        if (snippet != null) 'snippet': snippet,
      };

  factory ToolSource.fromJson(Map<String, dynamic> json) {
    return ToolSource(
      title: json['title'] as String? ?? 'Source',
      url: json['url'] as String? ?? '',
      snippet: json['snippet'] as String?,
    );
  }
}

class ToolResult {
  const ToolResult({
    required this.toolId,
    required this.title,
    required this.status,
    this.content = '',
    this.sources = const [],
    this.error,
  });

  final String toolId;
  final String title;
  final ToolResultStatus status;
  final String content;
  final List<ToolSource> sources;
  final String? error;

  bool get hasContext =>
      status == ToolResultStatus.success && content.trim().isNotEmpty;

  String toContextBlock() {
    final buffer = StringBuffer()
      ..writeln('Tool: $title')
      ..writeln('Status: retrieved evidence available')
      ..writeln('Use this evidence to answer the user directly.')
      ..writeln(content.trim());

    if (sources.isNotEmpty) {
      buffer.writeln('Ranked sources:');
      for (final entry in sources.take(6).indexed) {
        final rank = entry.$1 + 1;
        final source = entry.$2;
        final snippet = source.snippet?.trim();
        buffer.writeln('$rank. ${source.title}: ${source.url}');
        if (snippet != null && snippet.isNotEmpty) {
          buffer.writeln('   Evidence: $snippet');
        }
      }
    }

    return buffer.toString().trim();
  }
}
