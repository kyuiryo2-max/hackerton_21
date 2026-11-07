
import '../models/route_candidate.dart';
import '../models/route_plan.dart';

class RoutePlanningService {
  static const int defaultBufferMinutes = 10;

  RoutePlan createPlan({
    required RouteCandidate candidate,
    required DateTime desiredArrivalTime,
    DateTime? now,
    int bufferMinutes = defaultBufferMinutes,
  }) {
    if (bufferMinutes < 0) {
      throw ArgumentError(
        '여유시간은 0분 이상이어야 합니다.',
      );
    }

    final currentTime = now ?? DateTime.now();

    // 실제 API 총 이동시간을 우선 사용
    // Mock 데이터라면 구간별 이동시간 합계 사용
    final travelMinutes = candidate.totalMinutes;

    if (travelMinutes <= 0) {
      throw StateError(
        '유효한 경로 이동시간이 없습니다.',
      );
    }

    final departureTime = desiredArrivalTime.subtract(
      Duration(
        minutes: travelMinutes + bufferMinutes,
      ),
    );

    final estimatedArrivalTime = departureTime.add(
      Duration(minutes: travelMinutes),
    );

    final freeMinutes = departureTime
        .difference(currentTime)
        .inMinutes;

    return RoutePlan(
      candidate: candidate,
      departureTime: departureTime,
      estimatedArrivalTime: estimatedArrivalTime,
      desiredArrivalTime: desiredArrivalTime,
      bufferMinutes: bufferMinutes,
      freeMinutes: freeMinutes,
    );
  }
}
