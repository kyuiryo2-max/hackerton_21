import 'package:flutter_test/flutter_test.dart';
import 'package:sync_ro_app/data/offline_demo_data.dart';
import 'package:sync_ro_app/models/departure_overview.dart';
import 'package:sync_ro_app/services/route_api_service.dart';
import 'package:sync_ro_app/services/server_plan_service.dart';

void main() {
  test('발표 시연은 실제 모드에서 받은 서울역 → 고려대학교 경로 3개를 보여 줘요', () {
    final routes = RouteApiService().demoRoutes();

    expect(routes, hasLength(3));
    // 실제 모드와 같은 변환(server_N)이라 이동 탭이 계획과 순위로 연결해요
    expect(routes.map((r) => r.id), ['server_1', 'server_2', 'server_3']);
    expect(routes.map((r) => r.title), [
      '1호선 (서울역 > 동묘앞)',
      '1호선 (서울역 > 신설동)',
      '4호선 (서울역 > 삼각지(전쟁기념관))',
    ]);
    expect(routes.first.segments.first.geometry, isNotEmpty);
  });

  test('오프라인 시연 계획은 11/22 9:20 도착이고 이어폰·다이소를 타기 전에 들러요', () {
    final context = OfflineDemoData.context;
    final schedule = context['schedule'] as Map;
    final destination = schedule['destination'] as Map;

    expect((context['location'] as Map)['name'], '서울역');
    expect(destination['name'], '고려대학교 서울캠퍼스');

    final plan = ServerPlan(OfflineDemoData.plan);
    final overview = DepartureOverview.fromPlan(plan, source: DepartureSource.offlineDemo);

    expect(overview.destination, '고려대학교 서울캠퍼스');
    expect(overview.boardStopName, '서울역');
    expect(overview.departure, DateTime.parse('2026-11-22T08:40:22+09:00'));
    expect(overview.arriveAt, DateTime.parse('2026-11-22T09:15:00+09:00'));
    // 시연 할 일 번호(1 이어폰, 3 다이소)와 같아야 할 일 탭·할 일 적용이 같은 할 일을 가리켜요
    expect(overview.tasks.map((t) => t.id).toSet(), {'1', '3'});
  });
}
