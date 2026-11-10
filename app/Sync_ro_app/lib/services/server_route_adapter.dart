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
    final wait = (route['wait_min'] as num?)?.toInt() ?? 0;
    final moving = (route['moving_min'] as num?)?.toInt() ?? 0;
    final walk = (route['last_walk_min'] as num?)?.toInt() ?? 0;
    final rawLegs = route['segments'] ?? route['steps'];
    final legs = <RouteSegment>[];
    if (rawLegs is List && rawLegs.isNotEmpty) {
      for (final item in rawLegs) {
        final leg = _object(item);
        final type = _type('${leg['type'] ?? leg['mode'] ?? 'BUS'}');
        final start = leg['start_name'] ?? leg['origin_name'] ?? leg['start'];
        final end = leg['end_name'] ?? leg['destination_name'] ?? leg['end'];
        legs.add(RouteSegment(
          type: type,
          description: '${leg['guidance'] ?? leg['description'] ?? ''}',
          lineName: '${leg['line_name'] ?? leg['name'] ?? ''}',
          durationMinutes: (leg['duration_min'] as num?)?.toInt() ??
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
