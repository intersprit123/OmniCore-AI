import 'dart:async';
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
  final List<StreamSubscription<html.Event>> _subscriptions = [];
  bool _isDraggingFiles = false;
  int _dragDepth = 0;

  @override
  void initState() {
    super.initState();

    // Use the browser's native HTML5 drag/drop events at document level.
    // This avoids platform-specific drop-zone widgets and works in Flutter Web.
    _subscriptions.add(
      html.document.onDragEnter.listen((event) {
        if (!widget.enabled || !_containsFiles(event)) return;
        _dragDepth++;
        if (mounted && !_isDraggingFiles) {
          setState(() => _isDraggingFiles = true);
        }
      }),
    );

    _subscriptions.add(
      html.document.onDragOver.listen((event) {
        if (!widget.enabled || !_containsFiles(event)) return;
        event.preventDefault();
        if (event is html.MouseEvent) {
          event.dataTransfer?.dropEffect = 'copy';
        }
        if (mounted && !_isDraggingFiles) {
          setState(() => _isDraggingFiles = true);
        }
      }),
    );

    _subscriptions.add(
      html.document.onDragLeave.listen((event) {
        if (!widget.enabled || !_containsFiles(event)) return;
        _dragDepth = (_dragDepth - 1).clamp(0, 1000);
        if (_dragDepth == 0 && mounted && _isDraggingFiles) {
          setState(() => _isDraggingFiles = false);
        }
      }),
    );

    _subscriptions.add(
      html.document.onDrop.listen((event) {
        if (!widget.enabled || !_containsFiles(event)) return;
        event.preventDefault();
        _dragDepth = 0;

        final dataTransfer = event is html.MouseEvent
            ? event.dataTransfer
            : null;
        final files = dataTransfer?.files;
        final attachments = <FileAttachment>[];

        if (files != null) {
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
        }

        if (mounted) {
          setState(() => _isDraggingFiles = false);
        }
        if (attachments.isNotEmpty) {
          widget.onFilesDropped(attachments);
        }
      }),
    );
  }

  bool _containsFiles(html.Event event) {
    if (event is! html.MouseEvent) return false;
    final dataTransfer = event.dataTransfer;
    if (dataTransfer == null) return false;
    final types = dataTransfer.types;
    return types.contains('Files') || types.contains('application/x-moz-file');
  }

  @override
  void didUpdateWidget(covariant FileDropTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _isDraggingFiles) {
      _dragDepth = 0;
      setState(() => _isDraggingFiles = false);
    }
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
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
