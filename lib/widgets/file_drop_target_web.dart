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

    // file_picker creates a native browser file input on web. Capture its
    // real File objects here so the AI can receive actual file contents.
    _subscriptions.add(
      html.document.onChange.listen((event) {
        if (!widget.enabled) return;
        final target = event.target;
        if (target is! html.FileUploadInputElement) return;
        final files = target.files;
        if (files == null) return;
        for (var index = 0; index < files.length; index++) {
          final file = files[index];
          if (file == null) continue;
          unawaited(_readAndRegister(file));
        }
      }),
    );

    _subscriptions.add(
      html.document.onDragEnter.listen((event) {
        final mouseEvent = event as html.MouseEvent;
        if (!widget.enabled || !_hasFiles(mouseEvent.dataTransfer)) return;
        _dragDepth++;
        _setDragging(true);
      }),
    );

    _subscriptions.add(
      html.document.onDragOver.listen((event) {
        final mouseEvent = event as html.MouseEvent;
        if (!widget.enabled || !_hasFiles(mouseEvent.dataTransfer)) return;
        mouseEvent.preventDefault();
        mouseEvent.stopPropagation();
        _setDragging(true);
        mouseEvent.dataTransfer?.dropEffect = 'copy';
      }),
    );

    _subscriptions.add(
      html.document.onDragLeave.listen((event) {
        final mouseEvent = event as html.MouseEvent;
        if (!widget.enabled || !_hasFiles(mouseEvent.dataTransfer)) return;
        _dragDepth = (_dragDepth - 1).clamp(0, 1000);
        if (_dragDepth == 0 &&
            (mouseEvent.client.x <= 0 ||
                mouseEvent.client.y <= 0 ||
                mouseEvent.client.x >= html.window.innerWidth! - 1 ||
                mouseEvent.client.y >= html.window.innerHeight! - 1)) {
          _setDragging(false);
        }
      }),
    );

    _subscriptions.add(
      html.document.onDrop.listen((event) {
        final mouseEvent = event as html.MouseEvent;
        _handleDrop(mouseEvent);
      }),
    );
  }

  void _setDragging(bool value) {
    if (!mounted || !widget.enabled || _isDraggingFiles == value) return;
    setState(() => _isDraggingFiles = value);
  }

  bool _hasFiles(html.DataTransfer? dataTransfer) {
    if (dataTransfer == null) return false;
    final types = dataTransfer.types;
    return types == null ||
        types.contains('Files') ||
        types.contains('application/x-moz-file');
  }

  Future<void> _handleDrop(html.MouseEvent event) async {
    final dataTransfer = event.dataTransfer;
    if (!widget.enabled || !_hasFiles(dataTransfer)) return;

    event.preventDefault();
    event.stopPropagation();
    _dragDepth = 0;
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
      await _readAndRegister(file);
    }

    if (attachments.isNotEmpty) {
      widget.onFilesDropped(attachments);
    }
  }

  bool _isTextFile(html.File file) {
    final type = file.type.toLowerCase();
    if (type.startsWith('text/')) return true;

    final name = file.name.toLowerCase();
    const textExtensions = <String>{
      '.txt', '.md', '.markdown', '.csv', '.tsv', '.json', '.jsonl',
      '.xml', '.html', '.htm', '.css', '.scss', '.less', '.js', '.mjs',
      '.cjs', '.ts', '.tsx', '.jsx', '.dart', '.py', '.java', '.kt',
      '.kts', '.c', '.h', '.cpp', '.cc', '.cxx', '.hpp', '.cs', '.go',
      '.rs', '.swift', '.php', '.rb', '.sh', '.bash', '.ps1', '.bat',
      '.cmd', '.yml', '.yaml', '.toml', '.ini', '.cfg', '.conf', '.log',
      '.sql', '.graphql', '.gql', '.vue', '.svelte', '.astro',
    };
    return textExtensions.any(name.endsWith);
  }

  Future<void> _readAndRegister(html.File file) async {
    if (!_isTextFile(file)) return;

    final reader = html.FileReader();
    final completer = Completer<void>();

    reader.onLoadEnd.listen((_) {
      try {
        final result = reader.result;
        if (result is String) {
          FileAttachment.registerContent(
            name: file.name,
            content: result,
          );
        }
      } finally {
        if (!completer.isCompleted) completer.complete();
      }
    });

    reader.onError.listen((_) {
      if (!completer.isCompleted) completer.complete();
    });

    reader.readAsText(file);
    await completer.future;
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
