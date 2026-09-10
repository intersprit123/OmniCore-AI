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
  var _isDragging = false;

  Future<void> _handleDroppedFiles(
    List<DropzoneFileInterface> files,
  ) async {
    final controller = _controller;
    if (controller == null) return;

    final attachments = await Future.wait(
      files.map(
        (file) async => FileAttachment(
          name: await controller.getFilename(file),
          size: await controller.getFileSize(file),
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _isDragging = false);
    widget.onFilesDropped(attachments);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;

    return Column(
      children: [
        SizedBox(
          height: 52,
          child: Stack(
            fit: StackFit.expand,
            children: [
              DropzoneView(
                operation: DragOperation.copy,
                onCreated: (controller) => _controller = controller,
                onHover: () => setState(() => _isDragging = true),
                onLeave: () => setState(() => _isDragging = false),
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
                        ? const Color(0xFF39D6E8).withValues(alpha: 0.12)
                        : Colors.transparent,
                    border: Border.all(
                      color: _isDragging
                          ? const Color(0xFF39D6E8)
                          : const Color(0xFF39D6E8).withValues(alpha: 0.28),
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _isDragging ? 'Drop files to attach' : 'Drop files here',
                    style: const TextStyle(
                      color: Color(0xFFB7C4D4),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        widget.child,
      ],
    );
  }
}
