import 'package:flutter_test/flutter_test.dart';
import 'package:sync_ro_app/models/departure_overview.dart';
import 'package:sync_ro_app/services/server_plan_service.dart';

void main() {
  test('장소 후보가 없는 할 일도 화면 모델에 남겨요', () {
    final plan = ServerPlan({
      'schedule': {
        'destination': {'name': '고려대학교', 'lng': 127.0, 'lat': 37.5},
        'prep_minutes': 0,
      },
      'basis': 'now',
      'routes': [
        {
          'rank': 1,
          'type': 'SUBWAY',
          'name': '1호선',
          'basis': 'now',
          'has_realtime': false,
          'next_vehicles_min': <int>[],
        },
      ],
      'todos': [
        {
          'todo_id': 1,
          'text': '엄마한테 전화',
          'importance': '필수',
          'status': '제외',
          'place': null,
          'candidates': <Map<String, dynamic>>[],
          'reason': '들를 장소 종류가 없어요. 할 일·일정 탭에서 장소를 골라 주세요.',
        },
      ],
      'depart_at': '2026-11-21T08:00:00+09:00',
      'board_at': '2026-11-21T08:10:00+09:00',
      'arrive_at': '2026-11-21T08:40:00+09:00',
    });

    final overview = DepartureOverview.fromPlan(plan, source: DepartureSource.serverPlan);

    expect(overview.tasks, hasLength(1));
    expect(overview.tasks.first.candidates, isEmpty);
    expect(overview.tasks.first.reason, contains('장소 종류'));
  });
}
