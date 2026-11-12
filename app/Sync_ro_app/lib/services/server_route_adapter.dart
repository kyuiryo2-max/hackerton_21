import '../models/route_candidate.dart';

/// Map actual /api/plan routes into the same UI model used by manual searches.
/// Only enrich a route with /api/demo/context geometry when its identity matches.
class ServerRouteAdapter {
  static Map<String, dynamic> _object(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  static List<RoutePoint> _points(dynamic value) {
    if (value is! List) return const [];
    return value.map((item) {
      if (item is List && item.length >= 2 && item[0] is num && item[1] is num) {
        // Server polyline points are [longitude, latitude].
        return RoutePoint(latitude: (item[1] as num).toDouble(),
            longitude: (item[0] as num).toDouble());
      }
      final p = _object(item);
      final lat = p['lat'] ?? p['latitude'];
      final lng = p['lng'] ?? p['longitude'];
      if (lat is num && lng is num) {
        return RoutePoint(latitude: lat.toDouble(), longitude: lng.toDouble());
      }
      return null;
    }).whereType<RoutePoint>().toList();
  }

  static RouteSegmentType _type(String raw) {
    final v = raw.toUpperCase();
    if (v.contains('WALK')) return RouteSegmentType.walking;
    if (v.contains('WAIT')) return RouteSegmentType.waiting;
    if (v.contains('SUBWAY') || v.contains('METRO') || v.contains('TRAIN')) {
      return RouteSegmentType.subway;
    }
    return RouteSegmentType.bus;
  }

  static bool _matches(Map<String, dynamic> route, Map<String, dynamic> context) {
    final demo = _object(context['route']);
    if (demo.isEmpty) return false;
    return '${route['name']}'.trim() == '${demo['name']}'.trim() &&
        '${route['type']}'.toUpperCase() == '${demo['type']}'.toUpperCase();
  }

  static RouteCandidate fromPlan(Map<String, dynamic> route, int index,
      {Map<String, dynamic>? context}) {
    final demo = context != null && _matches(route, context) ?
        _object(context['route']) : <String, dynamic>{};
    final kind = _type('${route['type'] ?? 'BUS'}');
    final name = '${route['name'] ?? '대중교통'}';
    final stops = (route['stops'] is List ? route['stops'] as List :
        demo['stops'] is List ? demo['stops'] as List : const [])
        .map((s) => '$s').toList();
    var wait = (route['wait_min'] as num?)?.toInt() ?? 0;
    // 타임라인은 출발 시각부터 더해 가요. 서버 wait_min 은 "지금부터" 차가 올 때까지라서,
    // 출발 시각(depart_at)이 있으면 그 기준으로 다시 계산해요: 탑승 − 출발 − 처음 도보 (11/13)
    final departAt = DateTime.tryParse('${route['depart_at'] ?? ''}');
    final boardAt = DateTime.tryParse('${route['board_at'] ?? ''}');
    final firstWalk = (route['first_walk_min'] as num?)?.toInt() ?? 0;
    if (departAt != null && boardAt != null) {
      final m = boardAt.difference(departAt).inMinutes - firstWalk;
      wait = m < 0 ? 0 : m;
    }
    final moving = (route['moving_min'] as num?)?.toInt() ?? 0;
    final walk = (route['last_walk_min'] as num?)?.toInt() ?? 0;
    // 서버 /api/plan 은 11/13부터 routes[].legs (도보·버스·지하철 구간, from/to/minutes/points)를 줘요.
    final serverLegs = route['legs'];
    final rawLegs = serverLegs ?? route['segments'] ?? route['steps'];
    final legs = <RouteSegment>[];
    if (rawLegs is List && rawLegs.isNotEmpty) {
      var rideCount = 0;
      for (final item in rawLegs) {
        final leg = _object(item);
        final type = _type('${leg['type'] ?? leg['mode'] ?? 'BUS'}');
        final start = leg['from'] ?? leg['start_name'] ?? leg['origin_name'] ?? leg['start'];
        final end = leg['to'] ?? leg['destination_name'] ?? leg['end_name'] ?? leg['end'];
        // 탈것 구간 앞의 대기 (서버가 실시간 도착 정보로 계산해 주면 표시).
        // wait_source: realtime(실시간) / interval(배차간격 추정)
        // legs 형식은 첫 탑승 대기를 경로 카드의 wait_min 으로 줘요.
        final legWait = (leg['wait_min'] as num?)?.toInt() ??
            (serverLegs != null && rideCount == 0 ? wait : null);
        final isRide = type == RouteSegmentType.bus || type == RouteSegmentType.subway;
        if (isRide && legWait != null && legWait > 0) {
          final estimated = '${leg['wait_source'] ?? ''}' == 'interval';
          legs.add(RouteSegment(
            type: RouteSegmentType.waiting,
            description: '${rideCount == 0 ? '탑승 대기' : '환승 대기'}${estimated ? ' (배차간격 추정)' : ''}',
            lineName: rideCount == 0 ? '탑승 대기' : '환승 대기',
            durationMinutes: legWait,
            startName: start is String ? start : null,
            endName: start is String ? start : null,
          ));
        }
        if (isRide) rideCount++;
        legs.add(RouteSegment(
          type: type,
          description: '${leg['guidance'] ?? leg['description'] ?? ''}',
          lineName: '${leg['line_name'] ?? leg['name'] ?? ''}',
          durationMinutes: (leg['minutes'] as num?)?.toInt() ??
              (leg['duration_min'] as num?)?.toInt() ??
              (leg['moving_min'] as num?)?.toInt() ?? 0,
          startName: start is String ? start : null,
          endName: end is String ? end : null,
          geometry: _points(leg['path'] ?? leg['points']),
        ));
      }
    } else {
      if (wait > 0) {
        legs.add(RouteSegment(type: RouteSegmentType.waiting,
            description: '대중교통 대기', durationMinutes: wait,
            startName: stops.isNotEmpty ? stops.first : null,
            endName: stops.isNotEmpty ? stops.first : null));
      }
      legs.add(RouteSegment(type: kind,
          description: '${route['guidance'] ?? name}',
          lineName: name, durationMinutes: moving,
          startName: stops.isNotEmpty ? stops.first : null,
          endName: stops.isNotEmpty ? stops.last : null,
          geometry: _points(route['path'] ?? demo['path'])));
      if (walk > 0) {
        legs.add(RouteSegment(type: RouteSegmentType.walking,
            description: '도착지까지 도보', durationMinutes: walk,
            startName: stops.isNotEmpty ? stops.last : null));
      }
    }
    return RouteCandidate(
      id: 'server_${route['rank'] ?? index + 1}',
      title: '${route['guidance'] ?? name}',
      segments: legs,
      transferCount: (route['transfers'] as num?)?.toInt() ?? 0,
      totalDurationMinutes: (route['total_min'] as num?)?.toInt(),
      isRecommended: index == 0,
    );
  }
}
