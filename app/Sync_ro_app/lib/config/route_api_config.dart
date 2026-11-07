
class RouteApiConfig {
  // 기본값은 Mock 모드
  // 실행할 때 --dart-define으로 실제 API 사용 여부 변경
  static const bool useRealApi = bool.fromEnvironment(
    'SYNC_RO_USE_REAL_API',
    defaultValue: false,
  );

  // 백엔드 API 서버 주소
  static const String baseUrl = String.fromEnvironment(
    'SYNC_RO_API_URL',
    defaultValue: 'http://localhost:8000',
  );

  // API 응답 대기시간
  static const Duration timeout = Duration(seconds: 15);
}
