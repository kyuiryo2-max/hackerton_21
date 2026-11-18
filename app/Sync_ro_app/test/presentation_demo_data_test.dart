import 'package:flutter_test/flutter_test.dart';
import 'package:sync_ro_app/data/offline_demo_data.dart';
import 'package:sync_ro_app/models/departure_overview.dart';
import 'package:sync_ro_app/services/route_api_service.dart';
import 'package:sync_ro_app/services/server_plan_service.dart';

void main() {
  test('발표 시연은 서울역에서 고려대학교로 가는 세 가지 경로를 보여 줘요', () {
    final routes = RouteApiService().demoRoutes();

    expect(routes, hasLength(3));
    expect(routes.map((r) => r.title), [
      '1호선 → 6호선',
      '4호선 → 6호선',
      '273번 버스',
    ]);
    expect(routes.first.isRecommended, isTrue);
    expect(routes.first.segments.first.startName, '서울역');
    expect(routes.first.segments.last.endName, '고려대학교');
    expect(routes.first.segments.first.geometry, isNotEmpty);
  });

  test('오프라인 시연 계획의 출발·도착과 탑승 정류장이 새 경로와 맞아요', () {
    final context = OfflineDemoData.context;
    final schedule = context['schedule'] as Map;
    final destination = schedule['destination'] as Map;

    expect((context['location'] as Map)['name'], '서울역');
    expect(destination['name'], '고려대학교');

    final overview = DepartureOverview.fromPlan(
      ServerPlan(OfflineDemoData.plan),
      source: DepartureSource.offlineDemo,
    );

    expect(overview.title, '고려대학교 가기');
    expect(overview.destination, '고려대학교');
    expect(overview.boardStopName, '서울역');
    expect(overview.routeName, '1호선 → 6호선');
    expect(overview.departure, DateTime.parse('2026-11-21T08:36:00+09:00'));
    expect(overview.arriveAt, DateTime.parse('2026-11-21T09:12:00+09:00'));
  });
}
