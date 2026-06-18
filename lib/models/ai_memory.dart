enum OmniMemoryType {
  session,
  longTerm,
  preference,
  pinned,
  semantic,
}

class OmniMemory {
  const OmniMemory({
    required this.id,
    required this.text,
    required this.type,
    required this.createdAt,
    required this.updatedAt,
    this.pinned = false,
    this.tags = const [],
    this.source = 'manual',
  });

  final String id;
  final String text;
  final OmniMemoryType type;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool pinned;
  final List<String> tags;
  final String source;

  OmniMemory copyWith({
    String? text,
    OmniMemoryType? type,
    DateTime? updatedAt,
    bool? pinned,
    List<String>? tags,
    String? source,
  }) {
    return OmniMemory(
      id: id,
      text: text ?? this.text,
      type: type ?? this.type,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      pinned: pinned ?? this.pinned,
      tags: tags ?? this.tags,
      source: source ?? this.source,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'type': type.name,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'pinned': pinned,
        'tags': tags,
        'source': source,
      };

  factory OmniMemory.fromJson(Map<String, dynamic> json) {
    return OmniMemory(
      id: json['id'] as String,
      text: json['text'] as String,
      type: _typeFromName(json['type'] as String?),
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      pinned: json['pinned'] as bool? ?? false,
      tags: (json['tags'] as List<dynamic>? ?? const [])
          .map((tag) => tag.toString())
          .toList(),
      source: json['source'] as String? ?? 'manual',
    );
  }

  static OmniMemoryType _typeFromName(String? name) {
    return OmniMemoryType.values.firstWhere(
      (type) => type.name == name,
      orElse: () => OmniMemoryType.longTerm,
    );
  }
}
