
class PlaceSearchConfig {
  static const bool useRealApi = bool.fromEnvironment(
    'SYNC_RO_USE_REAL_PLACES', defaultValue: false,
  );

  static const String baseUrl = String.fromEnvironment(
    'SYNC_RO_PLACE_API_URL',
    defaultValue: 'http://127.0.0.1:8000',
  );

  static const Duration timeout = Duration(seconds: 10);
}
