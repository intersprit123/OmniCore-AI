import '../models/ai_memory.dart';

class MemoryIntelligenceService {
  static OmniMemory? memoryFromPrompt(String prompt) {
    final trimmed = prompt.trim();
    final lower = trimmed.toLowerCase();
    final patterns = [
      RegExp(r'^remember(?: this| that)?:?\s+(.+)$', caseSensitive: false),
      RegExp(r'^save(?: this| that)?(?: memory)?:?\s+(.+)$',
          caseSensitive: false),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(trimmed);
      if (match != null) {
        final text = match.group(1)?.trim();
        if (text == null || text.length < 3) return null;
        return OmniMemory(
          id: 'mem-${DateTime.now().millisecondsSinceEpoch}',
          text: text,
          type: _inferType(text),
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          pinned: _inferType(text) == OmniMemoryType.pinned,
          tags: _tagsFor(text),
          source: 'chat-command',
        );
      }
    }

    if (lower.startsWith('my preference is ') ||
        lower.startsWith('i prefer ') ||
        lower.startsWith('always use ')) {
      return OmniMemory(
        id: 'mem-${DateTime.now().millisecondsSinceEpoch}',
        text: trimmed,
        type: OmniMemoryType.preference,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        tags: _tagsFor(trimmed),
        source: 'preference-signal',
      );
    }

    return null;
  }

  static String? forgetTargetFromPrompt(String prompt) {
    final match = RegExp(
      r'^(forget|remove memory|delete memory)(?: this| that)?:?\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(prompt.trim());
    return match?.group(2)?.trim();
  }

  static List<OmniMemory> retrieveRelevant(
    String prompt,
    List<OmniMemory> memories, {
    int limit = 6,
  }) {
    final queryTokens = _tokenize(prompt);
    final scored = memories
        .map((memory) => MapEntry(memory, _score(memory, queryTokens)))
        .where((entry) => entry.value > 0 || entry.key.pinned)
        .toList()
      ..sort((a, b) {
        final pinnedCompare = (b.key.pinned ? 1 : 0) - (a.key.pinned ? 1 : 0);
        if (pinnedCompare != 0) return pinnedCompare;
        return b.value.compareTo(a.value);
      });

    return scored.take(limit).map((entry) => entry.key).toList();
  }

  static String formatForPrompt(List<OmniMemory> memories) {
    if (memories.isEmpty) return '';
    final buffer = StringBuffer();
    for (final memory in memories) {
      final type = memory.type.name;
      buffer.writeln('- [$type] ${memory.text}');
    }
    return buffer.toString().trim();
  }

  static OmniMemoryType _inferType(String text) {
    final lower = text.toLowerCase();
    if (lower.contains('prefer') ||
        lower.contains('always') ||
        lower.contains('use ') ||
        lower.contains('tone')) {
      return OmniMemoryType.preference;
    }
    if (lower.contains('pin') || lower.contains('important')) {
      return OmniMemoryType.pinned;
    }
    if (lower.contains('project') || lower.contains('workflow')) {
      return OmniMemoryType.semantic;
    }
    return OmniMemoryType.longTerm;
  }

  static List<String> _tagsFor(String text) {
    final tags = <String>{};
    final lower = text.toLowerCase();
    if (lower.contains('code') || lower.contains('flutter')) tags.add('code');
    if (lower.contains('project')) tags.add('project');
    if (lower.contains('tone') || lower.contains('prefer')) {
      tags.add('preference');
    }
    if (lower.contains('workflow')) tags.add('workflow');
    return tags.toList();
  }

  static int _score(OmniMemory memory, Set<String> queryTokens) {
    final memoryTokens = _tokenize('${memory.text} ${memory.tags.join(' ')}');
    var score = 0;
    for (final token in queryTokens) {
      if (memoryTokens.contains(token)) score += 2;
    }
    if (memory.type == OmniMemoryType.preference) score += 1;
    if (memory.type == OmniMemoryType.pinned) score += 3;
    return score;
  }

  static Set<String> _tokenize(String value) {
    final matches = RegExp(r'[a-zA-Z0-9_+#.-]{3,}')
        .allMatches(value.toLowerCase())
        .map((match) => match.group(0)!)
        .where((token) => !_stopWords.contains(token));
    return matches.toSet();
  }

  static const _stopWords = {
    'the',
    'and',
    'for',
    'with',
    'this',
    'that',
    'from',
    'what',
    'when',
    'where',
    'please',
    'about',
  };
}
