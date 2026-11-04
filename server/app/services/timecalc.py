"""④ 계산: 출발·준비 시각, 경유지에서 최대로 쓸 수 있는 시간.

AI를 쓰지 않는 순수 계산 모듈이에요. (작업 표 15번, 29번)
"""
from dataclasses import dataclass
from datetime import datetime, timedelta


@dataclass
class DepartPlan:
    depart_at: datetime        # 출발 시각
    prep_start_at: datetime    # 준비 시작 시각


def plan_departure(
    arrive_by: datetime,
    travel_minutes: int,
    prep_minutes: int,
    buffer_minutes: int = 5,
) -> DepartPlan:
    """출발 시각 = 도착 희망 시각 − 이동 시간(경유 포함) − 여유 시간
    준비 시작 시각 = 출발 시각 − 준비 시간"""
    if travel_minutes < 0 or prep_minutes < 0 or buffer_minutes < 0:
        raise ValueError("시간은 음수일 수 없어요")
    depart_at = arrive_by - timedelta(minutes=travel_minutes + buffer_minutes)
    prep_start_at = depart_at - timedelta(minutes=prep_minutes)
    return DepartPlan(depart_at=depart_at, prep_start_at=prep_start_at)


def max_stay_minutes(
    minutes_until_vehicle: int,
    walk_to_place_minutes: int,
    walk_back_to_stop_minutes: int,
    buffer_minutes: int = 2,
) -> int:
    """경유지에서 최대로 쓸 수 있는 시간(분).

    = 교통편 도착까지 남은 시간 − 경유지까지 도보 − 정류장으로 돌아오는 도보 − 여유
    0 이하이면 들를 수 없어요 (0을 반환).
    머무는 시간을 예측하지 않고, 쓸 수 있는 최대 시간만 계산해요.
    """
    stay = (
        minutes_until_vehicle
        - walk_to_place_minutes
        - walk_back_to_stop_minutes
        - buffer_minutes
    )
    return max(stay, 0)
