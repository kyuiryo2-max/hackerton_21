import 'place.dart';

class RouteRequest {
  final String origin;
  final String destination;
  final DateTime desiredArrivalTime;
  /// 도착 희망 시간을 사용자가 정했을 때만 있어요. 없으면 지금 출발 기준으로 찾아요 (11/16)
  final DateTime? arriveBy;

  final Place? originPlace;
  final Place? destinationPlace;

  const RouteRequest({
    required this.origin,
    required this.destination,
    required this.desiredArrivalTime,
    this.originPlace,
    this.destinationPlace,
    this.arriveBy,
  });

  Map<String, dynamic> toJson() {
    return {
      'origin': origin,
      'destination': destination,
      'desired_arrival_time': desiredArrivalTime.toIso8601String(),
      'origin_place_id': originPlace?.id,
      'destination_place_id': destinationPlace?.id,
      'origin_latitude': originPlace?.latitude,
      'origin_longitude': originPlace?.longitude,
      'destination_latitude': destinationPlace?.latitude,
      'destination_longitude': destinationPlace?.longitude,
    };
  }
}
