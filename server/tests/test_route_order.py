"""실제 모드 경로 순서와 시간 (11/13).

할 일을 적용하기 전에는 할 일과 상관없이 빠른 경로부터, 경로 시간에도 경유 시간을 넣지 않아요.
"""
from types import SimpleNamespace

from app.services.planner import _without_stop_times, sort_options
from app.services.stopover import StopDecision, StopResult


def option(name: str, minutes: int, included: list[int]):
    decisions = [SimpleNamespace(todo_id=i, status="included") for i in included]
    return SimpleNamespace(name=name, result=SimpleNamespace(total_seconds=minutes * 60, decisions=decisions))


TODOS = [{"id": 1, "importance": "필수"}, {"id": 2, "importance": None}]


def names(options):
    return [o.name for o in options]


def test_fastest_route_first_even_if_another_route_can_do_todos():
    # 11/13 화면: 6호선 72분(할 일 들를 수 있음)이 2115번 41분보다 먼저 나오던 문제
    opts = [option("6호선", 72, [1, 2]), option("2115", 41, []), option("1222", 51, [])]
    sort_options(opts, TODOS)
    assert names(opts) == ["2115", "1222", "6호선"]


def test_no_todos_sorts_by_time():
    opts = [option("c", 50, []), option("a", 30, []), option("b", 40, [])]
    sort_options(opts, [])
    assert names(opts) == ["a", "b", "c"]


def test_route_time_does_not_include_unapplied_todo():
    # 11/13 화면: 할 일을 적용하지 않았는데 41분 경로가 104분으로 나오던 문제
    with_todos = StopResult(decisions=[StopDecision(1, "included")], board_seconds=None,
                            total_seconds=104 * 60, direct_total_seconds=41 * 60, max_stay_seconds=None,
                            has_realtime=False)
    direct = StopResult(decisions=[], board_seconds=None, total_seconds=41 * 60,
                        direct_total_seconds=41 * 60, max_stay_seconds=None, has_realtime=False)
    merged = _without_stop_times(with_todos, direct)
    assert merged.total_seconds == 41 * 60
    # 할 일 판정(포함/제외)은 그대로 남아서 앱이 "할 일 적용하기"에 써요
    assert [(d.todo_id, d.status) for d in merged.decisions] == [(1, "included")]


def test_realtime_board_and_stay_come_from_direct_route():
    with_todos = StopResult(decisions=[StopDecision(1, "included")], board_seconds=900,
                            total_seconds=2400, direct_total_seconds=1800, max_stay_seconds=60,
                            has_realtime=True)
    direct = StopResult(decisions=[], board_seconds=600, total_seconds=1800,
                        direct_total_seconds=1800, max_stay_seconds=300, has_realtime=True)
    merged = _without_stop_times(with_todos, direct)
    assert (merged.board_seconds, merged.total_seconds, merged.max_stay_seconds) == (600, 1800, 300)


def test_안내_문장_노선_이름():
    # 11/13: 지하철 경로에 "6호선번을 타면"이라고 나오던 문제
    from app.services.planner import _ride_name
    assert _ride_name({"type": "BUS", "name": "2115"}) == "2115번"
    assert _ride_name({"type": "BUS_AND_SUBWAY", "name": "성북04"}) == "성북04번"
    assert _ride_name({"type": "BUS", "name": "7720·7727"}) == "7720·7727번"
    assert _ride_name({"type": "SUBWAY", "name": "6호선"}) == "6호선"
    assert _ride_name({"type": "BUS_AND_SUBWAY", "name": "6호선"}) == "6호선"
    assert _ride_name({"type": "SUBWAY", "name": "GTX-A"}) == "GTX-A"
