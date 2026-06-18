class BackendConfig {
  static const String baseUrl = String.fromEnvironment(
    'OMNICORE_BACKEND_URL',
    defaultValue: 'http://localhost:3000',
  );

  static String get healthEndpoint => _join('/health');
  static String get groqEndpoint => _join('/groq');
  static String get retrievalEndpoint => _join('/v1/retrieval');
  static String get configStatusEndpoint => _join('/config/status');
  static String get configKeysEndpoint => _join('/config/keys');
  static String get searchProviderConfigEndpoint =>
      _join('/config/search-providers');
  static String get searchProviderOrderEndpoint =>
      _join('/config/search-providers/order');
  static String get searchProviderTestEndpoint =>
      _join('/config/search-providers/test');

  static String _join(String path) {
    final trimmedBase = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final trimmedPath = path.startsWith('/') ? path.substring(1) : path;
    return '$trimmedBase/$trimmedPath';
  }
}
