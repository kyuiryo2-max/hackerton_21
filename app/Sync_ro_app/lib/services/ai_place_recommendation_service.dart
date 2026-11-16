import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../models/place_recommendation.dart';

/// 서버 AI 장소 추천이 실패했을 때 화면에 보여 줄 이유를 담아요.
class AiPlaceRecommendationException implements Exception {
  const AiPlaceRecommendationException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 로컬 의미 규칙이 비었을 때만 호출하는 서버 AI 추천 서비스예요.
///
/// AI 키는 앱에 넣지 않아요. 서버가 AI로 매장 후보를 고르고 카카오 장소
/// 검색으로 실제 지점을 확인한 뒤 돌려줘요.
class AiPlaceRecommendationService {
  const AiPlaceRecommendationService({this.client});

  /// 테스트에서 가짜 HTTP 클라이언트를 넣을 때 써요.
  final http.Client? client;

  // AI 응답 재시도와 카카오 장소 검색이 겹칠 수 있어 넉넉히 기다려요.
  static const Duration timeout = Duration(seconds: 30);

  Future<List<PlaceRecommendation>> recommend({
    required String text,
    double? latitude,
    double? longitude,
    int limit = 3,
  }) async {
    final keyword = text.trim();
    if (keyword.isEmpty || limit <= 0) return const [];

    final body = <String, dynamic>{'text': keyword, 'limit': limit};
    if (latitude != null && longitude != null) {
      body['lat'] = latitude;
      body['lng'] = longitude;
    }

    final requestClient = client ?? http.Client();
    try {
      final response = await requestClient
          .post(
            ApiConfig.endpoint('/api/places/recommend'),
            headers: const {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
      if (response.statusCode != 200) {
        throw AiPlaceRecommendationException(_errorMessage(response));
      }
      return _parsePlaces(response.bodyBytes);
    } on AiPlaceRecommendationException {
      rethrow;
    } on TimeoutException {
      throw const AiPlaceRecommendationException('AI 추천 응답이 늦어지고 있어요.');
    } catch (_) {
      throw const AiPlaceRecommendationException('AI 추천을 불러오지 못했어요.');
    } finally {
      if (client == null) requestClient.close();
    }
  }

  List<PlaceRecommendation> _parsePlaces(List<int> bodyBytes) {
    final dynamic decoded = jsonDecode(utf8.decode(bodyBytes));
    final dynamic raw = decoded is Map ? decoded['places'] : null;
    if (raw is! List) {
      throw const AiPlaceRecommendationException('AI 추천 결과 형식이 올바르지 않아요.');
    }
    final result = <PlaceRecommendation>[];
    for (var index = 0; index < raw.length; index++) {
      final item = raw[index];
      if (item is! Map) continue;
      final name = '${item['name'] ?? ''}'.trim();
      if (name.isEmpty) continue;
      final category = '${item['category'] ?? '기타'}'.trim();
      final reason = '${item['reason'] ?? '현재 위치 주변에서 찾은 매장이에요.'}'.trim();
      final query = '${item['search_query'] ?? name}'.trim();
      result.add(
        PlaceRecommendation(
          name: name,
          category: category.isEmpty ? '기타' : category,
          reason: reason.isEmpty ? '현재 위치 주변에서 찾은 매장이에요.' : reason,
          searchQuery: query.isEmpty ? name : query,
          score: index * 10,
          address: '${item['address'] ?? ''}'.trim().isEmpty
              ? null
              : '${item['address']}'.trim(),
          distanceMeters: _integer(item['distance_m']),
          latitude: _decimal(item['lat']),
          longitude: _decimal(item['lng']),
          fromAi: true,
        ),
      );
    }
    return result;
  }

  int? _integer(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse('$value');
  }

  double? _decimal(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse('$value');
  }

  String _errorMessage(http.Response response) {
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map && '${error['message'] ?? ''}'.trim().isNotEmpty) {
          return '${error['message']}'.trim();
        }
        if ('${decoded['message'] ?? ''}'.trim().isNotEmpty) {
          return '${decoded['message']}'.trim();
        }
      }
    } catch (_) {
      // 서버가 JSON이 아닌 오류를 줘도 아래 기본 문장으로 안내해요.
    }
    if (response.statusCode == 404 ||
        response.statusCode == 405 ||
        response.statusCode == 501) {
      return 'AI 추천 서버가 아직 준비되지 않았어요.';
    }
    if (response.statusCode == 503) {
      return 'AI 추천 서버가 아직 준비되지 않았어요.';
    }
    return 'AI 추천을 불러오지 못했어요.';
  }
}
