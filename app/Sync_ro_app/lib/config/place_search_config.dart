import 'api_config.dart';
class PlaceSearchConfig {
  // Optional, because the deployed server may not implement /api/places/search.
  static const bool useRealApi = bool.fromEnvironment('SYNC_RO_USE_REAL_PLACES', defaultValue: false);
  static String get baseUrl => ApiConfig.normalizedBaseUrl;
  static const Duration timeout = Duration(seconds: 12);
}
