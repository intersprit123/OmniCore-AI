import 'package:flutter/widgets.dart';

import '../models/file_attachment.dart';

class FileDropTarget extends StatelessWidget {
  const FileDropTarget({
    super.key,
    required this.child,
    required this.onFilesDropped,
    required this.enabled,
  });

  final Widget child;
  final ValueChanged<List<FileAttachment>> onFilesDropped;
  final bool enabled;

  @override
  Widget build(BuildContext context) => child;
}
