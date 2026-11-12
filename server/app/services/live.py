"""실제 모드 질문용 "마지막 계획" 기억 (할 일 59번).

이동 중 질문("다음 버스 언제야?", "편의점 들러도 돼?", "얼마나 남았어?")은 어느 경로로 가는지 알아야 답할 수 있어요.
그래서 /api/plan(실시간)을 계산할 때 1위 경로의 탑승 구간과 시간 계산 값을 사용자별로 잠깐 기억해 두고,
질문이 오면 그 경로로 실시간 도착 정보를 다시 물어 답해요.

- 메모리에만 두고 DB에 저장하지 않아요. 서버가 다시 켜지면 사라지고, 1시간이 지나도 버려요.
- 사용자의 현재 좌표는 넣지 않아요 (11/9 팀 결정). 정류장 좌표, 노선, 걸리는 시간(초)만 기억해요.
"""
from dataclasses import dataclass
from datetime import datetime, timedelta
from threading import Lock

from app.services.stopover import RouteTiming

TTL = timedelta(hours=1)
MAX_USERS = 1000


@dataclass(frozen=True)
class LivePlan:
    planned_at: datetime
    arrive_by: datetime
    leg: dict            # 첫 탑승 구간 (type, vehicles, start=정류장 좌표, stops …). 사용자 위치 아님
    timing: RouteTiming  # 계획할 때의 도보·이동 시간(초)
    places: dict         # todo_id → 그 할 일에 고른 장소 (경로에 넣었는지는 DB의 할 일 상태로 봐요)


_plans: dict[str, LivePlan] = {}
_lock = Lock()


def remember(user_id: str, plan: LivePlan) -> None:
    with _lock:
        _plans.pop(user_id, None)
        if len(_plans) >= MAX_USERS:
            del _plans[next(iter(_plans))]  # 가장 오래된 사용자부터 지워요
        _plans[user_id] = plan


def recall(user_id: str, now: datetime) -> LivePlan | None:
    """1시간 안에 계산한 계획. 일정 도착 시각이 지났으면 없음으로 봐요."""
    with _lock:
        plan = _plans.get(user_id)
    if plan is None or now - plan.planned_at > TTL or now > plan.arrive_by:
        return None
    return plan


def forget_all() -> None:
    """테스트용"""
    with _lock:
        _plans.clear()
