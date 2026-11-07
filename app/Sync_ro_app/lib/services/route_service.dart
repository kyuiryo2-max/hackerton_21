
import '../models/route_request.dart';
import '../models/travel_recommendation.dart';

class RouteService {
  Future<TravelRecommendation> recommendRoute(
    RouteRequest request,
  ) async {
    // 서버 응답을 기다리는 상황을 가정
    await Future.delayed(
      const Duration(seconds: 1),
    );

    // 테스트용 고정 이동 시간
    const int travelMinutes = 35;

    // 도착 희망 시간보다 10분 일찍 도착
    const int bufferMinutes = 10;

    final arrivalTime = request.desiredArrivalTime.subtract(
      const Duration(minutes: bufferMinutes),
    );

    final departureTime = arrivalTime.subtract(
      const Duration(minutes: travelMinutes),
    );

    final freeMinutes =
        departureTime.difference(DateTime.now()).inMinutes;

    return TravelRecommendation(
      id: 1,
      destination: request.destination,
      departureTime: departureTime,
      arrivalTime: arrivalTime,
      travelMinutes: travelMinutes,
      freeMinutes: freeMinutes > 0 ? freeMinutes : 0,
      suggestion:
          '예상 이동 시간은 35분입니다. '
          '도착 희망 시간보다 10분 일찍 도착하도록 '
          '출발 시간을 계산했습니다.',
    );
  }
}
