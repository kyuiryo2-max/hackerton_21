
import '../models/route_request.dart';
import '../models/travel_recommendation.dart';
import 'route_api_service.dart';
import 'route_planning_service.dart';

class RouteService {
  final RouteApiService _routeApiService;
  final RoutePlanningService _routePlanningService;

  RouteService({
    RouteApiService? routeApiService,
    RoutePlanningService? routePlanningService,
  })  : _routeApiService = routeApiService ?? RouteApiService(),
        _routePlanningService =
            routePlanningService ?? RoutePlanningService();

  Future<TravelRecommendation> recommendRoute(
    RouteRequest request,
  ) async {
    // 1. Mock 또는 실제 API에서 경로 후보 조회
    final candidates =
        await _routeApiService.searchRoutes(request);

    if (candidates.isEmpty) {
      throw StateError('검색된 이동 경로가 없습니다.');
    }

    // 2. 현재는 총 이동시간이 가장 짧은 경로 선택
    final sortedCandidates = [...candidates]
      ..sort((a, b) => a.totalMinutes.compareTo(b.totalMinutes));

    final selectedCandidate = sortedCandidates.first;

    // 3. 기존 출발시간 계산 서비스 활용
    final plan = _routePlanningService.createPlan(
      candidate: selectedCandidate,
      desiredArrivalTime: request.desiredArrivalTime,
    );

    // 4. 기존 화면에서 사용하는 모델로 변환
    return TravelRecommendation(
      id: 1,
      destination: request.destination,
      departureTime: plan.departureTime,
      arrivalTime: plan.estimatedArrivalTime,
      travelMinutes: selectedCandidate.totalMinutes,
      freeMinutes:
          plan.freeMinutes > 0 ? plan.freeMinutes : 0,
      suggestion:
          '${selectedCandidate.title} 경로를 추천합니다. '
          '예상 이동시간은 ${selectedCandidate.totalMinutes}분이며, '
          '환승은 ${selectedCandidate.transferCount}회입니다. '
          '도착 희망 시간보다 ${plan.bufferMinutes}분 '
          '일찍 도착하도록 출발시간을 계산했습니다.',
    );
  }
}
