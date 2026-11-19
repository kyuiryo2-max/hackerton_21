import 'dart:convert';

import 'package:latlong2/latlong.dart';

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
  static const String nowIso = '2026-11-21T08:32:00+09:00';
  static const String arriveByIso = '2026-11-21T09:20:00+09:00';

  static Map<String, dynamic> _copy(dynamic source) =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(source)) as Map);

  static final Map<String, dynamic> _context = {
    'now': nowIso,
    'location': {
      'name': '서울역',
      'lng': 126.9707,
      'lat': 37.5547,
    },
    'schedule': {
      'destination': {
        'name': '고려대학교',
        'lng': 127.0320,
        'lat': 37.5887,
      },
      'arrive_by': arriveByIso,
      'prep_minutes': 30,
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

  static final Map<String, dynamic> _plan = {
    'now': nowIso,
    'origin': {
      'name': '서울역',
      'lng': 126.9707,
      'lat': 37.5547,
    },
    'basis': 'realtime',
    'schedule': {
      'destination': {
        'name': '고려대학교',
        'lng': 127.0320,
        'lat': 37.5887,
      },
      'arrive_by': arriveByIso,
      'prep_minutes': 30,
    },
    'depart_at': '2026-11-21T08:32:00+09:00',
    'board_at': '2026-11-21T08:41:00+09:00',
    'arrive_at': '2026-11-21T09:12:00+09:00',
    'routes': [
      _route(
        rank: 1,
        type: 'SUBWAY',
        name: '1호선·6호선',
        guidance: '1호선 (서울역 > 동묘앞) → 6호선 (동묘앞 > 고려대(종암))',
        totalMin: 40,
        waitMin: 9,
        movingMin: 28,
        lastWalkMin: 3,
        transfers: 1,
        fare: 1550,
        stops: ['서울역', '동묘앞', '고려대(종암)'],
        maxStayMin: 4,
        rideName: '1호선·6호선',
        nextVehiclesMin: [9, 18],
        boardInMin: 9,
        departAt: '2026-11-21T08:32:00+09:00',
        boardAt: '2026-11-21T08:41:00+09:00',
        arriveAt: '2026-11-21T09:12:00+09:00',
      ),
      _route(
        rank: 2,
        type: 'SUBWAY',
        name: '4호선·6호선',
        guidance: '4호선 (서울역 > 삼각지) → 6호선 (삼각지 > 고려대(종암))',
        totalMin: 43,
        waitMin: 10,
        movingMin: 30,
        lastWalkMin: 3,
        transfers: 1,
        fare: 1550,
        stops: ['서울역', '삼각지', '고려대(종암)'],
        maxStayMin: 5,
        rideName: '4호선·6호선',
        nextVehiclesMin: [10, 19],
        boardInMin: 10,
        departAt: '2026-11-21T08:33:00+09:00',
        boardAt: '2026-11-21T08:42:00+09:00',
        arriveAt: '2026-11-21T09:15:00+09:00',
      ),
      _route(
        rank: 3,
        type: 'BUS',
        name: '173',
        guidance: '간선 173 (서울역버스환승센터 > 고려대학교앞)',
        totalMin: 45,
        waitMin: 5,
        movingMin: 37,
        lastWalkMin: 3,
        transfers: 0,
        fare: 1500,
        stops: ['서울역버스환승센터', '종로2가', '동묘앞', '고려대학교앞'],
        maxStayMin: 3,
        rideName: '173번',
        nextVehiclesMin: [5, 13],
        boardInMin: 5,
        departAt: '2026-11-21T08:35:00+09:00',
        boardAt: '2026-11-21T08:37:00+09:00',
        arriveAt: '2026-11-21T09:17:00+09:00',
      ),
    ],
    'todos': [
      {
        'todo_id': 1,
        'stay_min': 4,
        'text': '이어폰 사기',
        'importance': '필수',
        'status': '포함',
        'place': {
          'place_type': '편의점',
          'name': 'GS25 S서울역1호점',
          'address': '서울 용산구 청파로 378 1층',
          'lng': 126.96963409,
          'lat': 37.55356136,
        },
        'detour_min': 2,
        'reason': '',
        'candidates': [
          {
            'place_type': '편의점',
            'name': 'GS25 S서울역1호점',
            'address': '서울 용산구 청파로 378 1층',
            'lng': 126.96963409,
            'lat': 37.55356136,
            'detour_min': 2,
          },
        ],
      },
      {
        'todo_id': 3,
        'stay_min': 5,
        'text': '다이소 들르기',
        'importance': '필수',
        'status': '대기',
        'place': {
          'place_type': '다이소',
          'name': '다이소 서울역점',
          'address': '서울 용산구 청파로 378 1층',
          'lng': 126.9720059,
          'lat': 37.55420345,
        },
        'detour_min': 6,
        'reason': '시간이 부족해요',
        'options': ['이번엔 빼기', '늦더라도 들르기'],
        'candidates': [
          {
            'place_type': '다이소',
            'name': '다이소 서울역점',
            'address': '서울 용산구 청파로 378 1층',
            'lng': 126.9720059,
            'lat': 37.55420345,
            'detour_min': 6,
          },
        ],
      },
      {
        'todo_id': 2,
        'stay_min': 5,
        'text': '커피 사기',
        'importance': '선택',
        'status': '제외',
        'place': {
          'place_type': '카페',
          'name': '스타벅스 서울역사점',
          'address': '서울 용산구 청파로 378 2층 101호',
          'lng': 126.97202401,
          'lat': 37.55421427,
        },
        'detour_min': 4,
        'reason': '시간이 부족해요',
        'candidates': [
          {
            'place_type': '카페',
            'name': '스타벅스 서울역사점',
            'address': '서울 용산구 청파로 378 2층 101호',
            'lng': 126.97202401,
            'lat': 37.55421427,
            'detour_min': 4,
          },
        ],
      },
    ],
    'explanation': '1호선·6호선을 타면 이어폰 사기까지 하고 9시 12분에 도착해요.',
  };

  static Map<String, dynamic> _route({
    required int rank,
    required String type,
    required String name,
    required String guidance,
    required int totalMin,
    required int waitMin,
    required int movingMin,
    required int lastWalkMin,
    required int transfers,
    required int fare,
    required List<String> stops,
    required int maxStayMin,
    required String rideName,
    required List<int> nextVehiclesMin,
    required int boardInMin,
    required String departAt,
    required String boardAt,
    required String arriveAt,
  }) {
    return {
      'rank': rank,
      'type': type,
      'name': name,
      'guidance': guidance,
      'basis': 'realtime',
      'total_min': totalMin,
      'first_walk_min': 0,
      'wait_min': waitMin,
      'moving_min': movingMin,
      'last_walk_min': lastWalkMin,
      'transfers': transfers,
      'fare': fare,
      'stops': stops,
      'max_stay_min': maxStayMin,
      'has_realtime': true,
      'ride_name': rideName,
      'next_vehicles_min': nextVehiclesMin,
      'board_in_min': boardInMin,
      'depart_at': departAt,
      'board_at': boardAt,
      'arrive_at': arriveAt,
    };
  }

  static Map<String, dynamic> get context => _copy(_context);
  static Map<String, dynamic> get plan => _copy(_plan);
}
