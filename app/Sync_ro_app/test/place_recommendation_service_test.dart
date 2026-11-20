import 'package:flutter_test/flutter_test.dart';
import 'package:sync_ro_app/services/place_recommendation_service.dart';

void main() {
  const service = PlaceRecommendationService();

  test('커피를 사야 돼 → 카페 브랜드를 추천해요', () {
    final result = service.recommend('커피를 사야 돼');

    expect(
      result.map((item) => item.name),
      containsAll(['스타벅스', '메가커피', '컴포즈커피']),
    );
    expect(result.first.name, '스타벅스');
    expect(result.every((item) => item.category == '카페'), isTrue);
    expect(result.first.query, '스타벅스');
  });

  test('슬리퍼를 사야 돼 → 다이소·편의점·문구점을 추천해요', () {
    final result = service.recommend('슬리퍼를 사야 돼');

    expect(result.map((item) => item.name).toList(), ['다이소', '편의점', '문구점']);
    expect(result.first.category, '다이소');
  });

  test('이어폰을 사야 돼 → 마트가 아니라 다이소·편의점을 추천해요', () {
    final result = service.recommend('이어폰 사야 돼');

    expect(result.first.name, '다이소');
    expect(result.map((item) => item.name), containsAll(['다이소', '편의점']));
    expect(result.map((item) => item.name), isNot(contains('마트')));
  });

  test('음료를 사야 돼 → 편의점·마트·카페를 추천해요', () {
    final result = service.recommend('음료를 사야 돼');

    expect(result.map((item) => item.name).toList(), ['편의점', '마트', '카페']);
  });

  test('물건만 말해도 구매 가능한 곳을 추천해요', () {
    final result = service.recommend('물건');

    expect(result.map((item) => item.name).toList(), ['편의점', '마트', '다이소']);
  });

  test('문구류는 문구점을 먼저 추천해요', () {
    final result = service.recommend('볼펜 사야 돼');

    expect(result.first.name, '문구점');
    expect(result.map((item) => item.name), contains('다이소'));
  });

  test('약 사기는 약국을 먼저 추천해요', () {
    final result = service.recommend('약 사기');

    expect(result.first.name, '약국');
    expect(result.first.category, '약국');
  });

  test('브랜드를 직접 말하면 그 브랜드를 가장 먼저 추천해요', () {
    final result = service.recommend('메가커피에서 커피 사기');

    expect(result.first.name, '메가커피');
  });

  test('장소와 관계없는 문장은 빈 목록을 돌려줘요', () {
    expect(service.recommend('오늘 날씨 어때?'), isEmpty);
    expect(service.recommend('회의 준비'), isEmpty);
  });

  test('로컬 규칙에 없는 물건은 AI fallback을 위해 빈 목록을 돌려줘요', () {
    expect(service.recommend('고양이 사료 사야 돼'), isEmpty);
  });

  test('limit으로 추천 개수를 제한해요', () {
    expect(service.recommend('커피 사기', limit: 1), hasLength(1));
  });
}
