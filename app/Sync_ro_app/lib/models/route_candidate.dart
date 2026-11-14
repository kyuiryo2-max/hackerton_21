enum RouteSegmentType { walking, bus, subway, waiting }

// 지도에 표시할 좌표
class RoutePoint {
  final double latitude;
  final double longitude;

  const RoutePoint({required this.latitude, required this.longitude});

  factory RoutePoint.fromJson(Map<String, dynamic> json) {
    return RoutePoint(
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
    );
  }
}

// 이동 구간
class RouteSegment {
  final RouteSegmentType type;
  final String description;
  final int durationMinutes;

  // 실제 지도 경로 좌표 (선택적)
  final List<RoutePoint> geometry;
  final String? startName;
  final String? endName;
  final String? lineName;

  const RouteSegment({
    required this.type,
    required this.description,
    required this.durationMinutes,
    this.geometry = const [],
    this.startName,
    this.endName,
    this.lineName,
    this.stopCount,
  });

  /// 탄 뒤 지나는 정류장·역 수 (서버 stop_count, 11/14)
  final int? stopCount;

  /// "1호선·1호선·1호선"처럼 같은 노선이 반복되면 한 번만, 다른 노선은 "262 · 273"
  static String uniqueLines(String raw) {
    final seen = <String>[];
    for (final part in raw.split(RegExp(r'\s*[·,/]\s*'))) {
      final p = part.trim();
      if (p.isNotEmpty && !seen.contains(p)) seen.add(p);
    }
    return seen.join(' · ');
  }
}

// 전체 경로 후보


class RouteCandidate {
  final String id;
  final String title;
  final List<RouteSegment> segments;
  final int transferCount;
  final bool isRecommended;

  // 추가: 실제 API에서 제공하는 총 이동시간
  final int? totalDurationMinutes;

  // 생성자
  const RouteCandidate({
    required this.id,
    required this.title,
    required this.segments,
    required this.transferCount,
    this.isRecommended = false,

    // 추가
    this.totalDurationMinutes,
  });

  // 총 이동시간
  int get totalMinutes =>
      totalDurationMinutes ??
      segments.fold(
        0,
        (sum, segment) => sum + segment.durationMinutes,
      );

  // 도보 이동시간
  int get walkingMinutes => segments
      .where(
        (segment) => segment.type == RouteSegmentType.walking,
      )
      .fold(
        0,
        (sum, segment) => sum + segment.durationMinutes,
      );

  // 대기시간
  int get waitingMinutes => segments
      .where(
        (segment) => segment.type == RouteSegmentType.waiting,
      )
      .fold(
        0,
        (sum, segment) => sum + segment.durationMinutes,
      );
}
