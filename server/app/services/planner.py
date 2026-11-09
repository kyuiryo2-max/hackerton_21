"""⑤ 추천: /api/plan 응답 만들기 (할 일 33번).

할 일(DB)과 경로·도착 정보를 경유 계산(stopover)에 넣고, 결과를 앱이 쓰는 모양으로 바꿔요.
- plan_demo: 시연 모드. 시각·위치·도착 정보는 data/demo/scenario.json 고정값
- plan_live: 실시간. 앱이 보낸 현재 좌표로 카카오 경로와 서울시 도착 정보를 조회해요.
  현재 좌표는 계산에만 쓰고 저장하거나 기록하지 않아요 (11/9 팀 결정)

시간은 계산할 때 초, 응답할 때 분이에요.
이동·도보는 올림, 교통편까지 남은 시간과 최대 체류 시간은 내림해요. (늦지 않는 쪽)
"""
import logging
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from app.db import repository as repo
from app.db.database import DEMO_USER_ID
from app.services import demo, kakao, places, seoul_bus, seoul_subway
from app.services.stopover import RouteTiming, StopCandidate, StopResult, decide_stops
from app.services.timecalc import travel_minutes_from_seconds, wait_minutes_from_seconds

log = logging.getLogger(__name__)

# 계산 결과 → DB 상태 (api.md "할 일 상태·출처")
STATUS = {"included": "포함", "excluded": "제외", "ask": "대기"}
ASK_OPTIONS = ["이번엔 빼기", "늦더라도 들르기"]
ACTIVE = ("대기", "포함", "제외")  # 완료한 할 일은 다시 계산하지 않아요

KST = timezone(timedelta(hours=9))
MAX_ROUTES = 3
PLACE_RADIUS_M = 300
# 장소별 체류 시간 기본값이 정해지기 전 임시값 (시연 대본의 편의점과 같은 4분)
DEFAULT_STAY_SECONDS = 240
TRANSIT_TYPES = ("BUS", "SUBWAY")
LOOKAHEAD_SECONDS = 60 * 60       # 실시간은 앞 차 2~3대만 알려 줘서 배차 간격으로 1시간 뒤까지 이어 붙여요
DEFAULT_SUBWAY_GAP_SECONDS = 300  # 지하철 차가 하나뿐이면 5분 간격으로 봐요


class PlanError(Exception):
    def __init__(self, status: int, code: str, message: str):
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


@dataclass
class RouteOption:
    """계산에 넣을 경로 하나와 카드에 보여 줄 정보."""
    timing: RouteTiming
    card: dict           # type, name, guidance, transfers, fare, stops
    places: dict         # todo_id → 장소 (place_type, name, address, round_trip_walk_seconds, stay_seconds)
    result: StopResult | None = None


def _todos(user_id: str, todo_ids: list[int] | None) -> list[dict]:
    if todo_ids is None:
        return [t for t in repo.list_todos(user_id) if t["status"] in ACTIVE]
    todos = []
    for todo_id in todo_ids:
        todo = repo.get_todo(todo_id, user_id)
        if todo is None:
            raise PlanError(404, "not_found", f"할 일 {todo_id} 없음")
        todos.append(todo)
    return todos


def _demo_place(todo: dict) -> dict | None:
    """할 일의 장소 종류 중 시연 지역에 있는 첫 장소."""
    by_type = {p["place_type"]: p for p in demo.scenario()["places"]}
    return next((by_type[t] for t in todo["place_types"] if t in by_type), None)


def _explanation(route_name: str, included: list[dict], arrive_at) -> str:
    """AI 문장(#36)이 붙기 전까지 쓰는 정해진 문장. 숫자는 계산값만 써요."""
    time = f"{arrive_at.hour}시 {arrive_at.minute}분"
    if not included:
        return f"{route_name}번을 타면 {time}에 도착해요."
    names = ", ".join(t["text"] for t in included)
    return f"{route_name}번을 타면 {names}까지 하고 {time}에 도착해요."


def _decide(option: RouteOption, todos: list[dict], deadline_seconds: int) -> StopResult:
    candidates = [
        StopCandidate(t["id"], t["importance"], option.places[t["id"]]["round_trip_walk_seconds"],
                      option.places[t["id"]]["stay_seconds"])
        for t in todos if option.places.get(t["id"])
    ]
    return decide_stops(option.timing, candidates, deadline_seconds)


def _route_card(rank: int, option: RouteOption) -> dict:
    timing, result = option.timing, option.result
    wait_seconds = (result.board_seconds or timing.first_walk_seconds) - timing.first_walk_seconds
    return {
        "rank": rank,
        **{k: option.card[k] for k in ("type", "name", "guidance")},
        "total_min": travel_minutes_from_seconds(result.total_seconds),
        "first_walk_min": travel_minutes_from_seconds(timing.first_walk_seconds),
        "wait_min": wait_minutes_from_seconds(wait_seconds),
        "moving_min": travel_minutes_from_seconds(timing.moving_seconds),
        "last_walk_min": travel_minutes_from_seconds(timing.last_walk_seconds),
        **{k: option.card[k] for k in ("transfers", "fare", "stops")},
        "max_stay_min": None if result.max_stay_seconds is None else wait_minutes_from_seconds(result.max_stay_seconds),
        "has_realtime": result.has_realtime,
    }


def _response(user_id: str, todos: list[dict], options: list[RouteOption], now: datetime,
              schedule: dict, missing_reason: str) -> dict:
    """첫 번째 경로로 할 일 상태를 정하고, 경로 카드는 모두 보여 줘요."""
    best = options[0]
    result = best.result
    by_id = {t["id"]: t for t in todos}
    decided = {d.todo_id: d for d in result.decisions}

    todo_rows = []
    for todo_id in [d.todo_id for d in result.decisions] + [t["id"] for t in todos if not best.places.get(t["id"])]:
        todo, place = by_id[todo_id], best.places.get(todo_id)
        decision = decided.get(todo_id)
        # 장소를 못 찾으면 계산을 못 한 것이라 저장하지 않고, 필수는 사라지지 않게 대기로 보여 줘요
        status = STATUS[decision.status] if decision else ("대기" if todo["importance"] == "필수" else "제외")
        row = {
            "todo_id": todo_id,
            "text": todo["text"],
            "importance": todo["importance"],
            "status": status,
            "place": place and {k: place[k] for k in ("place_type", "name", "address")},
            "detour_min": travel_minutes_from_seconds(place["round_trip_walk_seconds"]) if place else None,
            "reason": decision.reason if decision else missing_reason,
        }
        if decision and decision.status == "ask":
            row["options"] = ASK_OPTIONS
        todo_rows.append(row)
        if decision and user_id != DEMO_USER_ID:
            repo.update_todo(todo_id, user_id, status=status)

    arrive_at = now + timedelta(seconds=result.total_seconds)
    included = [by_id[d.todo_id] for d in result.decisions if d.status == "included"]
    return {
        "now": now.isoformat(),
        "schedule": schedule,
        "board_at": None if result.board_seconds is None
        else (now + timedelta(seconds=result.board_seconds)).isoformat(),
        "arrive_at": arrive_at.isoformat(),
        "routes": [_route_card(i, o) for i, o in enumerate(options, 1)],
        "todos": todo_rows,
        "explanation": _explanation(best.card["name"], included, arrive_at),
    }


def plan_demo(user_id: str, todo_ids: list[int] | None = None) -> dict:
    """시연 모드 계획. 시각·위치·일정·도착 정보는 시나리오 고정값이고 할 일은 DB에서 읽어요.

    demo 사용자가 아니면 계산한 상태(포함·제외·대기)를 할 일에 저장해요.
    부스에서 관객이 자기 할 일로 시연해 볼 때 쓰는 경로예요.
    """
    data = demo.scenario()
    todos = [t for t in _todos(user_id, todo_ids) if t["place_types"]]  # 들를 곳이 없는 할 일은 빼요
    route = data["route"]
    option = RouteOption(
        timing=demo.route_timing(),
        card={"type": route["type"], "name": route["name"], "guidance": route["guidance"],
              "transfers": route["transfers"], "fare": route["fare_min"], "stops": route["stops"]},
        places={t["id"]: _demo_place(t) for t in todos},
    )
    option.result = _decide(option, todos, demo.deadline_seconds())
    return _response(user_id, todos, [option], demo.current_time(), data["schedule"], "시연 지역에 없는 장소예요")


# ---------- 실시간 ----------
def extend_by_interval(seconds: list[int], interval: int | None) -> list[int]:
    """알려진 마지막 차 뒤로 배차 간격만큼 차를 이어 붙여요 (실시간은 앞 차 2~3대만 알려 줘요)."""
    if not seconds or not interval or interval <= 0:
        return seconds
    out = list(seconds)
    while out[-1] + interval <= LOOKAHEAD_SECONDS:
        out.append(out[-1] + interval)
    return out


def _vehicle_seconds(leg: dict) -> list[int]:
    """첫 탑승 구간의 도착(초). 실시간 값 뒤에는 배차 간격으로 추정한 차가 이어져요.

    못 찾거나 서울시 API가 실패하면 빈 목록이고, 대기 0으로 계산해요.
    """
    try:
        if leg["type"] == "BUS":
            found = seoul_bus.match_leg(leg)
            if not found:
                return []
            arrival = found["arrival"]
            known = [s for s in (arrival["first_seconds"], arrival["second_seconds"]) if s is not None]
            interval = arrival.get("interval_minutes")
            return extend_by_interval(known, interval * 60 if interval else None)
        found = seoul_subway.match_leg(leg)
        if not found:
            return []
        known = sorted(t["seconds"] for t in found["trains"])
        gap = known[1] - known[0] if len(known) > 1 and known[1] > known[0] else DEFAULT_SUBWAY_GAP_SECONDS
        return extend_by_interval(known, gap)
    except (seoul_bus.SeoulBusError, seoul_subway.SeoulSubwayError) as e:
        log.warning("실시간 도착 조회 실패, 대기 없이 계산: %s", e)
        return []


def _near_place(todo: dict, stop: kakao.Coord, cache: dict) -> dict | None:
    """탑승 정류장 근처에서 할 일 장소 종류의 가장 가까운 곳과 왕복 도보 시간."""
    for place_type in todo["place_types"]:
        key = (place_type, stop)
        if key not in cache:
            found = None
            for p in places.search_by_place_type(place_type, stop, radius_m=PLACE_RADIUS_M, size=1):
                walk = kakao.walk_seconds(stop, stop, via=[(p["lng"], p["lat"])])
                if walk is not None:
                    found = {"place_type": place_type, "name": p["name"], "address": p["address"],
                             "round_trip_walk_seconds": walk, "stay_seconds": DEFAULT_STAY_SECONDS}
            cache[key] = found
        if cache[key]:
            return cache[key]
    return None


def _live_option(route: dict, origin: kakao.Coord, destination: kakao.Coord,
                 todos: list[dict], place_cache: dict) -> RouteOption | None:
    legs = [leg for leg in route["legs"] if leg["type"] in TRANSIT_TYPES and leg["start"]]
    if not legs:
        return None
    first, last = legs[0], legs[-1]
    first_walk = kakao.walk_seconds(origin, tuple(first["start"]))
    last_walk = kakao.walk_seconds(tuple(last["end"] or last["start"]), destination)
    if first_walk is None or last_walk is None:
        # 도보 경로를 못 찾으면 카카오 총 시간에서 구간 시간을 뺀 나머지를 처음 도보로 봐요
        spare = max((route["kakao_total_seconds"] or 0) - route["moving_seconds"], 0)
        first_walk, last_walk = (first_walk if first_walk is not None else spare), (last_walk or 0)
    stop = tuple(first["start"])
    return RouteOption(
        timing=RouteTiming(route["moving_seconds"], first_walk, last_walk, _vehicle_seconds(first),
                           is_subway=first["type"] == "SUBWAY"),
        card={"type": route["type"], "name": "·".join(first["vehicles"][:3]) or first["guidance"],
              "guidance": first["guidance"], "transfers": route["transfers"], "fare": route["fare_min"],
              "stops": first["stops"]},
        places={t["id"]: _near_place(t, stop, place_cache) for t in todos},
    )


def _missed(option: RouteOption, todos: list[dict], importance: str | None) -> int:
    """이 경로에서 넣지 못한 할 일 수 (importance가 있으면 그 중요도만)."""
    included = {d.todo_id for d in option.result.decisions if d.status == "included"}
    return sum(1 for t in todos if (importance is None or t["importance"] == importance) and t["id"] not in included)


def plan_live(user_id: str, origin: kakao.Coord, schedule_id: int | None = None,
              todo_ids: list[int] | None = None, now: datetime | None = None) -> dict:
    """실시간 계획. origin은 (경도, 위도)이고 저장하지 않아요.

    카카오 경로 최대 3개를 계산하고 할 일을 잘 넣는 경로부터 보여 줘요. 할 일 상태는 첫 번째 경로 기준이에요.
    """
    now = now or datetime.now(KST).replace(microsecond=0)
    schedules = repo.list_schedules(user_id)
    schedule = next((s for s in schedules if schedule_id is None or s["id"] == schedule_id), None)
    if schedule is None:
        raise PlanError(404, "not_found", "일정이 없어요" if schedule_id is None else f"일정 {schedule_id} 없음")
    destination = (schedule["destination_lng"], schedule["destination_lat"])
    arrive_by = datetime.fromisoformat(schedule["arrive_by"])
    if arrive_by.tzinfo is None:
        arrive_by = arrive_by.replace(tzinfo=KST)
    deadline = int((arrive_by - now).total_seconds())

    todos = [t for t in _todos(user_id, todo_ids) if t["place_types"]]
    try:
        routes = kakao.transit_routes(origin, destination)
        place_cache: dict = {}
        options = [o for r in routes[:MAX_ROUTES]
                   if (o := _live_option(r, origin, destination, todos, place_cache))]
    except kakao.KakaoError as e:
        raise PlanError(502, "upstream_error", str(e)) from None
    if not options:
        raise PlanError(404, "no_route", "대중교통 경로를 찾지 못했어요")

    for option in options:
        option.result = _decide(option, todos, deadline)
    # 필수 할 일을 넣을 수 있는 경로 → 할 일을 많이 넣는 경로 → 빨리 도착하는 경로 순이에요
    options.sort(key=lambda o: (_missed(o, todos, "필수"), _missed(o, todos, None), o.result.total_seconds))
    schedule_out = {
        "destination": {"name": schedule["destination"], "lng": destination[0], "lat": destination[1]},
        "arrive_by": arrive_by.isoformat(),
        "prep_minutes": schedule["prep_minutes"],
    }
    return _response(user_id, todos, options, now, schedule_out, "근처에서 찾지 못했어요")
