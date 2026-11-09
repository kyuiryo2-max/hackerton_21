import 'dart:convert';
import 'kakao_route_parser.dart';
import '../data/demo_route_options.dart';
import '../data/demo_route_style.dart';
import 'package:http/http.dart' as http;

import '../config/route_api_config.dart';
import '../config/api_config.dart';
import '../models/route_candidate.dart';
import '../models/route_request.dart';

class RouteApiService {
  Future<List<RouteCandidate>> searchRoutes(RouteRequest request) async {
    if (ApiConfig.offlineDemo || !RouteApiConfig.useRealApi) {
      if (_isBundledDemoPair(request)) return _bundledDemoRoutes();
      throw StateError('현재 오프라인 시연 모드입니다. 임의의 출발지·목적지는 실제 경로를 조회할 수 없습니다. '
          '시연 경로(안암역3번출구 → 청량리역)를 이용하거나, 서버 복구 후 '
          'SYNC_RO_OFFLINE_DEMO=false 및 SYNC_RO_USE_REAL_API=true로 실행해 주세요.');
    }

    return _fetchRoutes(request);
  }

  bool _isBundledDemoPair(RouteRequest r) {
    final from = r.origin.replaceAll(' ', '');
    final to = r.destination.replaceAll(' ', '');
    return (from.contains('안암역') || from.contains('안암')) &&
        (to.contains('청량리역') || to.contains('청량리'));
  }

  List<RouteCandidate> _bundledDemoRoutes() {
    return [
      for (var i = 0; i < DemoRouteOptions.routes.length; i++)
        RouteCandidate(
          id: 'offline_demo_${i + 1}',
          title: DemoRouteOptions.routes[i].label,
          transferCount: DemoRouteOptions.routes[i].transfers,
          isRecommended: i == 0,
          totalDurationMinutes: (DemoRouteOptions.routes[i].durationSeconds / 60).ceil(),
          segments: [
            for (final leg in DemoRouteOptions.routes[i].legs)
              RouteSegment(
                type: switch (leg.mode) {
                  'BUS' => RouteSegmentType.bus,
                  'SUBWAY' => RouteSegmentType.subway,
                  _ => RouteSegmentType.walking,
                },
                description: leg.label,
                lineName: leg.mode == 'WALKING' ? '도보 환승' : leg.label.split(' (').first,
                startName: DemoRouteStyle.endpoints(leg).$1,
                endName: DemoRouteStyle.endpoints(leg).$2,
                durationMinutes: (leg.seconds / 60).ceil(),
                geometry: [
                  for (final p in leg.path)
                    RoutePoint(latitude: p.latitude, longitude: p.longitude),
                ],
              ),
          ],
        ),
    ];
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

    final uri = ApiConfig.endpoint('/api/routes/search');

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
          description: segment['description']?.toString() ?? '',
          lineName: (segment['lineName'] ?? segment['routeName'] ?? segment['line'])?.toString(),
          startName: (segment['startName'] ?? segment['fromName'])?.toString(),
          endName: (segment['endName'] ?? segment['toName'])?.toString(),
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

}
