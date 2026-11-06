"""④ 계산: 출발·준비 시각, 경유지에서 최대로 쓸 수 있는 시간.

AI를 쓰지 않는 순수 계산 모듈이에요. (작업 표 15번, 29번)
"""
import math
from collections.abc import Iterable
from dataclasses import dataclass
from datetime import datetime, timedelta


@dataclass
class DepartPlan:
    depart_at: datetime        # 출발 시각
    prep_start_at: datetime    # 준비 시작 시각


@dataclass
class VehiclePlan(DepartPlan):
    board_at: datetime         # 탈 교통편이 정류장에 오는 시각


def travel_minutes_from_seconds(seconds: int) -> int:
    """이동·도보 시간(초)을 분으로. 늦지 않도록 올림해요."""
    if seconds < 0:
        raise ValueError("시간은 음수일 수 없어요")
    return math.ceil(seconds / 60)


def wait_minutes_from_seconds(seconds: int) -> int:
    """교통편까지 남은 시간(초)을 분으로. 늦지 않도록 내림해요."""
    if seconds < 0:
        raise ValueError("시간은 음수일 수 없어요")
    return seconds // 60


def route_total_seconds(
    moving_seconds: int,
    first_walk_seconds: int,
    last_walk_seconds: int,
    wait_seconds: int,
) -> int:
    """경로 총 시간(초) = 구간 시간 합 + 처음·마지막 도보 + 실시간 대기"""
    parts = (moving_seconds, first_walk_seconds, last_walk_seconds, wait_seconds)
    if min(parts) < 0:
        raise ValueError("시간은 음수일 수 없어요")
    return sum(parts)


def estimate_vehicle_times(
    first_at: datetime,
    last_at: datetime,
    interval_minutes: int,
) -> list[datetime]:
    """첫차·막차·배차 간격으로 교통편 시각을 추정해요.

    회차별 시간표가 없는 노선의 사전 계산용이에요.
    출발 직전에는 실시간 도착 정보로 다시 계산해야 해요.
    """
    if interval_minutes <= 0:
        raise ValueError("배차 간격은 1분 이상이어야 해요")
    times = []
    vehicle_at = first_at
    while vehicle_at <= last_at:
        times.append(vehicle_at)
        vehicle_at += timedelta(minutes=interval_minutes)
    return times


def pick_vehicle(
    vehicle_times: Iterable[datetime],
    ride_minutes: int,
    arrive_by: datetime,
) -> datetime | None:
    """도착 희망 시각에 늦지 않는 교통편 중 가장 늦은 시각을 골라요. 없으면 None."""
    if ride_minutes < 0:
        raise ValueError("시간은 음수일 수 없어요")
    latest_board_at = arrive_by - timedelta(minutes=ride_minutes)
    return max((t for t in vehicle_times if t <= latest_board_at), default=None)


def plan_by_vehicle(
    arrive_by: datetime,
    vehicle_times: Iterable[datetime],
    ride_minutes: int,
    walk_to_stop_minutes: int,
    prep_minutes: int,
    stop_minutes: int = 0,
    buffer_minutes: int = 5,
) -> VehiclePlan | None:
    """탈 교통편을 먼저 고르고 출발·준비 시각을 거꾸로 계산해요.

    ride_minutes: 탑승부터 목적지 도착까지 (이후 환승·도보 포함)
    walk_to_stop_minutes: 집에서 정류장까지 도보 (경유 포함)
    stop_minutes: 경유지에 머무는 시간
    탈 수 있는 교통편이 없으면 None을 반환해요.
    """
    if min(walk_to_stop_minutes, prep_minutes, stop_minutes, buffer_minutes) < 0:
        raise ValueError("시간은 음수일 수 없어요")
    board_at = pick_vehicle(vehicle_times, ride_minutes, arrive_by)
    if board_at is None:
        return None
    depart_at = board_at - timedelta(
        minutes=buffer_minutes + walk_to_stop_minutes + stop_minutes
    )
    return VehiclePlan(
        depart_at=depart_at,
        prep_start_at=depart_at - timedelta(minutes=prep_minutes),
        board_at=board_at,
    )


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
