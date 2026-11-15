import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sync_ro_app/services/ai_place_recommendation_service.dart';

void main() {
  test('서버 AI 추천 응답을 실제 매장 추천으로 바꿔요', () async {
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/api/places/recommend');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['text'], '고양이 사료 사야 돼');
      expect(body['lat'], 37.5862);
      expect(body['lng'], 127.0304);
      expect(body['limit'], 3);
      return http.Response(
        jsonEncode({
          'places': [
            {
              'name': '다이소 안암점',
              'address': '서울 성북구 안암로 1',
              'lat': 37.5865,
              'lng': 127.0305,
              'category': '다이소',
              'reason': '생활용품을 살 수 있어요.',
              'search_query': '다이소',
              'distance_m': 120,
              'verified': true,
            },
          ],
          'source': 'ai',
          'engine': 'ai+kakao',
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });

    final result = await AiPlaceRecommendationService(client: client).recommend(
      text: '  고양이 사료 사야 돼  ',
      latitude: 37.5862,
      longitude: 127.0304,
    );

    expect(result, hasLength(1));
    final place = result.first;
    expect(place.name, '다이소 안암점');
    expect(place.category, '다이소');
    expect(place.address, '서울 성북구 안암로 1');
    expect(place.distanceMeters, 120);
    expect(place.latitude, 37.5865);
    expect(place.longitude, 127.0305);
    expect(place.query, '다이소');
    expect(place.fromAi, isTrue);
  });

  test('서버가 503을 주면 이유를 담은 예외를 던져요', () async {
    final client = MockClient((_) async {
      return http.Response(
        jsonEncode({
          'error': {
            'code': 'ai_not_configured',
            'message': '서버에 AI 추천 설정이 없어요',
          },
        }),
        503,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });

    expect(
      () => AiPlaceRecommendationService(
        client: client,
      ).recommend(text: '고양이 사료', latitude: 37.5, longitude: 127.0),
      throwsA(
        isA<AiPlaceRecommendationException>().having(
          (e) => e.message,
          'message',
          '서버에 AI 추천 설정이 없어요',
        ),
      ),
    );
  });

  test('결과가 없으면 빈 목록을 돌려줘요', () async {
    final client = MockClient((_) async {
      return http.Response(
        jsonEncode({'places': [], 'message': '판매처를 찾지 못했어요.'}),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });

    final result = await AiPlaceRecommendationService(
      client: client,
    ).recommend(text: '회의 준비', latitude: 37.5, longitude: 127.0);
    expect(result, isEmpty);
  });

  test('응답 형식이 깨지면 예외를 던져요', () async {
    final client = MockClient((_) async {
      return http.Response('not-json', 200);
    });

    expect(
      () => AiPlaceRecommendationService(
        client: client,
      ).recommend(text: '고양이 사료', latitude: 37.5, longitude: 127.0),
      throwsA(isA<AiPlaceRecommendationException>()),
    );
  });
}
