/// 메모나 할 일 문장에서 찾은 구매 가능 장소 후보.
///
/// [name]은 사용자에게 보여 줄 장소 이름(브랜드 또는 장소 종류)이고,
/// [category]는 기존 플래너의 장소 종류와 맞추기 위한 값이에요.
class PlaceRecommendation {
  const PlaceRecommendation({
    required this.name,
    required this.category,
    required this.reason,
    this.searchQuery,
    this.score = 0,
    this.address,
    this.distanceMeters,
    this.latitude,
    this.longitude,
    this.fromAi = false,
  });

  final String name;
  final String category;
  final String reason;

  /// 장소 검색 화면에 넣을 검색어. 비어 있으면 [name]을 써요.
  final String? searchQuery;

  /// 낮을수록 먼저 보여 줘요.
  final int score;

  /// AI가 카카오로 확인한 실제 지점의 도로명·지번 주소예요.
  final String? address;

  /// 현재 위치에서 실제 지점까지의 거리(미터)예요.
  final int? distanceMeters;

  /// AI가 카카오로 확인한 실제 지점의 좌표예요. 로컬 추천은 비어 있어요.
  final double? latitude;
  final double? longitude;

  /// 로컬 의미 규칙이 아니라 서버 AI 추천으로 만든 결과인지 여부예요.
  final bool fromAi;

  String get query => (searchQuery == null || searchQuery!.trim().isEmpty)
      ? name
      : searchQuery!.trim();
}
