import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/backend_config.dart';
import 'runtime_diagnostics.dart';

class BackendConfigurationStatus {
  const BackendConfigurationStatus({
    required this.backendConnected,
    required this.backendUrl,
    required this.dotenvLoaded,
    required this.groqKeyExists,
    required this.serpApiKeyExists,
    required this.groqKeyPreview,
    required this.serpApiKeyPreview,
    required this.groqEndpoint,
    required this.serpApiEndpoint,
    required this.activeModel,
    required this.lastError,
    required this.lastProviderResponse,
    required this.lastRetrievalEvent,
    required this.activeSearchProvider,
    required this.searchProviders,
    required this.fallbackEvents,
  });

  factory BackendConfigurationStatus.disconnected({
    String error = 'Backend status has not been checked.',
  }) {
    return BackendConfigurationStatus(
      backendConnected: false,
      backendUrl: BackendConfig.baseUrl,
      dotenvLoaded: false,
      groqKeyExists: false,
      serpApiKeyExists: false,
      groqKeyPreview: '',
      serpApiKeyPreview: '',
      groqEndpoint: BackendConfig.groqEndpoint,
      serpApiEndpoint: BackendConfig.retrievalEndpoint,
      activeModel: 'llama-3.3-70b-versatile',
      lastError: error,
      lastProviderResponse: 'No provider response yet',
      lastRetrievalEvent: 'No retrieval event yet',
      activeSearchProvider: '',
      searchProviders: const [],
      fallbackEvents: const [],
    );
  }

  factory BackendConfigurationStatus.fromJson(Map<String, dynamic> json) {
    final groq = _object(json['groq']);
    final serpApi = _object(json['serpapi']);
    final diagnostics = _object(json['diagnostics']);
    final search = _object(json['searchProviders']);
    final providers = _list(search['providers'])
        .map(BackendSearchProviderStatus.fromJson)
        .toList(growable: false);

    return BackendConfigurationStatus(
      backendConnected: json['backendConnected'] == true,
      backendUrl: _string(json['backendUrl'], BackendConfig.baseUrl),
      dotenvLoaded: json['dotenvLoaded'] == true,
      groqKeyExists: groq['keyExists'] == true,
      serpApiKeyExists: serpApi['keyExists'] == true,
      groqKeyPreview: _string(groq['keyPreview']),
      serpApiKeyPreview: _string(serpApi['keyPreview']),
      groqEndpoint: _string(groq['endpoint'], BackendConfig.groqEndpoint),
      serpApiEndpoint: _string(
        serpApi['retrievalEndpoint'],
        BackendConfig.retrievalEndpoint,
      ),
      activeModel: _string(
        groq['activeModel'] ?? diagnostics['activeModel'],
        'llama-3.3-70b-versatile',
      ),
      lastError: _string(diagnostics['lastError'], 'No errors recorded'),
      lastProviderResponse: _string(
        diagnostics['lastProviderResponse'],
        'No provider response yet',
      ),
      lastRetrievalEvent: _string(
        diagnostics['lastRetrievalEvent'],
        'No retrieval event yet',
      ),
      activeSearchProvider: _string(search['activeProvider']),
      searchProviders: providers,
      fallbackEvents: _list(search['fallbackEvents'])
          .map((item) => _string(item))
          .where((item) => item.isNotEmpty)
          .toList(growable: false),
    );
  }

  final bool backendConnected;
  final String backendUrl;
  final bool dotenvLoaded;
  final bool groqKeyExists;
  final bool serpApiKeyExists;
  final String groqKeyPreview;
  final String serpApiKeyPreview;
  final String groqEndpoint;
  final String serpApiEndpoint;
  final String activeModel;
  final String lastError;
  final String lastProviderResponse;
  final String lastRetrievalEvent;
  final String activeSearchProvider;
  final List<BackendSearchProviderStatus> searchProviders;
  final List<String> fallbackEvents;

  static Map<String, dynamic> _object(Object? value) {
    return value is Map<String, dynamic> ? value : const <String, dynamic>{};
  }

  static String _string(Object? value, [String fallback = '']) {
    return value is String && value.trim().isNotEmpty ? value.trim() : fallback;
  }

  static List<dynamic> _list(Object? value) {
    return value is List ? value : const <dynamic>[];
  }
}

class BackendSearchProviderStatus {
  const BackendSearchProviderStatus({
    required this.id,
    required this.name,
    required this.endpoint,
    required this.active,
    required this.enabled,
    required this.configured,
    required this.priority,
    required this.health,
    required this.successRate,
    required this.averageLatencyMs,
    required this.timeoutCount,
    required this.errorCount,
    required this.requestCount,
    required this.dailyRequests,
    required this.monthlyRequests,
    required this.lastSuccess,
    required this.lastFailure,
    required this.lastError,
    required this.circuitState,
    required this.circuitFailures,
    required this.circuitThreshold,
    required this.circuitNextRetryAt,
    required this.quotaStatus,
    required this.quotaAvailable,
    required this.quotaRemaining,
    required this.configFields,
  });

  factory BackendSearchProviderStatus.fromJson(Object? value) {
    final json = BackendConfigurationStatus._object(value);
    final circuit = BackendConfigurationStatus._object(json['circuit']);
    final quota = BackendConfigurationStatus._object(json['quota']);
    return BackendSearchProviderStatus(
      id: BackendConfigurationStatus._string(json['id']),
      name: BackendConfigurationStatus._string(json['name'], 'Provider'),
      endpoint: BackendConfigurationStatus._string(json['endpoint']),
      active: json['active'] == true,
      enabled: json['enabled'] == true,
      configured: json['configured'] == true,
      priority: _int(json['priority'], 100),
      health: _int(json['health'], 0),
      successRate: _double(json['successRate'], 0),
      averageLatencyMs: _int(json['averageLatencyMs'], 0),
      timeoutCount: _int(json['timeoutCount'], 0),
      errorCount: _int(json['errorCount'], 0),
      requestCount: _int(json['requestCount'], 0),
      dailyRequests: _int(json['dailyRequests'], 0),
      monthlyRequests: _int(json['monthlyRequests'], 0),
      lastSuccess: BackendConfigurationStatus._string(json['lastSuccess']),
      lastFailure: BackendConfigurationStatus._string(json['lastFailure']),
      lastError: BackendConfigurationStatus._string(json['lastError']),
      circuitState:
          BackendConfigurationStatus._string(circuit['state'], 'closed'),
      circuitFailures: _int(circuit['failures'], 0),
      circuitThreshold: _int(circuit['threshold'], 5),
      circuitNextRetryAt:
          BackendConfigurationStatus._string(circuit['nextRetryAt']),
      quotaStatus:
          BackendConfigurationStatus._string(quota['status'], 'not reported'),
      quotaAvailable: quota['available'] != false,
      quotaRemaining: _nullableInt(quota['remaining']),
      configFields: BackendConfigurationStatus._list(json['configFields'])
          .map(BackendSearchProviderConfigField.fromJson)
          .toList(growable: false),
    );
  }

  final String id;
  final String name;
  final String endpoint;
  final bool active;
  final bool enabled;
  final bool configured;
  final int priority;
  final int health;
  final double successRate;
  final int averageLatencyMs;
  final int timeoutCount;
  final int errorCount;
  final int requestCount;
  final int dailyRequests;
  final int monthlyRequests;
  final String lastSuccess;
  final String lastFailure;
  final String lastError;
  final String circuitState;
  final int circuitFailures;
  final int circuitThreshold;
  final String circuitNextRetryAt;
  final String quotaStatus;
  final bool quotaAvailable;
  final int? quotaRemaining;
  final List<BackendSearchProviderConfigField> configFields;

  static int _int(Object? value, int fallback) {
    final parsed = int.tryParse('$value');
    return parsed ?? fallback;
  }

  static int? _nullableInt(Object? value) {
    if (value == null) return null;
    return int.tryParse('$value');
  }

  static double _double(Object? value, double fallback) {
    final parsed = double.tryParse('$value');
    return parsed ?? fallback;
  }
}

class BackendSearchProviderConfigField {
  const BackendSearchProviderConfigField({
    required this.name,
    required this.label,
    required this.env,
    required this.secret,
    required this.keyExists,
    required this.keyPreview,
  });

  factory BackendSearchProviderConfigField.fromJson(Object? value) {
    final json = BackendConfigurationStatus._object(value);
    return BackendSearchProviderConfigField(
      name: BackendConfigurationStatus._string(json['name']),
      label: BackendConfigurationStatus._string(json['label'], 'Value'),
      env: BackendConfigurationStatus._string(json['env']),
      secret: json['secret'] == true,
      keyExists: json['keyExists'] == true,
      keyPreview: BackendConfigurationStatus._string(json['keyPreview']),
    );
  }

  final String name;
  final String label;
  final String env;
  final bool secret;
  final bool keyExists;
  final String keyPreview;
}

class BackendConfigurationService {
  static final status = ValueNotifier<BackendConfigurationStatus>(
    BackendConfigurationStatus.disconnected(),
  );

  static const Duration _timeout = Duration(seconds: 5);

  static Future<BackendConfigurationStatus> refreshStatus() async {
    try {
      final response = await http
          .get(Uri.parse(BackendConfig.configStatusEndpoint))
          .timeout(_timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw TimeoutException('Backend returned ${response.statusCode}.');
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Backend status payload was invalid.');
      }

      final next = BackendConfigurationStatus.fromJson(decoded);
      status.value = next;
      _publishDiagnostics(next);
      return next;
    } catch (error) {
      final next = BackendConfigurationStatus.disconnected(
        error: 'Backend status unavailable: $error',
      );
      status.value = next;
      _publishDiagnostics(next);
      return next;
    }
  }

  static Future<BackendConfigurationStatus> saveKeys({
    String? groqApiKey,
    String? serpApiKey,
    String? serperApiKey,
    String? googleSearchApiKey,
    String? googleSearchEngineId,
    String? tavilyApiKey,
    String? braveSearchApiKey,
  }) async {
    final payload = <String, String>{};
    final groq = groqApiKey?.trim();
    final serp = serpApiKey?.trim();
    final serper = serperApiKey?.trim();
    final googleKey = googleSearchApiKey?.trim();
    final googleEngine = googleSearchEngineId?.trim();
    final tavily = tavilyApiKey?.trim();
    final brave = braveSearchApiKey?.trim();
    if (groq != null && groq.isNotEmpty) payload['groqApiKey'] = groq;
    if (serp != null && serp.isNotEmpty) payload['serpApiKey'] = serp;
    if (serper != null && serper.isNotEmpty) {
      payload['serperApiKey'] = serper;
    }
    if (googleKey != null && googleKey.isNotEmpty) {
      payload['googleSearchApiKey'] = googleKey;
    }
    if (googleEngine != null && googleEngine.isNotEmpty) {
      payload['googleSearchEngineId'] = googleEngine;
    }
    if (tavily != null && tavily.isNotEmpty) payload['tavilyApiKey'] = tavily;
    if (brave != null && brave.isNotEmpty) {
      payload['braveSearchApiKey'] = brave;
    }

    if (payload.isEmpty) return status.value;

    final response = await http
        .post(
          Uri.parse(BackendConfig.configKeysEndpoint),
          headers: const {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(payload),
        )
        .timeout(_timeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Backend key update returned ${response.statusCode}.');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Backend key update payload was invalid.');
    }

    final next = BackendConfigurationStatus.fromJson(decoded);
    status.value = next;
    _publishDiagnostics(next);
    return next;
  }

  static Future<BackendConfigurationStatus> updateSearchProvider({
    required String provider,
    bool? enabled,
    int? priority,
    Map<String, String> fields = const {},
    int? dailyQuota,
    int? monthlyQuota,
  }) async {
    final payload = <String, Object?>{'provider': provider};
    if (enabled != null) payload['enabled'] = enabled;
    if (priority != null) payload['priority'] = priority;
    if (dailyQuota != null) payload['dailyQuota'] = dailyQuota;
    if (monthlyQuota != null) payload['monthlyQuota'] = monthlyQuota;
    for (final entry in fields.entries) {
      final value = entry.value.trim();
      if (value.isNotEmpty) payload[entry.key] = value;
    }

    final decoded = await _postJson(
      BackendConfig.searchProviderConfigEndpoint,
      payload,
      'Search provider update',
    );
    final next = BackendConfigurationStatus.fromJson(decoded);
    status.value = next;
    _publishDiagnostics(next);
    return next;
  }

  static Future<BackendConfigurationStatus> updateSearchProviderOrder(
    List<String> providerIds,
  ) async {
    final decoded = await _postJson(
      BackendConfig.searchProviderOrderEndpoint,
      {
        'providers': providerIds,
      },
      'Search provider order update',
    );
    final next = BackendConfigurationStatus.fromJson(decoded);
    status.value = next;
    _publishDiagnostics(next);
    return next;
  }

  static Future<Map<String, dynamic>> testSearchProvider(
    String provider, {
    String query = 'OmniCore AI search provider test',
  }) async {
    final decoded = await _postJson(
      BackendConfig.searchProviderTestEndpoint,
      {
        'provider': provider,
        'query': query,
      },
      'Search provider connectivity test',
      allowFailure: true,
    );
    if (decoded['status'] is Map<String, dynamic>) {
      final next = BackendConfigurationStatus.fromJson(decoded['status']);
      status.value = next;
      _publishDiagnostics(next);
    } else {
      await refreshStatus();
    }
    return decoded;
  }

  static Future<Map<String, dynamic>> _postJson(
    String endpoint,
    Map<String, Object?> payload,
    String label, {
    bool allowFailure = false,
  }) async {
    final response = await http
        .post(
          Uri.parse(endpoint),
          headers: const {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(payload),
        )
        .timeout(_timeout);

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('$label payload was invalid.');
    }
    if (!allowFailure &&
        (response.statusCode < 200 || response.statusCode >= 300)) {
      throw Exception('$label returned ${response.statusCode}.');
    }
    return decoded;
  }

  static void _publishDiagnostics(BackendConfigurationStatus next) {
    RuntimeDiagnostics.backendConfigurationUpdated(
      backendConnected: next.backendConnected,
      backendUrl: next.backendUrl,
      dotenvLoaded: next.dotenvLoaded,
      groqKeyExists: next.groqKeyExists,
      serpApiKeyExists: next.serpApiKeyExists,
      activeModel: next.activeModel,
      lastError: next.lastError,
      lastProviderResponse: next.lastProviderResponse,
      lastRetrievalEvent: next.lastRetrievalEvent,
      searchProviderSummary: next.searchProviders.isEmpty
          ? 'No search providers reported'
          : '${next.activeSearchProvider.isEmpty ? 'No active provider' : 'Active: ${next.activeSearchProvider}'} / ${next.searchProviders.where((provider) => provider.configured).length} configured',
      fallbackEvents: next.fallbackEvents,
    );
  }
}
