import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:sync_ro_app/data/offline_demo_data.dart';
import 'package:sync_ro_app/providers/todo_controller.dart';
import 'package:sync_ro_app/services/route_api_service.dart';
import 'package:sync_ro_app/services/server_plan_service.dart';
import 'package:sync_ro_app/widgets/move_route_planner.dart';
import 'package:sync_ro_app/widgets/route_compare_map.dart';

void main() {
  testWidgets('시연 경로를 시작하면 발표 모드 재생 컨트롤이 보여요', (tester) async {
    final routes = RouteApiService().demoRoutes();
    final context = OfflineDemoData.context;
    final schedule = context['schedule'] as Map;
    final location = context['location'] as Map;
    final destination = schedule['destination'] as Map;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TodoScope(
            controller: TodoController(),
            child: SingleChildScrollView(
              child: MoveRoutePlanner(
                routes: routes,
                selectedId: routes.first.id,
                onSelect: (_) {},
                plan: ServerPlan(OfflineDemoData.plan),
                title: '고려대학교 가기',
                badge: '시연',
                originName: '${location['name']}',
                destinationName: '${destination['name']}',
                arriveBy: DateTime.tryParse('${schedule['arrive_by']}'),
                now: DateTime.tryParse('${context['now']}')!,
                isDemo: true,
                origin: LatLng(
                  (location['lat'] as num).toDouble(),
                  (location['lng'] as num).toDouble(),
                ),
                destination: LatLng(
                  (destination['lat'] as num).toDouble(),
                  (destination['lng'] as num).toDouble(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final start = find.text('이 경로로 이동 시작');
    await tester.ensureVisible(start);
    await tester.tap(start);
    await tester.pump();

    expect(find.text('발표 모드 · 경로를 따라 자동 이동'), findsOneWidget);

    final play = find.byTooltip('발표 모드 재생');
    await tester.ensureVisible(play);
    await tester.tap(play);
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('발표 모드 · GPS 시뮬레이션 중'), findsOneWidget);

    final before = tester.widget<RouteCompareMap>(
      find.byType(RouteCompareMap),
    ).liveDot;
    expect(before, isNotNull);

    await tester.pump(const Duration(seconds: 2));
    final after = tester.widget<RouteCompareMap>(
      find.byType(RouteCompareMap),
    ).liveDot;
    expect(after, isNot(equals(before)));
  });
}
