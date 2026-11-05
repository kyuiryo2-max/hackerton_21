
import '../config/api_config.dart';
import '../data/mock_recommendations.dart';
import '../models/travel_recommendation.dart';
import 'api_service.dart';

class RecommendationService {
  final ApiService _apiService;

  RecommendationService({ApiService? apiService})
      : _apiService = apiService ?? ApiService();

  Future<List<TravelRecommendation>>
      getRecommendations() async {
    if (ApiConfig.useMockData) {
      await Future.delayed(
        const Duration(milliseconds: 500),
      );

      return List<TravelRecommendation>.from(
        mockRecommendations,
      );
    }

    final data = await _apiService.get(
      ApiConfig.recommendationsEndpoint,
    );

    if (data is! List) {
      throw const FormatException(
        '추천 API 응답은 JSON 배열이어야 합니다.',
      );
    }

    return data.map((item) {
      return TravelRecommendation.fromJson(
        Map<String, dynamic>.from(item as Map),
      );
    }).toList();
  }

  void dispose() {
    _apiService.dispose();
  }
}
