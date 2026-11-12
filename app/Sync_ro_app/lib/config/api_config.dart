import 'runtime_mode.dart';

/// All backend HTTP calls share API_BASE_URL.
/// Example: flutter run --dart-define=API_BASE_URL=https://teumgil-server.onrender.com
class ApiConfig {
  /// Use the real server by default; offline samples require explicit opt-in.
  static const bool offlineDemo = bool.fromEnvironment(
      'SYNC_RO_OFFLINE_DEMO', defaultValue: false);
  // Demo data on the REAL server; distinct from offline demo assets.
  static bool get demoMode => RuntimeMode.instance.isDemo;
  static String get userId => RuntimeMode.instance.userId;
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL', defaultValue: 'https://teumgil-server.onrender.com');
  static String get normalizedBaseUrl => baseUrl.replaceFirst(RegExp(r'/+$'), '');
  static Uri endpoint(String path, [Map<String, String>? query]) =>
      Uri.parse('$normalizedBaseUrl${path.startsWith('/') ? path : '/$path'}')
          .replace(queryParameters: query);
  static const bool useMockData = true; // legacy recommendation fallback
  static const String recommendationsEndpoint = '/api/recommendations';
}
