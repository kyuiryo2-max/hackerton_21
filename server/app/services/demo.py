"""시연 모드 (할 일 30번): 시각·위치·도착 정보를 고정해 항상 같은 장면을 보여 줘요.

data/demo/scenario.json 만 바꾸면 노선과 대본을 바꿀 수 있어요. 외부 API는 호출하지 않아요.

    demo.current_time()                    # 2026-11-21 08:32
    demo.arrivals("08301")                 # 2115번 720초 뒤
    demo.decide([1])                       # 이어폰 사기(편의점): 최대 체류 374초
    demo.decide([1, 3])                    # 다이소까지: 시간이 부족해요
"""
import json
from datetime import datetime, timedelta
from functools import lru_cache
from pathlib import Path

from app.services.stopover import RouteTiming, StopCandidate, StopResult, decide_stops

SCENARIO_PATH = Path(__file__).resolve().parents[3] / "data" / "demo" / "scenario.json"


@lru_cache
def scenario() -> dict:
    return json.loads(SCENARIO_PATH.read_text(encoding="utf-8"))


def current_time(elapsed_seconds: int = 0) -> datetime:
    return datetime.fromisoformat(scenario()["now"]) + timedelta(seconds=elapsed_seconds)


def current_location() -> tuple[float, float]:
    location = scenario()["location"]
    return location["lng"], location["lat"]


def deadline_seconds(elapsed_seconds: int = 0) -> int:
    """도착 희망 시각까지 남은 초."""
    arrive_by = datetime.fromisoformat(scenario()["schedule"]["arrive_by"])
    return int((arrive_by - current_time(elapsed_seconds)).total_seconds())


def arrivals(stop_id: str, elapsed_seconds: int = 0) -> list[dict]:
    """고정된 도착 정보. elapsed_seconds만큼 시간이 지난 장면도 만들 수 있어요.

    "10분 늦을 것 같아" 같은 장면에서 이미 지나간 차는 빠지고 다음 차가 첫 차가 돼요.
    """
    data = scenario()
    if stop_id != data["stop"]["ars_id"]:
        return []
    result = []
    for arrival in data["arrivals"]:
        seconds = [
            s - elapsed_seconds
            for s in (arrival["first_seconds"], arrival["second_seconds"])
            if s - elapsed_seconds >= 0
        ]
        result.append({
            **arrival,
            "ars_id": stop_id,
            "stop_name": data["stop"]["name"],
            "first_seconds": seconds[0] if seconds else None,
            "second_seconds": seconds[1] if len(seconds) > 1 else None,
        })
    return result


def route_timing(elapsed_seconds: int = 0) -> RouteTiming:
    data = scenario()
    route = data["route"]
    arrival = next(a for a in arrivals(data["stop"]["ars_id"], elapsed_seconds) if a["route"] == route["name"])
    vehicles = [s for s in (arrival["first_seconds"], arrival["second_seconds"]) if s is not None]
    return RouteTiming(
        moving_seconds=route["moving_seconds"],
        first_walk_seconds=0,  # 시연은 정류장에 서 있는 장면이에요
        last_walk_seconds=route["last_walk_seconds"],
        vehicle_seconds=vehicles,
    )


def stop_candidates(todo_ids: list[int]) -> list[StopCandidate]:
    places = {p["todo_id"]: p for p in scenario()["places"]}
    return [
        StopCandidate(
            todo_id=todo_id,
            importance=places[todo_id]["importance"],
            detour_seconds=places[todo_id]["round_trip_walk_seconds"],
            stay_seconds=places[todo_id]["stay_seconds"],
        )
        for todo_id in todo_ids
    ]


def decide(todo_ids: list[int], elapsed_seconds: int = 0) -> StopResult:
    """고른 할 일을 끼워 넣을 수 있는지 시연 데이터로 계산해요."""
    return decide_stops(
        route_timing(elapsed_seconds),
        stop_candidates(todo_ids),
        deadline_seconds(elapsed_seconds),
    )
