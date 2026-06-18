import 'package:flutter/foundation.dart';

import 'backend_config.dart';

/// SerpApi proxy configuration for live retrieval.
///
/// Do not pass SerpApi secrets through Flutter `--dart-define` values.
/// Flutter Web builds are browser-visible, so SerpApi must be reached through a
/// backend proxy that injects credentials server-side.
class SerpApiConfig {
  static const String proxyBaseUrl = '';
  static const String proxyRetrievalEndpoint = '';
  static const String localProxyBaseUrl = '';
  static const bool useLocalProxyFallback = false;

  static const String retrievalPath = '/v1/retrieval';

  static const String _envProxyBaseUrl = String.fromEnvironment(
    'SERPAPI_PROXY_BASE_URL',
    defaultValue: '',
  );
  static const String _envProxyRetrievalEndpoint = String.fromEnvironment(
    'SERPAPI_PROXY_RETRIEVAL_ENDPOINT',
    defaultValue: '',
  );
  static const String _envLocalProxyBaseUrl = String.fromEnvironment(
    'SERPAPI_LOCAL_PROXY_BASE_URL',
    defaultValue: BackendConfig.baseUrl,
  );
  static const bool _envUseLocalProxyFallback = bool.fromEnvironment(
    'SERPAPI_USE_LOCAL_PROXY_FALLBACK',
    defaultValue: false,
  );

  static String get retrievalEndpoint => _resolveEndpoint(
        explicitEndpoint: proxyRetrievalEndpoint.isNotEmpty
            ? proxyRetrievalEndpoint
            : _envProxyRetrievalEndpoint,
        baseUrl: proxyBaseUrl.isNotEmpty ? proxyBaseUrl : _envProxyBaseUrl,
      );

  static bool get localProxyFallbackEnabled =>
      kDebugMode && (useLocalProxyFallback || _envUseLocalProxyFallback);

  static String _resolveEndpoint({
    required String explicitEndpoint,
    required String baseUrl,
  }) {
    final endpoint = explicitEndpoint.trim();
    if (endpoint.isNotEmpty) return endpoint;

    final proxyBase = baseUrl.trim();
    if (proxyBase.isNotEmpty) return _joinUrl(proxyBase, retrievalPath);

    if (localProxyFallbackEnabled) {
      final localBase = localProxyBaseUrl.isNotEmpty
          ? localProxyBaseUrl
          : _envLocalProxyBaseUrl;
      return _joinUrl(localBase, retrievalPath);
    }

    return BackendConfig.retrievalEndpoint;
  }

  static String _joinUrl(String baseUrl, String path) {
    final trimmedBase = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final trimmedPath = path.startsWith('/') ? path.substring(1) : path;
    return '$trimmedBase/$trimmedPath';
  }
}
