import 'api_config.dart';
class RouteApiConfig {
  // Existing route-search endpoint is independent from the confirmed demo APIs.
  static const bool useRealApi = bool.fromEnvironment('SYNC_RO_USE_REAL_API', defaultValue: false);
  static String get baseUrl => ApiConfig.normalizedBaseUrl;
  static const Duration timeout = Duration(seconds: 15);
}
