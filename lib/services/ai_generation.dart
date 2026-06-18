import 'dart:async';

class AIGeneration {
  AIGeneration({
    required this.stream,
    required Future<void> Function() cancel,
    required this.provider,
    required this.model,
  }) : _cancel = cancel;

  factory AIGeneration.error(
    String message, {
    String provider = 'AI',
    String model = '',
  }) {
    return AIGeneration(
      stream: Stream<String>.error(AIServiceException(message)),
      cancel: () async {},
      provider: provider,
      model: model,
    );
  }

  final Stream<String> stream;
  final String provider;
  final String model;
  final Future<void> Function() _cancel;
  bool _cancelled = false;

  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    await _cancel();
  }
}

class AIServiceException implements Exception {
  const AIServiceException(
    this.message, {
    this.statusCode,
    this.isTimeout = false,
    this.details,
  });

  final String message;
  final int? statusCode;
  final bool isTimeout;
  final String? details;

  @override
  String toString() => message;
}
