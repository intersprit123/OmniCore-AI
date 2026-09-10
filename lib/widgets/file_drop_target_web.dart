import 'dart:html' as html;

import 'package:flutter/material.dart';

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
  bool _isDraggingFiles = false;

  void _setDragging(bool value) {
    if (!mounted || !widget.enabled || _isDraggingFiles == value) return;
    setState(() => _isDraggingFiles = value);
  }

  bool _hasFiles(html.DataTransfer? dataTransfer) {
    if (dataTransfer == null) return false;
    final types = dataTransfer.types;
    return types == null || types.contains('Files') || types.contains('application/x-moz-file');
  }

  Future<void> _handleDrop(html.MouseEvent event) async {
    final dataTransfer = event.dataTransfer;
    if (!widget.enabled || !_hasFiles(dataTransfer)) return;

    event.preventDefault();
    event.stopPropagation();
    _setDragging(false);

    final files = dataTransfer?.files;
    if (files == null || files.isEmpty) return;

    final attachments = <FileAttachment>[];
    for (var index = 0; index < files.length; index++) {
      final file = files[index];
      if (file == null) continue;
      attachments.add(
        FileAttachment(
          name: file.name,
          size: file.size,
        ),
      );
    }

    if (attachments.isNotEmpty) {
      widget.onFilesDropped(attachments);
    }
  }

  @override
  void initState() {
    super.initState();
    final document = html.document;

    document.onDragOver.listen((event) {
      final mouseEvent = event as html.MouseEvent;
      if (!_hasFiles(mouseEvent.dataTransfer)) return;
      mouseEvent.preventDefault();
      mouseEvent.stopPropagation();
      _setDragging(true);
      mouseEvent.dataTransfer?.dropEffect = 'copy';
    });

    document.onDragLeave.listen((event) {
      final mouseEvent = event as html.MouseEvent;
      if (!_hasFiles(mouseEvent.dataTransfer)) return;
      if (mouseEvent.client.x <= 0 ||
          mouseEvent.client.y <= 0 ||
          mouseEvent.client.x >= html.window.innerWidth! - 1 ||
          mouseEvent.client.y >= html.window.innerHeight! - 1) {
        _setDragging(false);
      }
    });

    document.onDrop.listen((event) {
      final mouseEvent = event as html.MouseEvent;
      _handleDrop(mouseEvent);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.enabled)
          AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: _isDraggingFiles ? 58 : 42,
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: _isDraggingFiles
                  ? const Color(0xFF39D6E8).withValues(alpha: 0.14)
                  : Colors.transparent,
              border: Border.all(
                color: _isDraggingFiles
                    ? const Color(0xFF39D6E8)
                    : const Color(0xFF39D6E8).withValues(alpha: 0.28),
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _isDraggingFiles ? Icons.file_download : Icons.upload_file,
                  size: 17,
                  color: const Color(0xFFB7C4D4),
                ),
                const SizedBox(width: 7),
                Text(
                  _isDraggingFiles
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
        widget.child,
      ],
    );
  }
}
