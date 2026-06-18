import 'package:flutter/foundation.dart';

import '../models/tool_result.dart';

enum RetrievalPreference { auto, force, disabled }

extension RetrievalPreferenceLabel on RetrievalPreference {
  String get label {
    switch (this) {
      case RetrievalPreference.auto:
        return 'Auto';
      case RetrievalPreference.force:
        return 'On';
      case RetrievalPreference.disabled:
        return 'Off';
    }
  }
}

class RuntimeSnapshot {
  const RuntimeSnapshot({
    this.providerStatus = 'Groq ready',
    this.groqConnectivity = 'Awaiting local backend status',
    this.serpApiConnectivity = 'Idle',
    this.backendConnectivity = 'Backend status not checked',
    this.workerHealth = 'Unknown',
    this.orchestratorStatus = 'Idle',
    this.retrievalStatus = 'Idle',
    this.retrievalPreference = RetrievalPreference.auto,
    this.retrievalTriggerReason = 'No retrieval planned',
    this.routerDecision = 'Groq generation',
    this.streamState = 'Idle',
    this.sendStopState = 'Send ready',
    this.isStreaming = false,
    this.chunkCount = 0,
    this.characterCount = 0,
    this.latencyMs,
    this.totalMs,
    this.lastSearchSummary = '',
    this.contextPreview = '',
    this.lastSources = const [],
    this.toolActivationLogs = const [],
    this.fallbackEvents = const [],
    this.lastError,
    this.lastProviderResponse = 'No provider response yet',
    this.lastRetrievalEvent = 'No retrieval event yet',
    this.activeModel = 'llama-3.3-70b-versatile',
    this.currentBackendUrl = 'http://localhost:3000',
    this.requestStartedAt,
    this.retrievalStartedAt,
    this.retrievalCompletedAt,
    this.generationStartedAt,
    this.streamStartedAt,
    this.streamCompletedAt,
    this.firstTokenAt,
    this.completedAt,
    this.timeoutSource = 'None',
  });

  final String providerStatus;
  final String groqConnectivity;
  final String serpApiConnectivity;
  final String backendConnectivity;
  final String workerHealth;
  final String orchestratorStatus;
  final String retrievalStatus;
  final RetrievalPreference retrievalPreference;
  final String retrievalTriggerReason;
  final String routerDecision;
  final String streamState;
  final String sendStopState;
  final bool isStreaming;
  final int chunkCount;
  final int characterCount;
  final int? latencyMs;
  final int? totalMs;
  final String lastSearchSummary;
  final String contextPreview;
  final List<ToolSource> lastSources;
  final List<String> toolActivationLogs;
  final List<String> fallbackEvents;
  final String? lastError;
  final String lastProviderResponse;
  final String lastRetrievalEvent;
  final String activeModel;
  final String currentBackendUrl;
  final DateTime? requestStartedAt;
  final DateTime? retrievalStartedAt;
  final DateTime? retrievalCompletedAt;
  final DateTime? generationStartedAt;
  final DateTime? streamStartedAt;
  final DateTime? streamCompletedAt;
  final DateTime? firstTokenAt;
  final DateTime? completedAt;
  final String timeoutSource;

  RuntimeSnapshot copyWith({
    String? providerStatus,
    String? groqConnectivity,
    String? serpApiConnectivity,
    String? backendConnectivity,
    String? workerHealth,
    String? orchestratorStatus,
    String? retrievalStatus,
    RetrievalPreference? retrievalPreference,
    String? retrievalTriggerReason,
    String? routerDecision,
    String? streamState,
    String? sendStopState,
    bool? isStreaming,
    int? chunkCount,
    int? characterCount,
    int? latencyMs,
    int? totalMs,
    String? lastSearchSummary,
    String? contextPreview,
    List<ToolSource>? lastSources,
    List<String>? toolActivationLogs,
    List<String>? fallbackEvents,
    String? lastError,
    String? lastProviderResponse,
    String? lastRetrievalEvent,
    String? activeModel,
    String? currentBackendUrl,
    DateTime? requestStartedAt,
    DateTime? retrievalStartedAt,
    DateTime? retrievalCompletedAt,
    DateTime? generationStartedAt,
    DateTime? streamStartedAt,
    DateTime? streamCompletedAt,
    DateTime? firstTokenAt,
    DateTime? completedAt,
    String? timeoutSource,
    bool clearError = false,
    bool clearTiming = false,
  }) {
    return RuntimeSnapshot(
      providerStatus: providerStatus ?? this.providerStatus,
      groqConnectivity: groqConnectivity ?? this.groqConnectivity,
      serpApiConnectivity: serpApiConnectivity ?? this.serpApiConnectivity,
      backendConnectivity: backendConnectivity ?? this.backendConnectivity,
      workerHealth: workerHealth ?? this.workerHealth,
      orchestratorStatus: orchestratorStatus ?? this.orchestratorStatus,
      retrievalStatus: retrievalStatus ?? this.retrievalStatus,
      retrievalPreference: retrievalPreference ?? this.retrievalPreference,
      retrievalTriggerReason:
          retrievalTriggerReason ?? this.retrievalTriggerReason,
      routerDecision: routerDecision ?? this.routerDecision,
      streamState: streamState ?? this.streamState,
      sendStopState: sendStopState ?? this.sendStopState,
      isStreaming: isStreaming ?? this.isStreaming,
      chunkCount: chunkCount ?? this.chunkCount,
      characterCount: characterCount ?? this.characterCount,
      latencyMs: latencyMs ?? (clearTiming ? null : this.latencyMs),
      totalMs: totalMs ?? (clearTiming ? null : this.totalMs),
      lastSearchSummary: lastSearchSummary ?? this.lastSearchSummary,
      contextPreview: contextPreview ?? this.contextPreview,
      lastSources: lastSources ?? this.lastSources,
      toolActivationLogs: toolActivationLogs ?? this.toolActivationLogs,
      fallbackEvents: fallbackEvents ?? this.fallbackEvents,
      lastError: clearError ? null : lastError ?? this.lastError,
      lastProviderResponse: lastProviderResponse ?? this.lastProviderResponse,
      lastRetrievalEvent: lastRetrievalEvent ?? this.lastRetrievalEvent,
      activeModel: activeModel ?? this.activeModel,
      currentBackendUrl: currentBackendUrl ?? this.currentBackendUrl,
      requestStartedAt:
          requestStartedAt ?? (clearTiming ? null : this.requestStartedAt),
      retrievalStartedAt:
          retrievalStartedAt ?? (clearTiming ? null : this.retrievalStartedAt),
      retrievalCompletedAt: retrievalCompletedAt ??
          (clearTiming ? null : this.retrievalCompletedAt),
      generationStartedAt: generationStartedAt ??
          (clearTiming ? null : this.generationStartedAt),
      streamStartedAt:
          streamStartedAt ?? (clearTiming ? null : this.streamStartedAt),
      streamCompletedAt:
          streamCompletedAt ?? (clearTiming ? null : this.streamCompletedAt),
      firstTokenAt: firstTokenAt ?? (clearTiming ? null : this.firstTokenAt),
      completedAt: completedAt ?? (clearTiming ? null : this.completedAt),
      timeoutSource:
          timeoutSource ?? (clearTiming ? 'None' : this.timeoutSource),
    );
  }
}

class RuntimeDiagnostics {
  static final snapshot = ValueNotifier<RuntimeSnapshot>(
    const RuntimeSnapshot(),
  );
  static final forceGroqOnlyMode = ValueNotifier<bool>(false);
  static final forceRetrievalMode = ValueNotifier<bool>(false);
  static final experimentalFeatures = ValueNotifier<bool>(false);
  static final debugOverlayEnabled = ValueNotifier<bool>(false);

  static void startRequest({
    required String mode,
    required RetrievalPreference retrievalPreference,
  }) {
    snapshot.value = snapshot.value.copyWith(
      providerStatus: 'Groq active',
      orchestratorStatus: 'Coordinating request',
      retrievalStatus: 'Evaluating retrieval need',
      retrievalPreference: retrievalPreference,
      retrievalTriggerReason: 'Awaiting tool plan',
      routerDecision: 'Groq generation for $mode mode',
      streamState: 'Starting',
      sendStopState: 'Stop available',
      isStreaming: false,
      chunkCount: 0,
      characterCount: 0,
      lastSearchSummary: '',
      contextPreview: '',
      lastSources: const [],
      toolActivationLogs: const [],
      fallbackEvents: const [],
      requestStartedAt: DateTime.now(),
      timeoutSource: 'None',
      clearError: true,
      clearTiming: true,
    );
  }

  static void retrievalTimingStarted() {
    snapshot.value = snapshot.value.copyWith(
      retrievalStartedAt: DateTime.now(),
      timeoutSource: 'None',
    );
  }

  static void retrievalTimingFinished() {
    snapshot.value = snapshot.value.copyWith(
      retrievalCompletedAt: DateTime.now(),
    );
  }

  static void generationTimingStarted() {
    snapshot.value = snapshot.value.copyWith(
      generationStartedAt: DateTime.now(),
    );
  }

  static void streamTimingStarted() {
    snapshot.value = snapshot.value.copyWith(
      streamStartedAt: DateTime.now(),
    );
  }

  static void streamTimingFinished() {
    snapshot.value = snapshot.value.copyWith(
      streamCompletedAt: DateTime.now(),
    );
  }

  static void timeoutRecorded(String source) {
    snapshot.value = snapshot.value.copyWith(timeoutSource: source);
  }

  static void routerDecision(String value) {
    snapshot.value = snapshot.value.copyWith(routerDecision: value);
  }

  static void routeSelected({
    required String model,
    required String backendUrl,
    required String decision,
  }) {
    snapshot.value = snapshot.value.copyWith(
      routerDecision: decision,
      activeModel: model,
      currentBackendUrl: backendUrl,
    );
  }

  static void backendConfigurationUpdated({
    required bool backendConnected,
    required String backendUrl,
    required bool dotenvLoaded,
    required bool groqKeyExists,
    required bool serpApiKeyExists,
    required String activeModel,
    required String lastError,
    required String lastProviderResponse,
    required String lastRetrievalEvent,
    String? searchProviderSummary,
    List<String>? fallbackEvents,
  }) {
    snapshot.value = snapshot.value.copyWith(
      backendConnectivity: backendConnected ? 'Connected' : 'Disconnected',
      groqConnectivity: groqKeyExists
          ? 'Configured through local backend'
          : 'Missing local backend key',
      serpApiConnectivity: serpApiKeyExists
          ? 'Configured through local backend'
          : 'Missing local backend key',
      workerHealth: dotenvLoaded ? 'dotenv loaded' : 'dotenv not loaded',
      activeModel: activeModel,
      currentBackendUrl: backendUrl,
      lastError: lastError == 'No errors recorded' ? null : lastError,
      lastProviderResponse: lastProviderResponse,
      lastRetrievalEvent: lastRetrievalEvent,
      providerStatus: searchProviderSummary,
      fallbackEvents: fallbackEvents,
      clearError: lastError == 'No errors recorded',
    );
  }

  static void providerResponse({
    required String provider,
    required int statusCode,
    String? details,
  }) {
    final summary = details == null || details.trim().isEmpty
        ? '$provider $statusCode'
        : '$provider $statusCode: ${details.trim()}';
    snapshot.value = snapshot.value.copyWith(
      lastProviderResponse: summary,
      groqConnectivity:
          statusCode >= 200 && statusCode < 300 ? 'Connected' : 'Error',
      lastError: statusCode >= 200 && statusCode < 300
          ? null
          : details ?? '$provider returned $statusCode.',
      clearError: statusCode >= 200 && statusCode < 300,
    );
  }

  static void retrievalSkipped(String reason) {
    snapshot.value = snapshot.value.copyWith(
      retrievalStatus: 'Skipped',
      retrievalTriggerReason: reason,
      serpApiConnectivity: 'Idle',
      lastRetrievalEvent: 'Skipped: $reason',
      toolActivationLogs: _appendLog('Retrieval skipped: $reason'),
    );
  }

  static void retrievalStarted(String reason) {
    snapshot.value = snapshot.value.copyWith(
      retrievalStatus: 'Searching live web',
      retrievalTriggerReason: reason,
      serpApiConnectivity: 'Requesting SerpApi via Worker',
      workerHealth: 'Proxy request in flight',
      lastRetrievalEvent: 'Started: $reason',
      toolActivationLogs: _appendLog('Live search started: $reason'),
    );
  }

  static void retrievalFinished(ToolResult result) {
    final success = result.status == ToolResultStatus.success;
    snapshot.value = snapshot.value.copyWith(
      retrievalStatus: success
          ? 'Retrieved context ready'
          : 'Unavailable; continuing with Groq',
      serpApiConnectivity: success ? 'Search complete' : 'Fallback active',
      workerHealth:
          success ? 'Healthy for last request' : 'No context injected',
      lastSearchSummary: result.content,
      lastSources: result.sources,
      lastError: success ? null : result.error,
      lastRetrievalEvent:
          '${result.title}: ${result.status.name}${result.error == null ? '' : ' (${result.error})'}',
      toolActivationLogs: _appendLog(
        '${result.title}: ${result.status.name}${result.error == null ? '' : ' (${result.error})'}',
      ),
      fallbackEvents: success
          ? snapshot.value.fallbackEvents
          : _appendFallback(result.error ?? 'Retrieval produced no context.'),
      clearError: success,
    );
  }

  static void contextInjected(String preview) {
    snapshot.value = snapshot.value.copyWith(
      retrievalStatus: 'Injecting retrieved context',
      contextPreview: preview,
      orchestratorStatus: 'Context composed for Groq',
      toolActivationLogs: _appendLog('Retrieved context injected into prompt'),
    );
  }

  static void contextNotInjected() {
    snapshot.value = snapshot.value.copyWith(
      retrievalStatus: 'No external context injected',
      contextPreview: '',
    );
  }

  static void streamingStarted() {
    final current = snapshot.value;
    snapshot.value = current.copyWith(
      providerStatus: 'Groq streaming',
      retrievalStatus: current.retrievalStatus.contains('Injecting')
          ? 'Grounding response'
          : current.retrievalStatus,
      streamState: 'Streaming',
      sendStopState: 'Stop available',
      isStreaming: true,
    );
  }

  static void recordChunk(String chunk) {
    final current = snapshot.value;
    final now = DateTime.now();
    snapshot.value = current.copyWith(
      firstTokenAt: current.firstTokenAt ?? now,
      latencyMs:
          current.firstTokenAt == null && current.requestStartedAt != null
              ? now.difference(current.requestStartedAt!).inMilliseconds
              : current.latencyMs,
      chunkCount: current.chunkCount + 1,
      characterCount: current.characterCount + chunk.length,
      streamState: 'Streaming ${current.chunkCount + 1} chunks',
      isStreaming: true,
    );
  }

  static void streamingFinished() {
    final current = snapshot.value;
    final now = DateTime.now();
    snapshot.value = current.copyWith(
      providerStatus: 'Groq ready',
      orchestratorStatus: 'Idle',
      streamState: 'Complete',
      sendStopState: 'Send ready',
      isStreaming: false,
      completedAt: now,
      totalMs: current.requestStartedAt == null
          ? current.totalMs
          : now.difference(current.requestStartedAt!).inMilliseconds,
    );
  }

  static void streamingCancelled() {
    snapshot.value = snapshot.value.copyWith(
      providerStatus: 'Groq cancelled',
      orchestratorStatus: 'Idle',
      streamState: 'Cancelled',
      sendStopState: 'Send ready',
      isStreaming: false,
      fallbackEvents: _appendFallback('User stopped active stream.'),
    );
  }

  static void streamingFailed(String message) {
    snapshot.value = snapshot.value.copyWith(
      providerStatus: 'Groq error',
      orchestratorStatus: 'Idle',
      streamState: 'Error',
      sendStopState: 'Send ready',
      isStreaming: false,
      lastError: message,
      lastProviderResponse: message,
      fallbackEvents: _appendFallback(message),
    );
  }

  static List<String> _appendLog(String entry) {
    return [entry, ...snapshot.value.toolActivationLogs].take(8).toList();
  }

  static List<String> _appendFallback(String entry) {
    return [entry, ...snapshot.value.fallbackEvents].take(8).toList();
  }
}
