"""④ 계산: 경유 포함·미포함 총 시간, 최대 체류 시간, 경유지 제외 판단 (할 일 28·29번).

외부 호출이 없는 순수 계산이에요. 시간은 모두 초이고, 지금부터 지난 초로 나타내요.
화면에 보여 줄 때 timecalc.travel_minutes_from_seconds 로 한 번만 올림해요.

    route = RouteTiming(moving_seconds=797, first_walk_seconds=118, last_walk_seconds=119,
                        vehicle_seconds=[720, 1200])
    result = decide_stops(route, [StopCandidate(1, "필수", detour_seconds=120, stay_seconds=240)],
                          deadline_seconds=3600)
    result.total_seconds, result.max_stay_seconds
"""
from dataclasses import dataclass

DEFAULT_BUFFER_SECONDS = 120  # 정류장에 미리 도착해 있는 여유
SUBWAY_MARGIN_SECONDS = 60    # 지하철 도착 시간은 1분 단위라 더하는 여유
REQUIRED = "필수"


@dataclass
class RouteTiming:
    moving_seconds: int            # 카카오 구간 시간 합 (totalTime 아님)
    first_walk_seconds: int        # 지금 위치 → 승차 정류장
    last_walk_seconds: int         # 하차 정류장 → 목적지
    vehicle_seconds: list[int]     # 지금부터 차가 오기까지, 모르면 빈 목록
    is_subway: bool = False
    interval_seconds: int | None = None  # 배차 간격, 모르면 None (서울시 버스 interval_minutes × 60)


@dataclass
class StopCandidate:
    todo_id: int
    importance: str                # 필수 / 선택
    detour_seconds: int            # 경유로 늘어나는 도보 (경유 도보 − 바로 가는 도보)
    stay_seconds: int              # 머무는 시간


@dataclass
class StopDecision:
    todo_id: int
    status: str                    # included / excluded / ask
    reason: str = ""


@dataclass
class StopResult:
    decisions: list[StopDecision]
    board_seconds: int | None      # 탈 차가 오는 시각, 실시간 정보가 없으면 None
    total_seconds: int             # 경유 포함 총 시간
    direct_total_seconds: int      # 경유 미포함 총 시간
    max_stay_seconds: int | None   # 고른 차를 타면서 경유지에서 쓸 수 있는 전체 시간
    has_realtime: bool = True


def buffer_seconds(route: RouteTiming, buffer: int = DEFAULT_BUFFER_SECONDS) -> int:
    return buffer + (SUBWAY_MARGIN_SECONDS if route.is_subway else 0)


def pick_board_seconds(vehicle_seconds: list[int], ready_seconds: int, buffer: int) -> int | None:
    """정류장 도착 후 여유를 두고 탈 수 있는 가장 빠른 차. 없으면 None."""
    return min((v for v in vehicle_seconds if v >= ready_seconds + buffer), default=None)


def max_stay_seconds(board_seconds: int, walk_seconds: int, buffer: int) -> int:
    """체류 가능 시간 = 차가 올 때까지 − 경유 도보 − 여유. 부족하면 0이에요."""
    return max(board_seconds - walk_seconds - buffer, 0)


def next_by_interval(vehicle_seconds: list[int], need_seconds: int, interval: int) -> int:
    """목록의 마지막 차 뒤로 배차 간격만큼 이어서, need_seconds 이후 가장 빠른 차."""
    last = max(vehicle_seconds)
    count = -(-(need_seconds - last) // interval)  # 올림
    return last + count * interval


def total_seconds(route: RouteTiming, ready_seconds: int, buffer: int) -> tuple[int, int | None] | None:
    """(총 시간, 탈 차 시각). 실시간 정보가 없으면 대기 0으로 계산해요.

    목록의 차를 모두 놓치면 배차 간격으로 다음 차를 추정해요.
    배차 간격도 모르면 None이에요.
    """
    after_board = route.moving_seconds + route.last_walk_seconds
    if not route.vehicle_seconds:
        return ready_seconds + after_board, None
    board = pick_board_seconds(route.vehicle_seconds, ready_seconds, buffer)
    if board is None and route.interval_seconds:
        board = next_by_interval(route.vehicle_seconds, ready_seconds + buffer, route.interval_seconds)
    if board is None:
        return None
    return board + after_board, board


def _validate(route: RouteTiming, stops: list[StopCandidate], deadline_seconds: int) -> None:
    times = [
        route.moving_seconds, route.first_walk_seconds, route.last_walk_seconds,
        deadline_seconds, *route.vehicle_seconds,
        *(s.detour_seconds for s in stops), *(s.stay_seconds for s in stops),
    ]
    if times and min(times) < 0:
        raise ValueError("시간은 음수일 수 없어요")
    if route.interval_seconds is not None and route.interval_seconds <= 0:
        raise ValueError("배차 간격은 0보다 커야 해요")


def decide_stops(
    route: RouteTiming,
    stops: list[StopCandidate],
    deadline_seconds: int,
    buffer: int = DEFAULT_BUFFER_SECONDS,
) -> StopResult:
    """필수 할 일부터 넣어 보고 도착 희망 시각을 넘기면 경유지를 뺄지 정해요.

    - 들러도 늦지 않으면 included
    - 시간이 부족한 선택 할 일은 excluded
    - 시간이 부족한 필수 할 일은 ask (사용자에게 선택지를 보여 줘요)
    경유지가 여럿이면 detour_seconds를 더해 계산해서 실제 동선보다 조금 길 수 있어요.
    """
    _validate(route, stops, deadline_seconds)
    buffer = buffer_seconds(route, buffer)
    direct = total_seconds(route, route.first_walk_seconds, buffer)
    # 경유 없이도 탈 차가 없으면 경유지를 넣을 수 없어요
    direct_total = direct[0] if direct else route.first_walk_seconds + route.moving_seconds + route.last_walk_seconds

    ready = route.first_walk_seconds
    best = direct
    decisions = []
    for stop in sorted(stops, key=lambda s: s.importance != REQUIRED):
        added = ready + stop.detour_seconds + stop.stay_seconds
        trial = total_seconds(route, added, buffer)
        if trial is not None and trial[0] <= deadline_seconds:
            ready, best = added, trial
            decisions.append(StopDecision(stop.todo_id, "included"))
        elif stop.importance == REQUIRED:
            decisions.append(StopDecision(stop.todo_id, "ask", "시간이 부족해요"))
        else:
            decisions.append(StopDecision(stop.todo_id, "excluded", "시간이 부족해요"))

    final_total, board = best if best else (direct_total, None)
    walk = ready - sum(s.stay_seconds for s in _included(stops, decisions))
    return StopResult(
        decisions=decisions,
        board_seconds=board,
        total_seconds=final_total,
        direct_total_seconds=direct_total,
        max_stay_seconds=None if board is None else max_stay_seconds(board, walk, buffer),
        has_realtime=bool(route.vehicle_seconds),
    )


def _included(stops: list[StopCandidate], decisions: list[StopDecision]) -> list[StopCandidate]:
    included = {d.todo_id for d in decisions if d.status == "included"}
    return [s for s in stops if s.todo_id in included]
