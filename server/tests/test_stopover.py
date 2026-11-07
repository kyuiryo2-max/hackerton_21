"""경유·체류 계산 테스트 (할 일 28·29번). 외부 호출이 없어요."""
import pytest

from app.services.stopover import (
    DEFAULT_BUFFER_SECONDS,
    SUBWAY_MARGIN_SECONDS,
    RouteTiming,
    StopCandidate,
    decide_stops,
    max_stay_seconds,
    pick_board_seconds,
    total_seconds,
)
from app.services.timecalc import route_total_seconds, travel_minutes_from_seconds


def route(vehicles=(720, 1200), **kwargs) -> RouteTiming:
    base = {"moving_seconds": 800, "first_walk_seconds": 120, "last_walk_seconds": 120}
    return RouteTiming(vehicle_seconds=list(vehicles), **{**base, **kwargs})


def stop(todo_id=1, importance="필수", detour=120, stay=240) -> StopCandidate:
    return StopCandidate(todo_id, importance, detour, stay)


def statuses(result) -> dict:
    return {d.todo_id: d.status for d in result.decisions}


# ---------- 차 고르기와 체류 시간 ----------
def test_여유를_두고_탈_수_있는_가장_빠른_차():
    assert pick_board_seconds([300, 720], ready_seconds=120, buffer=120) == 300


def test_여유가_모자라면_다음_차():
    assert pick_board_seconds([230, 720], ready_seconds=120, buffer=120) == 720


def test_딱_맞으면_탈_수_있음():
    assert pick_board_seconds([240], ready_seconds=120, buffer=120) == 240


def test_탈_수_있는_차가_없으면_None():
    assert pick_board_seconds([100], ready_seconds=120, buffer=120) is None


def test_최대_체류_시간():
    # 버스까지 12분, 경유 도보 6분, 여유 2분 → 4분
    assert max_stay_seconds(720, 360, 120) == 240


def test_시간이_부족하면_체류_0():
    assert max_stay_seconds(300, 360, 120) == 0


def test_왕복을_한_번만_올림():
    # 편도 94초를 올려 두 배 하면 4분, 왕복 179초를 올리면 3분
    assert travel_minutes_from_seconds(94) * 2 == 4
    assert travel_minutes_from_seconds(179) == 3


# ---------- 총 시간 ----------
def test_총_시간은_구간_앞뒤_도보_대기의_합():
    r = route(vehicles=[720])
    total, board = total_seconds(r, r.first_walk_seconds, DEFAULT_BUFFER_SECONDS)
    assert board == 720
    assert total == route_total_seconds(800, 120, 120, 720 - 120)


def test_실시간_정보가_없으면_대기_0():
    r = route(vehicles=[])
    assert total_seconds(r, 120, DEFAULT_BUFFER_SECONDS) == (1040, None)


def test_탈_차가_없으면_None():
    assert total_seconds(route(vehicles=[100]), 120, DEFAULT_BUFFER_SECONDS) is None


# ---------- 경유 판단 ----------
def test_같은_차를_타면서_들를_수_있음():
    result = decide_stops(route(), [stop()], deadline_seconds=3600)
    assert statuses(result) == {1: "included"}
    assert result.board_seconds == 720
    assert result.total_seconds == result.direct_total_seconds


def test_경유_후_늘어난_시간은_다음_차_기준():
    result = decide_stops(route(), [stop(stay=400)], deadline_seconds=3600)
    assert result.board_seconds == 1200
    assert result.total_seconds - result.direct_total_seconds == 480


def test_경유_체류_시간은_탈_차_기준():
    result = decide_stops(route(), [stop()], deadline_seconds=3600)
    # 720 − (120 + 120) − 120 = 360초 쓸 수 있고 240초 머물러도 돼요
    assert result.max_stay_seconds == 360


def test_시간이_부족한_선택_할_일은_제외():
    result = decide_stops(route(vehicles=[720]), [stop(importance="선택", stay=600)], deadline_seconds=3600)
    assert statuses(result) == {1: "excluded"}
    assert result.board_seconds == 720


def test_시간이_부족한_필수_할_일은_물어봄():
    result = decide_stops(route(vehicles=[720]), [stop(stay=600)], deadline_seconds=3600)
    assert statuses(result) == {1: "ask"}
    assert result.decisions[0].reason


def test_도착_희망_시각을_넘기면_제외():
    # 다음 차로는 갈 수 있지만 1200 + 920 = 2120초라 마감을 넘겨요
    result = decide_stops(route(), [stop(importance="선택", stay=400)], deadline_seconds=2000)
    assert statuses(result) == {1: "excluded"}


def test_딱_마감에_도착하면_포함():
    result = decide_stops(route(), [stop(importance="선택", stay=400)], deadline_seconds=2120)
    assert statuses(result) == {1: "included"}


def test_필수를_먼저_넣음():
    stops = [stop(1, "선택", 120, 240), stop(2, "필수", 120, 240)]
    result = decide_stops(route(vehicles=[720]), stops, deadline_seconds=3600)
    assert statuses(result) == {2: "included", 1: "excluded"}


def test_여러_경유지는_시간을_더해_판단():
    stops = [stop(1, "필수", 60, 120), stop(2, "선택", 60, 120)]
    result = decide_stops(route(vehicles=[720]), stops, deadline_seconds=3600)
    assert statuses(result) == {1: "included", 2: "included"}


def test_할_일이_없으면_경유_없음():
    result = decide_stops(route(), [], deadline_seconds=3600)
    assert result.decisions == []
    assert result.total_seconds == result.direct_total_seconds


def test_지하철은_1분_여유를_더함():
    r = route(vehicles=[280], is_subway=True)
    ready = r.first_walk_seconds
    assert pick_board_seconds(r.vehicle_seconds, ready, DEFAULT_BUFFER_SECONDS) == 280
    assert pick_board_seconds(r.vehicle_seconds, ready, DEFAULT_BUFFER_SECONDS + SUBWAY_MARGIN_SECONDS) is None
    assert decide_stops(r, [], 3600).board_seconds is None


def test_실시간_정보가_없어도_경유_판단():
    result = decide_stops(route(vehicles=[]), [stop()], deadline_seconds=3600)
    assert statuses(result) == {1: "included"}
    assert result.has_realtime is False
    assert result.max_stay_seconds is None
    assert result.total_seconds == 1040 + 360


def test_탈_차가_없으면_경유_미포함_시간으로_표시():
    result = decide_stops(route(vehicles=[100]), [stop(importance="선택")], deadline_seconds=3600)
    assert statuses(result) == {1: "excluded"}
    assert result.board_seconds is None
    assert result.total_seconds == 1040


def test_음수는_오류():
    with pytest.raises(ValueError):
        decide_stops(route(), [stop(stay=-1)], deadline_seconds=3600)
