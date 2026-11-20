import 'package:flutter_test/flutter_test.dart';
import 'package:sync_ro_app/models/departure_overview.dart';

/// 11/20: 실시간 기준 경로에서 머물 시간을 늘려 곧 오는 차를 놓치면 "머물 시간 N분으로 줄이기"만 떴어요.
/// 도착 희망 시각 안에 오는 다음 차(later_boards)가 있으면 그 차로 판정해요.
void main() {
  // _stayBase가 DateTime.now() 기준이라 지금 시각에서 상대로 잡아요 (분 내림 오차를 피하려고 30초 더해요)
  final now = DateTime.now();
  DateTime inMin(int m) => now.add(Duration(minutes: m, seconds: 30));

  const shop = StayCandidate(id: 'cu', name: 'CU', detourMinutes: 4, walkToMinutes: 2, walkBackMinutes: 2);

  DepartureOverview overview({
    DepartureSource source = DepartureSource.serverPlan,
    List<LaterBoard> later = const [],
  }) =>
      DepartureOverview(
        source: source,
        title: '청량리역 가기',
        destination: '청량리역',
        prepMinutes: 0,
        departure: inMin(5),
        boardAt: inMin(10), // 곧 오는 차: 10분 뒤
        arriveAt: inMin(40),
        arriveBy: inMin(70),
        spareMinutes: 4, // 실시간 기준이라 서버가 max_stay_min을 줘요
        laterBoards: later,
      );

  final next = LaterBoard(inMin(20), inMin(50)); // 다음 차: 20분 뒤 타고 50분 뒤 도착

  test('곧 오는 차로는 모자라도 다음 차를 타면 10분 머물 수 있어요', () {
    final e = overview(later: [next]).evaluate(shop, delayMinutes: 0, need: 10);
    expect(e.status, isNot(StayStatus.bad));
    expect(e.laterBoardAt, next.boardAt);
    expect(e.laterArriveAt, next.arriveAt);
    expect(e.missesVehicle, isFalse);
  });

  test('다음 차 목록이 없으면 예전처럼 시간이 부족해요', () {
    final e = overview().evaluate(shop, delayMinutes: 0, need: 10);
    expect(e.status, StayStatus.bad);
    expect(e.laterBoardAt, isNull);
  });

  test('곧 오는 차로 충분하면 다음 차를 쓰지 않아요', () {
    final e = overview(later: [next]).evaluate(shop, delayMinutes: 0, need: 2);
    expect(e.status, isNot(StayStatus.bad));
    expect(e.laterBoardAt, isNull);
  });

  test('시연 계획에는 적용하지 않아요', () {
    final e = overview(source: DepartureSource.serverDemo, later: [next]).evaluate(shop, delayMinutes: 0, need: 30);
    expect(e.laterBoardAt, isNull);
  });

  test('서버 later_boards를 시각 순서로 읽어요', () {
    final list = LaterBoard.parseList([
      {'board_at': '2026-11-21T09:20:00+09:00', 'arrive_at': '2026-11-21T09:50:00+09:00'},
      {'board_at': '2026-11-21T09:10:00+09:00', 'arrive_at': '2026-11-21T09:40:00+09:00'},
      {'board_at': 'x'},
    ]);
    expect(list.length, 2);
    expect(list.first.boardAt.isBefore(list.last.boardAt), isTrue);
  });
}
