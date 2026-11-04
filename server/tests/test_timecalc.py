from datetime import datetime

import pytest

from app.services.timecalc import max_stay_minutes, plan_departure


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
