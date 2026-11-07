
class TravelRecommendation {
  final int id;
  final String destination;
  final DateTime departureTime;
  final DateTime arrivalTime;
  final int travelMinutes;
  final int freeMinutes;
  final String suggestion;

  const TravelRecommendation({
    required this.id,
    required this.destination,
    required this.departureTime,
    required this.arrivalTime,
    required this.travelMinutes,
    required this.freeMinutes,
    required this.suggestion,
  });

  factory TravelRecommendation.fromJson(
    Map<String, dynamic> json,
  ) {
    return TravelRecommendation(
      id: (json['id'] as num).toInt(),
      destination: json['destination'] as String,
      departureTime: DateTime.parse(
        json['departure_time'] as String,
      ),
      arrivalTime: DateTime.parse(
        json['arrival_time'] as String,
      ),
      travelMinutes:
          (json['travel_minutes'] as num).toInt(),
      freeMinutes:
          (json['free_minutes'] as num).toInt(),
      suggestion: json['suggestion'] as String,
    );
  }
}
//{
  //"id": 1,
  //"destination": "스터디룸",
  //"departure_time": "2026-11-06T12:15:00",
  //"arrival_time": "2026-11-06T12:50:00",
  //"travel_minutes": 35,
  //"free_minutes": 20,
  //"suggestion": "출발 전 편의점에 들를 수 있어요."
//} 서버에서 다음과 같은 데이터를 받았다고 가정한 코드 , 확정 된 APIO 명세가 아님!