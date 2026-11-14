import 'package:flutter_test/flutter_test.dart';
import 'package:sync_ro_app/models/trip_progress.dart';

/// 11/14: 버스 → 1호선처럼 갈아타는 경로에서, 버스를 탄 뒤 "내렸어요"를 누르면
/// 목적지 도착이 아니라 1호선 환승 단계로 가야 해요.
void main() {
  DateTime at(int h, int m) => DateTime(2026, 11, 15, h, m);

  TripPlan busThenSubway() => TripPlan(
        depart: at(13, 0),
        reachStop: at(13, 5),
        boardAt: at(13, 8),
        arriveAt: at(13, 55),
        stopName: '신촌오거리',
        rideName: '273번',
        destination: '시청',
        transfers: [
          TripTransfer(
            getOffAt: at(13, 25),
            getOffName: '종로3가',
            rideName: '1호선',
            stopName: '종로3가역',
            reachStop: at(13, 30),
            boardAt: at(13, 33),
          ),
        ],
      );

  test('갈아타는 경로는 버스 → 환승 걷기 → 기다림 → 1호선 → 도착 순서예요', () {
    final plan = busThenSubway();
    final phases = [for (final s in plan.steps) '${s.phase.name}:${s.leg}'];
    expect(phases, [
      'toStop:0',
      'waiting:0',
      'riding:0',
      'toStop:1',
      'waiting:1',
      'riding:1',
      'arrived:0',
    ]);
  });

  test('버스 타는 중 다음 단계는 도착이 아니라 환승이에요', () {
    final plan = busThenSubway();
    final busRiding = plan.steps.indexWhere((s) => s.phase == TripPhase.riding && s.leg == 0);
    expect(plan.steps[busRiding + 1].phase, TripPhase.toStop);
    expect(plan.steps[busRiding + 1].leg, 1);
    expect(plan.isLastLeg(0), isFalse);
    expect(plan.alightOf(0), at(13, 25));
  });

  test('시간 기준 단계도 환승 시각에 맞춰 넘어가요', () {
    final plan = busThenSubway();
    expect(plan.steps[plan.indexAt(at(13, 20))].phase, TripPhase.riding);
    expect(plan.steps[plan.indexAt(at(13, 27))].phase, TripPhase.toStop);
    expect(plan.steps[plan.indexAt(at(13, 31))].phase, TripPhase.waiting);
    expect(plan.steps[plan.indexAt(at(13, 40))].leg, 1);
    expect(plan.steps[plan.indexAt(at(13, 56))].phase, TripPhase.arrived);
  });

  test('환승 중 AI 질문에는 지금 탈 차(1호선) 정보를 보내요', () {
    final plan = busThenSubway();
    final json = plan.toAskJson(TripPhase.waiting, at(13, 31), 1);
    expect(json['ride_name'], '1호선');
    expect(json['stop_name'], '종로3가역');
    expect(json['next_vehicles_min'], isEmpty);
  });

  test('한 번에 가는 경로는 예전과 같아요', () {
    final plan = TripPlan(
      depart: at(13, 0),
      reachStop: at(13, 5),
      boardAt: at(13, 8),
      arriveAt: at(13, 40),
      stopName: '신촌오거리',
      rideName: '2115번',
      destination: '을지로입구',
    );
    expect([for (final s in plan.steps) s.phase],
        [TripPhase.toStop, TripPhase.waiting, TripPhase.riding, TripPhase.arrived]);
    expect(plan.isLastLeg(0), isTrue);
  });
}
