class FileAttachment {
  const FileAttachment({
    required this.name,
    required this.size,
  });

  final String name;
  final int size;

  static final Map<String, String> _contentByName = <String, String>{};

  static void registerContent({
    required String name,
    required String content,
  }) {
    final normalized = name.trim();
    if (normalized.isEmpty) return;
    _contentByName[normalized] = content;
  }

  static String? contentForName(String name) {
    return _contentByName[name.trim()];
  }

  static void clearContentForName(String name) {
    _contentByName.remove(name.trim());
  }

  String get displaySize {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
