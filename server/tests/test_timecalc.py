from datetime import datetime

import pytest

from app.services.timecalc import (
    estimate_vehicle_times,
    max_stay_minutes,
    pick_vehicle,
    plan_by_vehicle,
    plan_departure,
    travel_minutes_from_seconds,
    wait_minutes_from_seconds,
)


def test_출발_준비_시각():
    plan = plan_departure(
        arrive_by=datetime(2026, 11, 21, 9, 0),
        travel_minutes=40,
        prep_minutes=30,
        buffer_minutes=5,
    )
    assert plan.depart_at == datetime(2026, 11, 21, 8, 15)
    assert plan.prep_start_at == datetime(2026, 11, 21, 7, 45)


def test_날짜를_넘어가는_경우():
    plan = plan_departure(
        arrive_by=datetime(2026, 11, 21, 0, 20),
        travel_minutes=30,
        prep_minutes=20,
        buffer_minutes=0,
    )
    assert plan.depart_at == datetime(2026, 11, 20, 23, 50)
    assert plan.prep_start_at == datetime(2026, 11, 20, 23, 30)


def test_음수_시간은_오류():
    with pytest.raises(ValueError):
        plan_departure(datetime(2026, 11, 21, 9, 0), -1, 30)


def test_최대로_쓸_수_있는_시간():
    # 버스까지 12분, 약국까지 3분, 돌아오는 데 3분, 여유 2분 → 4분
    assert max_stay_minutes(12, 3, 3, buffer_minutes=2) == 4


def test_시간이_부족하면_0():
    assert max_stay_minutes(5, 3, 3, buffer_minutes=2) == 0


def at(hour, minute):
    return datetime(2026, 11, 21, hour, minute)


def test_이동_시간은_올림():
    assert travel_minutes_from_seconds(61) == 2
    assert travel_minutes_from_seconds(120) == 2


def test_남은_시간은_내림():
    assert wait_minutes_from_seconds(119) == 1
    assert wait_minutes_from_seconds(120) == 2


def test_초가_음수면_오류():
    with pytest.raises(ValueError):
        travel_minutes_from_seconds(-1)
    with pytest.raises(ValueError):
        wait_minutes_from_seconds(-1)


def test_배차_간격으로_교통편_추정():
    assert estimate_vehicle_times(at(6, 0), at(7, 0), 30) == [at(6, 0), at(6, 30), at(7, 0)]


def test_배차_간격이_0이면_오류():
    with pytest.raises(ValueError):
        estimate_vehicle_times(at(6, 0), at(7, 0), 0)


def test_늦지_않는_가장_늦은_교통편():
    times = [at(8, 30), at(7, 50), at(8, 10)]
    assert pick_vehicle(times, ride_minutes=40, arrive_by=at(9, 0)) == at(8, 10)


def test_딱_맞게_도착하는_교통편도_선택():
    assert pick_vehicle([at(8, 20)], ride_minutes=40, arrive_by=at(9, 0)) == at(8, 20)


def test_탈_수_있는_교통편이_없으면_None():
    assert pick_vehicle([at(8, 30)], ride_minutes=40, arrive_by=at(9, 0)) is None
    assert plan_by_vehicle(at(9, 0), [at(8, 30)], 40, 5, 30) is None


def test_교통편에서_거꾸로_출발_시각_계산():
    # 8:30 버스는 늦으므로 8:10 버스 → 여유 5분, 도보 10분 → 7:55 출발
    plan = plan_by_vehicle(
        arrive_by=at(9, 0),
        vehicle_times=[at(7, 50), at(8, 10), at(8, 30)],
        ride_minutes=40,
        walk_to_stop_minutes=10,
        prep_minutes=30,
    )
    assert plan.board_at == at(8, 10)
    assert plan.depart_at == at(7, 55)
    assert plan.prep_start_at == at(7, 25)


def test_경유_체류_시간은_한_번만_빠짐():
    plan = plan_by_vehicle(
        arrive_by=at(9, 0),
        vehicle_times=[at(8, 10)],
        ride_minutes=40,
        walk_to_stop_minutes=12,
        prep_minutes=30,
        stop_minutes=5,
    )
    assert plan.depart_at == at(7, 48)


def test_이동_시간만_빼면_버스가_없는_시각이_나오는_경우():
    # 배차 30분 노선: 단순 계산은 8:05 출발이지만 실제로는 8:00 버스를 타야 함
    simple = plan_departure(at(9, 0), travel_minutes=50, prep_minutes=30)
    plan = plan_by_vehicle(at(9, 0), [at(7, 30), at(8, 0), at(8, 30)], 40, 10, 30)
    assert simple.depart_at == at(8, 5)
    assert plan.depart_at == at(7, 45)


def test_음수_도보_시간은_오류():
    with pytest.raises(ValueError):
        plan_by_vehicle(at(9, 0), [at(8, 10)], 40, -1, 30)
