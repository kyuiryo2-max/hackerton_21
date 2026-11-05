
import '../models/travel_recommendation.dart';

final List<TravelRecommendation> mockRecommendations = [
  TravelRecommendation(
    id: 1,
    destination: '스터디룸',
    departureTime: DateTime(2026, 11, 6, 12, 15),
    arrivalTime: DateTime(2026, 11, 6, 12, 50),
    travelMinutes: 35,
    freeMinutes: 20,
    suggestion: '출발 전 가까운 편의점에 들를 수 있어요.',
  ),
  TravelRecommendation(
    id: 2,
    destination: '중앙도서관',
    departureTime: DateTime(2026, 11, 6, 16, 20),
    arrivalTime: DateTime(2026, 11, 6, 16, 50),
    travelMinutes: 30,
    freeMinutes: 15,
    suggestion: '이동 전 간단한 할 일을 처리할 수 있어요.',
  ),
];
//동작 확인용 예시. 실제 교통 정보나 AI 계산 결과아님 추후 API로 교체