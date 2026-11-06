import 'route_candidate.dart';

class RoutePlan {
  final RouteCandidate candidate;
  final DateTime departureTime;
  final DateTime estimatedArrivalTime;
  final DateTime desiredArrivalTime;
  final int bufferMinutes;
  final int freeMinutes;

  const RoutePlan({
    required this.candidate,
    required this.departureTime,
    required this.estimatedArrivalTime,
    required this.desiredArrivalTime,
    required this.bufferMinutes,
    required this.freeMinutes,
  });

  bool get canLeaveOnTime => freeMinutes >= 0;
}
