class ApiConfig {
  // true: 임시 데이터 사용
  // false: 실제 서버 API 사용
  static const bool useMockData = true;

  // Android 에뮬레이터에서 PC의 localhost에 접근하는 주소
  static const String baseUrl = 'http://10.0.2.2:8000';

  static const String recommendationsEndpoint = '/api/recommendations';
}
