import 'package:flutter/material.dart';
import 'package:flutter_dropzone/flutter_dropzone.dart';

import '../models/file_attachment.dart';

class FileDropTarget extends StatefulWidget {
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
  State<FileDropTarget> createState() => _FileDropTargetState();
}

class _FileDropTargetState extends State<FileDropTarget> {
  DropzoneViewController? _controller;
  bool _isDragging = false;

  Future<void> _handleDroppedFiles(List<DropzoneFileInterface> files) async {
    final controller = _controller;
    if (controller == null || files.isEmpty) return;

    final attachments = <FileAttachment>[];
    for (final file in files) {
      attachments.add(
        FileAttachment(
          name: await controller.getFilename(file),
          size: await controller.getFileSize(file),
        ),
      );
    }

    if (!mounted) return;
    setState(() => _isDragging = false);
    widget.onFilesDropped(attachments);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;

    // Keep the drop target as a real, visible part of the composer instead
    // of placing it underneath the composer where it can be clipped.
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: _isDragging ? 58 : 42,
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 8),
          child: Stack(
            fit: StackFit.expand,
            children: [
              DropzoneView(
                operation: DragOperation.copy,
                onCreated: (controller) => _controller = controller,
                onHover: () {
                  if (mounted && !_isDragging) {
                    setState(() => _isDragging = true);
                  }
                },
                onLeave: () {
                  if (mounted && _isDragging) {
                    setState(() => _isDragging = false);
                  }
                },
                onDropFiles: (files) {
                  if (files != null) {
                    _handleDroppedFiles(files);
                  }
                },
              ),
              IgnorePointer(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _isDragging
                        ? const Color(0xFF39D6E8).withValues(alpha: 0.14)
                        : Colors.transparent,
                    border: Border.all(
                      color: _isDragging
                          ? const Color(0xFF39D6E8)
                          : const Color(0xFF39D6E8).withValues(alpha: 0.28),
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _isDragging ? Icons.file_download : Icons.upload_file,
                        size: 17,
                        color: const Color(0xFFB7C4D4),
                      ),
                      const SizedBox(width: 7),
                      Text(
                        _isDragging
                            ? 'Release to attach files'
                            : 'Drag & drop files here',
                        style: const TextStyle(
                          color: Color(0xFFB7C4D4),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        widget.child,
      ],
    );
  }
}
