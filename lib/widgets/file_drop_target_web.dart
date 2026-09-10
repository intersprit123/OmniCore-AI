import 'dart:async';
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

import '../models/file_attachment.dart';

int _nextDropTargetId = 0;

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
  late final String _viewType;
  late final html.DivElement _dropElement;
  final List<StreamSubscription<html.Event>> _subscriptions = [];
  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    _viewType = 'omnicore-file-drop-${_nextDropTargetId++}';

    _dropElement = html.DivElement()
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.backgroundColor = 'transparent'
      ..style.border = 'none'
      ..style.cursor = 'copy';

    _subscriptions.add(
      _dropElement.onDragEnter.listen((event) {
        event.preventDefault();
        if (mounted && widget.enabled) {
          setState(() => _isDragging = true);
        }
      }),
    );
    _subscriptions.add(
      _dropElement.onDragOver.listen((event) {
        event.preventDefault();
        if (event is html.MouseEvent) {
          event.dataTransfer?.dropEffect = 'copy';
        }
        if (mounted && widget.enabled && !_isDragging) {
          setState(() => _isDragging = true);
        }
      }),
    );
    _subscriptions.add(
      _dropElement.onDragLeave.listen((event) {
        event.preventDefault();
        if (mounted && _isDragging) {
          setState(() => _isDragging = false);
        }
      }),
    );
    _subscriptions.add(
      _dropElement.onDrop.listen((event) {
        event.preventDefault();
        if (!widget.enabled || event is! html.MouseEvent) return;

        final files = event.dataTransfer?.files;
        if (files == null || files.isEmpty) {
          if (mounted) setState(() => _isDragging = false);
          return;
        }

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

        if (!mounted) return;
        setState(() => _isDragging = false);
        if (attachments.isNotEmpty) {
          widget.onFilesDropped(attachments);
        }
      }),
    );

    ui_web.platformViewRegistry.registerViewFactory(
      _viewType,
      (int viewId) => _dropElement,
    );
  }

  @override
  void didUpdateWidget(covariant FileDropTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _isDragging) {
      setState(() => _isDragging = false);
    }
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _dropElement.remove();
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
          height: _isDragging ? 58 : 42,
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 8),
          child: Stack(
            fit: StackFit.expand,
            children: [
              HtmlElementView(viewType: _viewType),
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
