
enum RouteSegmentType {
  walking,
  bus,
  subway,
  waiting,
}

class RouteSegment {
  final RouteSegmentType type;
  final String description;
  final int durationMinutes;

  const RouteSegment({
    required this.type,
    required this.description,
    required this.durationMinutes,
  });
}

class RouteCandidate {
  final String id;
  final String title;
  final List<RouteSegment> segments;
  final int transferCount;
  final bool isRecommended;

  const RouteCandidate({
    required this.id,
    required this.title,
    required this.segments,
    required this.transferCount,
    this.isRecommended = false,
  });

  int get totalMinutes => segments.fold(
        0,
        (sum, segment) => sum + segment.durationMinutes,
      );

  int get walkingMinutes => segments
      .where((segment) =>
          segment.type == RouteSegmentType.walking)
      .fold(
        0,
        (sum, segment) => sum + segment.durationMinutes,
      );

  int get waitingMinutes => segments
      .where((segment) =>
          segment.type == RouteSegmentType.waiting)
      .fold(
        0,
        (sum, segment) => sum + segment.durationMinutes,
      );
}
