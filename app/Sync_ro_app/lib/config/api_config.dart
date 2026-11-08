/// All backend HTTP calls share API_BASE_URL.
/// Example: flutter run --dart-define=API_BASE_URL=https://teumgil-server.onrender.com
class ApiConfig {
  /// Offline demo by default. Explicitly set false to connect to a backend.
  static const bool offlineDemo = bool.fromEnvironment(
      'SYNC_RO_OFFLINE_DEMO', defaultValue: true);
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL', defaultValue: 'https://teumgil-server.onrender.com');
  static String get normalizedBaseUrl => baseUrl.replaceFirst(RegExp(r'/+$'), '');
  static Uri endpoint(String path, [Map<String, String>? query]) =>
      Uri.parse('${normalizedBaseUrl}${path.startsWith('/') ? path : '/$path'}')
          .replace(queryParameters: query);
  static const bool useMockData = true; // legacy recommendation fallback
  static const String recommendationsEndpoint = '/api/recommendations';
}
