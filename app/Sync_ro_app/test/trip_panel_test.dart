import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_ro_app/models/route_candidate.dart';
import 'package:sync_ro_app/models/trip_progress.dart';
import 'package:sync_ro_app/widgets/route_compare_map.dart';
import 'package:sync_ro_app/widgets/trip_panel.dart';

void main() {
  testWidgets('이동 타임라인은 경로 띠만 보여 주고 현재 위치 세로선은 없어요', (tester) async {
    final now = DateTime(2026, 11, 16, 13, 10);
    final plan = TripPlan(
      depart: DateTime(2026, 11, 16, 13, 0),
      reachStop: DateTime(2026, 11, 16, 13, 5),
      boardAt: DateTime(2026, 11, 16, 13, 8),
      arriveAt: DateTime(2026, 11, 16, 13, 40),
      stopName: '신촌오거리',
      rideName: '2115번',
      destination: '을지로입구',
    );
    const route = RouteCandidate(
      id: 'test-route',
      title: '2115번',
      transferCount: 0,
      segments: [
        RouteSegment(
          type: RouteSegmentType.walking,
          description: '정류장까지 걷기',
          durationMinutes: 5,
        ),
        RouteSegment(
          type: RouteSegmentType.bus,
          description: '2115번',
          durationMinutes: 35,
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TripPanel(
            plan: plan,
            now: now,
            index: plan.indexAt(now),
            stripRoute: route,
            onAdvance: () {},
            onAsk: (_) async => const TripAskReply(''),
            onEnd: () {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(RouteTimeStrip), findsOneWidget);
    final threePxLine = find.byWidgetPredicate((widget) {
      if (widget is! Container) return false;
      final constraints = widget.constraints;
      return constraints != null &&
          constraints.minWidth == 3 &&
          constraints.maxWidth == 3;
    });
    expect(threePxLine, findsNothing);
  });

  testWidgets('시연 모드에서는 발표 모드 재생·배속·처음으로 컨트롤을 보여 줘요', (tester) async {
    final now = DateTime(2026, 11, 16, 13, 10);
    final plan = TripPlan(
      depart: DateTime(2026, 11, 16, 13, 0),
      reachStop: DateTime(2026, 11, 16, 13, 5),
      boardAt: DateTime(2026, 11, 16, 13, 8),
      arriveAt: DateTime(2026, 11, 16, 13, 40),
      stopName: '신촌오거리',
      rideName: '2115번',
      destination: '을지로입구',
    );
    const route = RouteCandidate(
      id: 'test-route',
      title: '2115번',
      transferCount: 0,
      segments: [
        RouteSegment(
          type: RouteSegmentType.walking,
          description: '정류장까지 걷기',
          durationMinutes: 5,
        ),
        RouteSegment(
          type: RouteSegmentType.bus,
          description: '2115번',
          durationMinutes: 35,
        ),
      ],
    );

    var toggled = 0;
    var speedChanged = 0;
    var reset = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TripPanel(
            plan: plan,
            now: now,
            index: plan.indexAt(now),
            stripRoute: route,
            onAdvance: () {},
            onAsk: (_) async => const TripAskReply(''),
            onEnd: () {},
            presentationAvailable: true,
            presentationSpeed: 4,
            onPresentationToggle: () => toggled++,
            onPresentationSpeed: () => speedChanged++,
            onPresentationReset: () => reset++,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('발표 모드 · 경로를 따라 자동 이동'), findsOneWidget);
    expect(find.text('4배속'), findsOneWidget);
    await tester.tap(find.byTooltip('발표 모드 재생'));
    await tester.tap(find.text('4배속'));
    await tester.tap(find.byTooltip('경로 처음으로'));
    expect(toggled, 1);
    expect(speedChanged, 1);
    expect(reset, 1);
  });
}
