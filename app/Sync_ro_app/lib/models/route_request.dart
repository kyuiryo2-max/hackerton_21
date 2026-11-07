import 'place.dart';

class RouteRequest {
  final String origin;
  final String destination;
  final DateTime desiredArrivalTime;

  final Place? originPlace;
  final Place? destinationPlace;

  const RouteRequest({
    required this.origin,
    required this.destination,
    required this.desiredArrivalTime,
    this.originPlace,
    this.destinationPlace,
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
