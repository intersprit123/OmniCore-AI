class FileAttachment {
  const FileAttachment({
    required this.name,
    required this.size,
  });

  final String name;
  final int size;

  String get displaySize {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
