
import '../models/route_candidate.dart';

class KakaoRouteParser {
  static List<RouteCandidate> parse(
    Map<String, dynamic> json,
  ) {
    if (json['status'] != 'OK') {
      throw FormatException(
        '카카오 경로 조회 실패: ${json['status']}',
      );
    }

    final routes = json['routes'];

    if (routes is! List) {
      throw const FormatException(
        '카카오 응답에 routes 목록이 없습니다.',
      );
    }

    final candidates = <RouteCandidate>[];

    for (var index = 0; index < routes.length; index++) {
      final route = _asMap(routes[index]);
      final properties = _asMap(route['properties']);
      final steps = route['steps'];

      if (steps is! List) {
        throw const FormatException(
          '카카오 경로에 steps 목록이 없습니다.',
        );
      }

      final segments = <RouteSegment>[];

      for (final rawStep in steps) {
        final step = _asMap(rawStep);
        final sp = _asMap(step['properties']);

        final type = _parseType(
          sp['type']?.toString() ?? '',
        );

        if (type == null) {
          continue;
        }

        // 실제 샘플에서는 time이 초 단위
        final seconds = _number(sp['time']);

        final path = step['path'];
        final geometry = <RoutePoint>[];

        if (path is Map) {
          final pathMap = _asMap(path);
          final points = pathMap['points'];

          if (points is List) {
            for (final point in points) {
              if (point is List && point.length >= 2) {
                final longitude = _number(point[0]);
                final latitude = _number(point[1]);

                geometry.add(
                  RoutePoint(
                    latitude: latitude.toDouble(),
                    longitude: longitude.toDouble(),
                  ),
                );
              }
            }
          }
        }

        segments.add(
          RouteSegment(
            type: type,
            lineName: _firstString(sp, ['lineName', 'routeName', 'route', 'line', 'name']),
            startName: _firstString(sp, ['startName', 'startStation', 'startStop', 'fromName', 'departureName']),
            endName: _firstString(sp, ['endName', 'endStation', 'endStop', 'toName', 'arrivalName']),
            description:
                sp['guidance']?.toString() ??
                _defaultDescription(type),
            durationMinutes: (seconds / 60).ceil(),
            geometry: geometry,
          ),
        );
      }

      final totalSeconds = _number(
        properties['totalTime'],
      );

      candidates.add(
        RouteCandidate(
          id: 'kakao_route_${index + 1}',
          title: _makeTitle(segments),
          segments: segments,
          transferCount: _number(
            properties['transfers'],
          ).toInt(),
          totalDurationMinutes:
              (totalSeconds / 60).ceil(),
          isRecommended: index == 0,
        ),
      );
    }

    return candidates;
  }

  static String? _firstString(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }

  static Map<String, dynamic> _asMap(dynamic value) {
    if (value is! Map) {
      throw const FormatException(
        '카카오 응답 객체 형식이 올바르지 않습니다.',
      );
    }

    return Map<String, dynamic>.from(value);
  }

  static num _number(dynamic value) {
    if (value is num) return value;

    if (value is String) {
      final parsed = num.tryParse(value);
      if (parsed != null) return parsed;
    }

    throw FormatException(
      '숫자 형식이 올바르지 않습니다: $value',
    );
  }

  static RouteSegmentType? _parseType(String type) {
    switch (type.toUpperCase()) {
      case 'WALKING':
      case 'WALK':
        return RouteSegmentType.walking;
      case 'BUS':
        return RouteSegmentType.bus;
      case 'SUBWAY':
        return RouteSegmentType.subway;
      case 'WAITING':
        return RouteSegmentType.waiting;
      default:
        return null;
    }
  }

  static String _defaultDescription(
    RouteSegmentType type,
  ) {
    switch (type) {
      case RouteSegmentType.walking:
        return '도보 이동';
      case RouteSegmentType.bus:
        return '버스 이동';
      case RouteSegmentType.subway:
        return '지하철 이동';
      case RouteSegmentType.waiting:
        return '대기';
    }
  }

  static String _makeTitle(
    List<RouteSegment> segments,
  ) {
    final types = segments
        .where(
          (segment) =>
              segment.type != RouteSegmentType.walking &&
              segment.type != RouteSegmentType.waiting,
        )
        .map((segment) {
          switch (segment.type) {
            case RouteSegmentType.bus:
              return '버스';
            case RouteSegmentType.subway:
              return '지하철';
            default:
              return '도보';
          }
        })
        .toSet()
        .toList();

    if (types.isEmpty) {
      return '도보 경로';
    }

    return '도보 + ${types.join(' + ')}';
  }
}
