import 'dart:convert';

import 'package:latlong2/latlong.dart';

import 'demo_plan_fixture.dart';
import 'demo_route_options.dart';

/// 발표 시연 전용 경로: 서울역 → 고려대학교.
///
/// 실제 카카오 경로 샘플 대신 노선별 대표 역 좌표를 직선으로 연결한
/// 데모 폴리라인입니다. 지도에서 이동 궤적을 보여 주는 용도이며,
/// 실제 운행 정보가 아닙니다.
class PresentationRoutes {
  static final routes = <DemoRouteOption>[
    DemoRouteOption('1호선 → 6호선', 2400, 1550, 1, [
      DemoRouteLeg('SUBWAY', '1호선 (서울역 > 동묘앞)', 780, [
        LatLng(37.5547, 126.9707),
        LatLng(37.5600, 126.9735),
        LatLng(37.5657, 126.9770),
        LatLng(37.5680, 126.9800),
        LatLng(37.5700, 126.9830),
        LatLng(37.5702, 126.9870),
        LatLng(37.5704, 126.9910),
        LatLng(37.5707, 126.9960),
        LatLng(37.5709, 127.0010),
        LatLng(37.5711, 127.0050),
        LatLng(37.5714, 127.0095),
        LatLng(37.5724, 127.0130),
        LatLng(37.5735, 127.0165),
      ]),
      DemoRouteLeg('WALKING', '동묘앞역 환승', 180, [
        LatLng(37.5735, 127.0165),
        LatLng(37.5736, 127.0167),
      ]),
      DemoRouteLeg('SUBWAY', '6호선 (동묘앞 > 고려대(종암))', 720, [
        LatLng(37.5735, 127.0165),
        LatLng(37.5765, 127.0160),
        LatLng(37.5795, 127.0155),
        LatLng(37.5820, 127.0140),
        LatLng(37.5850, 127.0130),
        LatLng(37.5857, 127.0210),
        LatLng(37.5863, 127.0292),
        LatLng(37.5878, 127.0325),
        LatLng(37.5906, 127.0363),
      ]),
      DemoRouteLeg('WALKING', '고려대(종암)역 > 고려대학교', 180, [
        LatLng(37.5906, 127.0363),
        LatLng(37.5896, 127.0341),
        LatLng(37.5887, 127.0320),
      ]),
    ]),
    DemoRouteOption('4호선 → 6호선', 2580, 1550, 1, [
      DemoRouteLeg('SUBWAY', '4호선 (서울역 > 삼각지)', 180, [
        LatLng(37.5547, 126.9707),
        LatLng(37.5450, 126.9718),
        LatLng(37.5350, 126.9730),
      ]),
      DemoRouteLeg('WALKING', '삼각지역 환승', 180, [
        LatLng(37.5350, 126.9730),
        LatLng(37.5352, 126.9732),
      ]),
      DemoRouteLeg('SUBWAY', '6호선 (삼각지 > 고려대(종암))', 1440, [
        LatLng(37.5350, 126.9730),
        LatLng(37.5347, 126.9865),
        LatLng(37.5345, 126.9945),
        LatLng(37.5395, 127.0015),
        LatLng(37.5400, 127.0070),
        LatLng(37.5540, 127.0100),
        LatLng(37.5600, 127.0130),
        LatLng(37.5655, 127.0160),
        LatLng(37.5735, 127.0165),
        LatLng(37.5765, 127.0160),
        LatLng(37.5795, 127.0155),
        LatLng(37.5820, 127.0140),
        LatLng(37.5850, 127.0130),
        LatLng(37.5857, 127.0210),
        LatLng(37.5863, 127.0292),
        LatLng(37.5878, 127.0325),
        LatLng(37.5906, 127.0363),
      ]),
      DemoRouteLeg('WALKING', '고려대(종암)역 > 고려대학교', 180, [
        LatLng(37.5906, 127.0363),
        LatLng(37.5896, 127.0341),
        LatLng(37.5887, 127.0320),
      ]),
    ]),
    DemoRouteOption('173번 버스', 2700, 1500, 0, [
      DemoRouteLeg('BUS', '간선 173 (서울역버스환승센터 > 고려대학교앞)', 2220, [
        LatLng(37.5547, 126.9707),
        LatLng(37.5590, 126.9770),
        LatLng(37.5635, 126.9820),
        LatLng(37.5660, 126.9860),
        LatLng(37.5695, 126.9875),
        LatLng(37.5704, 126.9910),
        LatLng(37.5707, 126.9960),
        LatLng(37.5709, 127.0010),
        LatLng(37.5714, 127.0095),
        LatLng(37.5735, 127.0165),
        LatLng(37.5750, 127.0200),
        LatLng(37.5780, 127.0300),
        LatLng(37.5880, 127.0330),
      ]),
      DemoRouteLeg('WALKING', '고려대학교앞 > 고려대학교', 180, [
        LatLng(37.5880, 127.0330),
        LatLng(37.5887, 127.0320),
      ]),
    ]),
  ];
}

/// 시연 화면이 쓰는 고정 계획. 실제 조회 결과가 아니라 발표용 스냅샷입니다.
class PresentationDemoData {
  static const String nowIso = '2026-11-22T08:00:00+09:00';
  static const String arriveByIso = '2026-11-22T09:20:00+09:00';

  static Map<String, dynamic> _copy(dynamic source) =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(source)) as Map);

  static final Map<String, dynamic> _context = {
    'now': nowIso,
    'location': {
      'name': '서울역',
      'lng': 126.9716234,
      'lat': 37.55489578,
    },
    'schedule': {
      'destination': {
        'name': '고려대학교 서울캠퍼스',
        'lng': 127.03231892661324,
        'lat': 37.589526761187834,
      },
      'arrive_by': arriveByIso,
      'prep_minutes': 15,
    },
    'stop': {
      'ars_id': '02006',
      'station_id': '0150',
      'name': '서울역',
    },
    'route': {
      'type': 'SUBWAY',
      'name': '1호선·6호선',
      'guidance': '1호선 (서울역 > 동묘앞) → 6호선 (동묘앞 > 고려대(종암))',
      'moving_seconds': 1680,
      'last_walk_seconds': 180,
      'transfers': 1,
      'fare_min': 1550,
      'fare_max': 1550,
      'stops': ['서울역', '동묘앞', '고려대(종암)'],
      'times': {
        'depart_offset_seconds': 0,
        'board_offset_seconds': 540,
        'arrive_offset_seconds': 2400,
      },
      'path': [
        [126.9707, 37.5547], [126.9735, 37.56], [126.977, 37.5657], [126.98, 37.568], [126.983, 37.57],
        [126.987, 37.5702], [126.991, 37.5704], [126.996, 37.5707], [127.001, 37.5709], [127.005, 37.5711],
        [127.0095, 37.5714], [127.013, 37.5724], [127.0165, 37.5735], [127.016, 37.5765], [127.0155, 37.5795],
        [127.014, 37.582], [127.013, 37.585], [127.021, 37.5857], [127.0292, 37.5863], [127.0325, 37.5878],
        [127.0363, 37.5906], [127.0341, 37.5896], [127.032, 37.5887],
      ],
      'stop_points': [
        {'name': '서울역', 'lng': 126.9707, 'lat': 37.5547, 'source': 'seoul_subway'},
        {'name': '동묘앞', 'lng': 127.0165, 'lat': 37.5735, 'source': 'seoul_subway'},
        {'name': '고려대(종암)', 'lng': 127.0363, 'lat': 37.5906, 'source': 'seoul_subway'},
      ],
    },
  };

  static Map<String, dynamic> get context => _copy(_context);
  /// 경로·할 일 계획은 실제 모드에서 받은 응답을 그대로 써요 (11/21, [DemoPlanFixture]).
  static Map<String, dynamic> get plan => DemoPlanFixture.plan;
}
