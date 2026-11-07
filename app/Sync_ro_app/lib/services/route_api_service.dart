import 'dart:convert';
import 'kakao_route_parser.dart';
import 'package:http/http.dart' as http;

import '../config/route_api_config.dart';
import '../models/route_candidate.dart';
import '../models/route_request.dart';

class RouteApiService {
  Future<List<RouteCandidate>> searchRoutes(RouteRequest request) async {
    if (!RouteApiConfig.useRealApi) {
      return _mockRoutes();
    }

    return _fetchRoutes(request);
  }

  Future<List<RouteCandidate>> _fetchRoutes(RouteRequest request) async {
    final origin = request.originPlace;
    final destination = request.destinationPlace;

    if (origin == null || destination == null) {
      throw Exception(
        '실제 경로 탐색을 위해 출발지와 목적지를 '
        '장소 검색에서 선택해 주세요.',
      );
    }

    final baseUrl = RouteApiConfig.baseUrl.replaceFirst(RegExp(r'/$'), '');

    final uri = Uri.parse('$baseUrl/api/routes/search');

    final response = await http
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'origin': {
              'latitude': origin.latitude,
              'longitude': origin.longitude,
            },
            'destination': {
              'latitude': destination.latitude,
              'longitude': destination.longitude,
            },
            'desiredArrivalTime': request.desiredArrivalTime.toIso8601String(),
          }),
        )
        .timeout(RouteApiConfig.timeout);

    if (response.statusCode != 200) {
      throw Exception('경로 탐색 실패: HTTP ${response.statusCode}');
    }

    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is Map<String, dynamic> &&
        decoded['status'] == 'OK' &&
        decoded['routes'] is List) {
      return KakaoRouteParser.parse(decoded);
    }

    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('경로 API 응답 형식이 올바르지 않습니다.');
    }

    final routesJson = decoded['routes'];

    if (routesJson is! List) {
      throw const FormatException('응답에 routes 목록이 없습니다.');
    }

    return routesJson.map((route) {
      if (route is! Map<String, dynamic>) {
        throw const FormatException('경로 데이터 형식이 올바르지 않습니다.');
      }

      final segmentsJson = route['segments'];

      if (segmentsJson is! List) {
        throw const FormatException('경로 구간 데이터가 없습니다.');
      }

      final segments = segmentsJson.map((segment) {
        if (segment is! Map<String, dynamic>) {
          throw const FormatException('이동 구간 형식이 올바르지 않습니다.');
        }

        final geometryJson = segment['geometry'];

        final geometry = geometryJson is List
            ? geometryJson.map((point) {
                if (point is! Map<String, dynamic>) {
                  throw const FormatException('경로 좌표 형식이 올바르지 않습니다.');
                }

                return RoutePoint.fromJson(point);
              }).toList()
            : <RoutePoint>[];

        return RouteSegment(
          type: _parseSegmentType(segment['type'] as String),
          description: segment['description'] as String,
          durationMinutes: (segment['durationMinutes'] as num).toInt(),
          geometry: geometry,
        );
      }).toList();

      return RouteCandidate(
        id: route['id'] as String,
        title: route['title'] as String,
        transferCount: (route['transferCount'] as num).toInt(),
        isRecommended: route['isRecommended'] as bool? ?? false,
        totalDurationMinutes:
            (route['totalDurationMinutes'] as num?)?.toInt(),
        segments: segments,
      );
    }).toList();
  }

  RouteSegmentType _parseSegmentType(String type) {
    switch (type.toLowerCase()) {
      case 'walking':
        return RouteSegmentType.walking;
      case 'bus':
        return RouteSegmentType.bus;
      case 'subway':
        return RouteSegmentType.subway;
      case 'waiting':
        return RouteSegmentType.waiting;
      default:
        throw FormatException('지원하지 않는 이동 수단: $type');
    }
  }

  List<RouteCandidate> _mockRoutes() {
    return const [
      RouteCandidate(
        id: 'route_1',
        title: '도보 + 버스',
        transferCount: 0,
        isRecommended: true,
        segments: [
          RouteSegment(
            type: RouteSegmentType.walking,
            description: '출발지 → 버스 정류장',
            durationMinutes: 8,
          ),
          RouteSegment(
            type: RouteSegmentType.waiting,
            description: '버스 대기',
            durationMinutes: 4,
          ),
          RouteSegment(
            type: RouteSegmentType.bus,
            description: '버스 탑승',
            durationMinutes: 25,
          ),
          RouteSegment(
            type: RouteSegmentType.walking,
            description: '버스 정류장 → 목적지',
            durationMinutes: 5,
          ),
        ],
      ),
      RouteCandidate(
        id: 'route_2',
        title: '도보 + 지하철',
        transferCount: 0,
        segments: [
          RouteSegment(
            type: RouteSegmentType.walking,
            description: '출발지 → 지하철역',
            durationMinutes: 12,
          ),
          RouteSegment(
            type: RouteSegmentType.waiting,
            description: '지하철 대기',
            durationMinutes: 5,
          ),
          RouteSegment(
            type: RouteSegmentType.subway,
            description: '지하철 탑승',
            durationMinutes: 22,
          ),
          RouteSegment(
            type: RouteSegmentType.walking,
            description: '지하철역 → 목적지',
            durationMinutes: 7,
          ),
        ],
      ),
      RouteCandidate(
        id: 'route_3',
        title: '도보 + 버스 + 지하철',
        transferCount: 1,
        segments: [
          RouteSegment(
            type: RouteSegmentType.walking,
            description: '출발지 → 버스 정류장',
            durationMinutes: 5,
          ),
          RouteSegment(
            type: RouteSegmentType.waiting,
            description: '버스 대기',
            durationMinutes: 3,
          ),
          RouteSegment(
            type: RouteSegmentType.bus,
            description: '버스 탑승',
            durationMinutes: 12,
          ),
          RouteSegment(
            type: RouteSegmentType.walking,
            description: '버스 정류장 → 지하철역',
            durationMinutes: 4,
          ),
          RouteSegment(
            type: RouteSegmentType.waiting,
            description: '지하철 대기',
            durationMinutes: 4,
          ),
          RouteSegment(
            type: RouteSegmentType.subway,
            description: '지하철 탑승',
            durationMinutes: 15,
          ),
          RouteSegment(
            type: RouteSegmentType.walking,
            description: '지하철역 → 목적지',
            durationMinutes: 4,
          ),
        ],
      ),
    ];
  }
}
