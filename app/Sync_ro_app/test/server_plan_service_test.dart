import 'package:flutter_test/flutter_test.dart';
import 'package:sync_ro_app/services/server_plan_service.dart';

void main() {
  const route = <String, dynamic>{
    'type': 'BUS',
    'basis': 'now',
    'has_realtime': false,
    'next_vehicles_min': <int>[],
  };
  const plan = ServerPlan({
    'basis': 'now',
    'routes': [route],
  });

  test('낮에는 실시간 정보가 없어도 운행 중인 경로로 봐요', () {
    final noonKst = DateTime.utc(2026, 11, 21, 3); // 12:00 KST
    expect(plan.notRunning(route, now: noonKst), isFalse);
  });

  test('밤에 실시간 정보가 없으면 운행 종료로 봐요', () {
    final midnightKst = DateTime.utc(2026, 11, 21, 15); // 00:00 KST
    expect(plan.notRunning(route, now: midnightKst), isTrue);
  });

  test('예상 대기 경로는 낮에는 유지하고 밤에는 첫차 기준으로 다시 계산해요', () {
    final noonKst = DateTime.utc(2026, 11, 21, 3); // 12:00 KST
    final midnightKst = DateTime.utc(2026, 11, 21, 15); // 00:00 KST
    final estimated = <String, dynamic>{
      ...route,
      'wait_estimated': true,
    };
    expect(plan.notRunning(estimated, now: noonKst), isFalse);
    expect(plan.notRunning(estimated, now: midnightKst), isTrue);
  });
}
