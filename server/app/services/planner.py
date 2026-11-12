"""⑤ 추천: /api/plan 응답 만들기 (할 일 33번).

할 일(DB)과 경로·도착 정보를 경유 계산(stopover)에 넣고, 결과를 앱이 쓰는 모양으로 바꿔요.
- plan_demo: 시연 모드. 시각·위치·도착 정보는 data/demo/scenario.json 고정값
- plan_live: 실시간. 앱이 보낸 현재 좌표로 카카오 경로와 서울시 도착 정보를 조회해요.
  현재 좌표는 계산에만 쓰고 저장하거나 기록하지 않아요 (11/9 팀 결정)

시간은 계산할 때 초, 응답할 때 분이에요.
이동·도보는 올림, 교통편까지 남은 시간과 최대 체류 시간은 내림해요. (늦지 않는 쪽)
"""
import logging
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

from app.db import repository as repo
from app.db.database import DEMO_USER_ID
from app.services import demo, kakao, live, places, seoul_bus, seoul_subway
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
# 할 일에 머물 시간(stay_minutes)이 없을 때 쓰는 기본값 (시연 대본의 편의점과 같은 4분)
DEFAULT_STAY_SECONDS = 240
# 할 일 하나에 보여 줄 경유 후보 수 (#62). 장소 종류마다 이만큼 찾고, 합쳐서 가까운 순으로 이만큼만 도보 시간을 재요
MAX_CANDIDATES = 3
TRANSIT_TYPES = ("BUS", "SUBWAY")
LOOKAHEAD_SECONDS = 60 * 60       # 실시간은 앞 차 2~3대만 알려 줘서 배차 간격으로 1시간 뒤까지 이어 붙여요
# 출발 기준 (11/13 팀 결정)
#   일정으로 찾기: 도착 희망 시각에서 거꾸로 "몇 시에 출발"을 계산해요 (basis "arrive_by").
#     출발까지 REALTIME_WINDOW_SECONDS 안으로 다가오면 실시간 버스 도착을 붙여 탈 차를 정해요 (basis "realtime").
#   목적지로 바로 찾기(홈 검색창): 지금 출발 기준 (basis "now")
REALTIME_WINDOW_SECONDS = 30 * 60
ARRIVE_MARGIN_SECONDS = 5 * 60    # 거꾸로 계산할 때 도착 희망 시각보다 이만큼 일찍 도착하게 잡아요
NOW_TRIP_DEADLINE_SECONDS = 6 * 60 * 60  # 지금 출발에는 도착 목표가 없어서, 계산용으로만 넉넉히 둬요
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
    places: dict         # todo_id → 장소 (place_type, name, address, lng, lat, round_trip_walk_seconds,
                         #              stay_seconds, candidates[])
    result: StopResult | None = None
    leg: dict | None = field(default=None, repr=False)  # 실시간: 첫 탑승 구간 (질문 답변에서 다시 써요)
    times: dict = field(default_factory=dict)           # basis, depart_at, board_at, arrive_at (datetime)


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


def stay_seconds(todo: dict, fallback: int = DEFAULT_STAY_SECONDS) -> int:
    """할 일에 사용자가 정한 머물 시간이 있으면 그 값, 없으면 fallback (초)."""
    minutes = todo.get("stay_minutes")
    return minutes * 60 if minutes else fallback


def _demo_place(todo: dict) -> dict | None:
    """할 일의 장소 종류 중 시연 지역에 있는 첫 장소. 머물 시간은 할 일에 정한 값이 먼저예요."""
    by_type = {p["place_type"]: p for p in demo.scenario()["places"]}
    place = next((by_type[t] for t in todo["place_types"] if t in by_type), None)
    if place is None:
        return None
    return {**place, "stay_seconds": stay_seconds(todo, place["stay_seconds"])}


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


def _place_out(place: dict) -> dict:
    return {k: place.get(k) for k in ("place_type", "name", "address", "lng", "lat")}


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
        # 경로마다 같은 기준으로 계산한 시각 (11/13). 앱은 순위와 상관없이 이 값을 그대로 보여 주면 돼요
        **_iso_times(option.times),
        # 구간 목록 (걷기·버스·지하철, 분, 타는 곳 → 내리는 곳, 지도에 그릴 좌표)
        "legs": option.card.get("legs", []),
    }


def _iso_times(times: dict) -> dict:
    out = {"basis": times.get("basis")}
    for key in ("depart_at", "board_at", "arrive_at"):
        out[key] = times[key].isoformat() if times.get(key) else None
    return out


def _ready_seconds(option: RouteOption) -> int:
    """정류장에서 차를 탈 준비가 될 때까지: 처음 도보 + 넣은 경유지 왕복 도보 + 머무는 시간."""
    included = {d.todo_id for d in option.result.decisions if d.status == "included"}
    extra = sum(p["round_trip_walk_seconds"] + p["stay_seconds"]
                for tid, p in option.places.items() if p and tid in included)
    return option.timing.first_walk_seconds + extra


def _set_times(option: RouteOption, now: datetime, arrive_by: datetime | None) -> None:
    """경로 하나의 출발·탑승·도착 시각.

    - 실시간 차가 있으면(realtime·시연): 탈 차에 맞춰 늦어도 언제 나가야 하는지
    - 일정인데 실시간이 없으면(arrive_by): 도착 희망 5분 전에 닿도록 거꾸로
    - 지금 출발(now): 지금 나가요
    """
    result = option.result
    ready = _ready_seconds(option)
    if result.board_seconds is not None:
        slack = max(result.board_seconds - ready - _stop_buffer(option), 0)
        depart = now + timedelta(seconds=slack)
        option.times = {"basis": "realtime" if arrive_by else "now", "depart_at": depart,
                        "board_at": now + timedelta(seconds=result.board_seconds),
                        "arrive_at": now + timedelta(seconds=result.total_seconds)}
        return
    if arrive_by is not None:
        depart = max(now, arrive_by - timedelta(seconds=ARRIVE_MARGIN_SECONDS + result.total_seconds))
        basis = "arrive_by"
    else:
        depart, basis = now, "now"
    option.times = {"basis": basis, "depart_at": depart, "board_at": depart + timedelta(seconds=ready),
                    "arrive_at": depart + timedelta(seconds=result.total_seconds)}


def _stop_buffer(option: RouteOption) -> int:
    from app.services.stopover import buffer_seconds
    return buffer_seconds(option.timing)


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
            "stay_min": travel_minutes_from_seconds(place["stay_seconds"] if place else stay_seconds(todo)),
            "place": place and _place_out(place),
            "detour_min": travel_minutes_from_seconds(place["round_trip_walk_seconds"]) if place else None,
            # 경유 후보 여러 곳 (#62). 첫 번째가 place와 같아요. 앱은 후보마다 머물 수 있는 시간을 비교해요
            "candidates": [{**_place_out(c), "detour_min": travel_minutes_from_seconds(c["round_trip_walk_seconds"])}
                           for c in (place.get("candidates") or [place])] if place else [],
            "reason": decision.reason if decision else missing_reason,
        }
        if decision and decision.status == "ask":
            row["options"] = ASK_OPTIONS
        todo_rows.append(row)
        if decision and user_id != DEMO_USER_ID:
            repo.update_todo(todo_id, user_id, status=status)

    times = best.times
    arrive_at = times["arrive_at"]
    included = [by_id[d.todo_id] for d in result.decisions if d.status == "included"]
    return {
        "now": now.isoformat(),
        "schedule": schedule,
        # basis: arrive_by(도착 시각에서 거꾸로) / realtime(실시간 차) / now(지금 출발)
        "basis": times["basis"],
        "depart_at": times["depart_at"].isoformat(),
        # 실시간 차가 없으면 board_at은 정류장에 닿는 예상 시각이에요 (has_realtime=false)
        "board_at": times["board_at"].isoformat() if result.board_seconds is not None or times["basis"] != "realtime"
        else None,
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
    option.card["legs"] = _demo_legs(route, option.timing)
    option.result = _decide(option, todos, demo.deadline_seconds())
    _set_times(option, demo.current_time(), _arrive_by(data["schedule"]))
    return _response(user_id, todos, [option], demo.current_time(), data["schedule"], "시연 지역에 없는 장소예요")


def _demo_legs(route: dict, timing: RouteTiming) -> list[dict]:
    # 시나리오의 실제 경로 좌표(path)를 쓰고, 없으면 정류장 좌표를 이어요
    points = kakao._thin(route.get("path") or [[p["lng"], p["lat"]] for p in route.get("stop_points", []) if "lng" in p])
    stops = route.get("stops", [])
    return [
        _walk_leg(timing.first_walk_seconds, "출발지", stops[0] if stops else "", None),
        {"type": route["type"], "name": route["name"], "guidance": route.get("guidance", ""),
         "from": stops[0] if stops else "", "to": stops[-1] if stops else "", "stop_count": max(len(stops) - 1, 0),
         "minutes": travel_minutes_from_seconds(timing.moving_seconds), "points": points},
        _walk_leg(timing.last_walk_seconds, stops[-1] if stops else "", "도착지", None),
    ]


def _walk_leg(seconds: int, frm: str, to: str, points: list | None) -> dict:
    return {"type": "WALK", "name": "도보", "from": frm, "to": to,
            "minutes": travel_minutes_from_seconds(seconds), "points": points or []}


def _live_legs(route: dict, origin: kakao.Coord, destination: kakao.Coord,
               first_walk: int, last_walk: int) -> list[dict]:
    """카카오 구간 전체를 앱이 그리기 쉬운 목록으로 (처음·마지막 도보 포함).

    카카오 legs에는 처음·마지막 도보가 없어서 직접 앞뒤에 붙여요.
    """
    out, prev_stop = [], "출발지"
    transit = [leg for leg in route["legs"] if leg["type"] in TRANSIT_TYPES]
    first, last = transit[0], transit[-1]
    out.append(_walk_leg(first_walk, "출발지", (first["stops"] or [""])[0],
                         [list(origin), list(first["start"])] if first["start"] else []))
    for leg in route["legs"]:
        if leg["type"] in TRANSIT_TYPES:
            stops = leg["stops"]
            out.append({"type": leg["type"], "name": "·".join(leg["vehicles"][:3]) or leg["guidance"],
                        "guidance": leg["guidance"], "from": stops[0] if stops else "",
                        "to": stops[-1] if stops else "", "stop_count": max(len(stops) - 1, 0),
                        "minutes": travel_minutes_from_seconds(leg["seconds"]), "points": leg.get("points", [])})
            prev_stop = stops[-1] if stops else prev_stop
        elif leg["seconds"]:
            out.append({**_walk_leg(leg["seconds"], prev_stop, "환승", leg.get("points")), "name": "환승 도보"})
    end = last["end"] or last["start"]
    out.append(_walk_leg(last_walk, (last["stops"] or [""])[-1], "도착지",
                         [list(end), list(destination)] if end else []))
    return out


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


def _search_type(place_type: str, stop: kakao.Coord, cache: dict) -> list[dict]:
    """정류장 근처에서 장소 종류 하나로 찾은 곳 (가까운 순). 같은 계획 안에서는 다시 부르지 않아요."""
    key = ("search", place_type, stop)
    if key not in cache:
        found = places.search_by_place_type(place_type, stop, radius_m=PLACE_RADIUS_M, size=MAX_CANDIDATES)
        cache[key] = [{**p, "place_type": place_type} for p in found]
    return cache[key]


def _round_trip(stop: kakao.Coord, p: dict, cache: dict) -> int | None:
    """정류장 → 장소 → 정류장 도보(초)."""
    key = ("walk", stop, p["name"], p["address"])
    if key not in cache:
        cache[key] = kakao.walk_seconds(stop, stop, via=[(p["lng"], p["lat"])])
    return cache[key]


def _near_place(todo: dict, stop: kakao.Coord, cache: dict) -> dict | None:
    """탑승 정류장 근처의 경유 후보 (#62).

    할 일의 장소 종류를 모두 찾아 합치고(예: 이어폰 → 편의점·다이소), 직선거리로 가까운 MAX_CANDIDATES곳만
    도보 시간을 재요. 카카오 호출을 아끼려고 먼 곳은 도보 시간을 재지 않아요.
    도보가 짧은 곳(= 가장 오래 머물 수 있는 곳)이 첫 번째이고, 계산은 첫 번째 후보로 해요.
    """
    found: dict[tuple, dict] = {}
    for place_type in todo["place_types"]:
        for p in _search_type(place_type, stop, cache):
            found.setdefault((p["name"], p["address"]), p)  # 두 종류에 같은 가게가 나오면 한 번만
    unknown = 10**9  # 거리를 모르면 맨 뒤로
    nearest = sorted(found.values(), key=lambda p: unknown if p.get("distance_m") is None else p["distance_m"])
    nearest = nearest[:MAX_CANDIDATES]
    if not nearest:
        return None
    # 후보 도보 시간은 서로 상관없어서 동시에 물어봐요 (순서대로 부르면 후보 수만큼 느려져요)
    with ThreadPoolExecutor(max_workers=MAX_CANDIDATES) as pool:
        walks = list(pool.map(lambda p: _round_trip(stop, p, cache), nearest))
    stay = stay_seconds(todo)
    candidates = sorted(
        ({"place_type": p["place_type"], "name": p["name"], "address": p["address"], "lng": p["lng"], "lat": p["lat"],
          "round_trip_walk_seconds": walk, "stay_seconds": stay}
         for p, walk in zip(nearest, walks) if walk is not None),
        key=lambda c: c["round_trip_walk_seconds"],
    )
    if not candidates:
        return None
    return {**candidates[0], "candidates": candidates}


def _live_option(route: dict, origin: kakao.Coord, destination: kakao.Coord,
                 todos: list[dict], place_cache: dict, deadline: int | None = None) -> RouteOption | None:
    """deadline(도착 희망까지 남은 초)이 있고 출발까지 여유가 REALTIME_WINDOW_SECONDS보다 많으면
    실시간 도착을 부르지 않아요. 지금 오는 차는 그때 탈 차가 아니라서요 (호출 한도도 아껴요)."""
    legs = [leg for leg in route["legs"] if leg["type"] in TRANSIT_TYPES and leg["start"]]
    if not legs:
        return None
    first, last = legs[0], legs[-1]
    # 현재 좌표가 들어간 호출은 메모리에도 남기지 않아요 (PR #29 리뷰)
    first_walk = kakao.walk_seconds(origin, tuple(first["start"]), use_cache=False)
    last_walk = kakao.walk_seconds(tuple(last["end"] or last["start"]), destination)
    if first_walk is None or last_walk is None:
        # 도보 경로를 못 찾으면 카카오 총 시간에서 구간 시간을 뺀 나머지를 처음 도보로 봐요
        spare = max((route["kakao_total_seconds"] or 0) - route["moving_seconds"], 0)
        first_walk, last_walk = (first_walk if first_walk is not None else spare), (last_walk or 0)
    stop = tuple(first["start"])
    plain = first_walk + route["moving_seconds"] + last_walk
    far = deadline is not None and deadline - plain > REALTIME_WINDOW_SECONDS
    return RouteOption(
        timing=RouteTiming(route["moving_seconds"], first_walk, last_walk, [] if far else _vehicle_seconds(first),
                           is_subway=first["type"] == "SUBWAY"),
        card={"type": route["type"], "name": "·".join(first["vehicles"][:3]) or first["guidance"],
              "guidance": first["guidance"], "transfers": route["transfers"], "fare": route["fare_min"],
              "stops": first["stops"], "legs": _live_legs(route, origin, destination, first_walk, last_walk)},
        places={t["id"]: _near_place(t, stop, place_cache) for t in todos},
        leg=first,
    )


def _missed(option: RouteOption, todos: list[dict], importance: str | None) -> int:
    """이 경로에서 넣지 못한 할 일 수 (importance가 있으면 그 중요도만)."""
    included = {d.todo_id for d in option.result.decisions if d.status == "included"}
    return sum(1 for t in todos if (importance is None or t["importance"] == importance) and t["id"] not in included)


def _arrive_by(schedule: dict) -> datetime:
    arrive_by = datetime.fromisoformat(schedule["arrive_by"])
    return arrive_by if arrive_by.tzinfo else arrive_by.replace(tzinfo=KST)


def _pick_schedule(user_id: str, schedule_id: int | None, now: datetime) -> dict:
    """schedule_id가 있으면 그 일정, 없으면 지금 이후 가장 가까운 일정이에요. 지난 일정은 고르지 않아요."""
    if schedule_id is not None:
        schedule = repo.get_schedule(schedule_id, user_id)
        if schedule is None:
            raise PlanError(404, "not_found", f"일정 {schedule_id} 없음")
        return schedule
    upcoming = [s for s in repo.list_schedules(user_id) if _arrive_by(s) > now]
    if not upcoming:
        raise PlanError(404, "not_found", "다가오는 일정이 없어요")
    return min(upcoming, key=_arrive_by)


def plan_live(user_id: str, origin: kakao.Coord, schedule_id: int | None = None,
              todo_ids: list[int] | None = None, now: datetime | None = None,
              destination: dict | None = None) -> dict:
    """실시간 계획. origin은 (경도, 위도)이고 저장하지 않아요.

    destination({name, lng, lat})이 있으면 일정 없이 지금 출발 기준으로 계산해요 (홈 검색창).
    이때 할 일은 todo_ids로 고른 것만 넣어요 (없으면 할 일 없이 길만 찾아요).
    없으면 일정(schedule_id, 없으면 가장 가까운 일정)의 도착 희망 시각에서 거꾸로 계산해요.

    카카오 경로 최대 3개를 계산하고 할 일을 잘 넣는 경로부터 보여 줘요. 할 일 상태는 첫 번째 경로 기준이에요.
    """
    now = now or datetime.now(KST).replace(microsecond=0)
    if destination is not None:
        dest = (destination["lng"], destination["lat"])
        arrive_by = None
        deadline = NOW_TRIP_DEADLINE_SECONDS
        todo_ids = todo_ids or []
        schedule_out = {"destination": {"name": destination.get("name") or "목적지", "lng": dest[0], "lat": dest[1]},
                        "arrive_by": None, "prep_minutes": 0}
    else:
        schedule = _pick_schedule(user_id, schedule_id, now)
        dest = (schedule["destination_lng"], schedule["destination_lat"])
        arrive_by = _arrive_by(schedule)
        deadline = int((arrive_by - now).total_seconds())
        schedule_out = {"destination": {"name": schedule["destination"], "lng": dest[0], "lat": dest[1]},
                        "arrive_by": arrive_by.isoformat(), "prep_minutes": schedule["prep_minutes"]}

    todos = [t for t in _todos(user_id, todo_ids) if t["place_types"]]
    try:
        routes = kakao.transit_routes(origin, dest, use_cache=False)
        place_cache: dict = {}
        options = [o for r in routes[:MAX_ROUTES]
                   if (o := _live_option(r, origin, dest, todos, place_cache,
                                         deadline if arrive_by else None))]
    except kakao.KakaoError as e:
        raise PlanError(502, "upstream_error", str(e)) from None
    if not options:
        raise PlanError(404, "no_route", "대중교통 경로를 찾지 못했어요")

    for option in options:
        option.result = _decide(option, todos, deadline)
        _set_times(option, now, arrive_by)
    # 필수 할 일을 넣을 수 있는 경로 → 할 일을 많이 넣는 경로 → 빨리 도착하는 경로 순이에요
    options.sort(key=lambda o: (_missed(o, todos, "필수"), _missed(o, todos, None), o.result.total_seconds))
    # 이동 중 질문(#59)이 이 경로로 답할 수 있게 1위 경로를 기억해요 (현재 좌표는 넣지 않아요)
    best = options[0]
    summary = [{"rank": i, "name": o.card["name"], "type": o.card["type"], "transfers": o.card["transfers"],
                "fare": o.card.get("fare"),
                "total_min": travel_minutes_from_seconds(o.result.total_seconds),
                "depart_at": o.times["depart_at"].isoformat(),
                "arrive_at": o.times["arrive_at"].isoformat()}
               for i, o in enumerate(options, 1)]
    live.remember(user_id, live.LivePlan(
        planned_at=now, arrive_by=arrive_by or now + timedelta(seconds=NOW_TRIP_DEADLINE_SECONDS),
        leg=best.leg, timing=best.timing, places=dict(best.places), routes=summary,
        basis=best.times["basis"], depart_at=best.times["depart_at"], total_seconds=best.result.total_seconds,
        has_target=arrive_by is not None))
    return _response(user_id, todos, options, now, schedule_out, "근처에서 찾지 못했어요")
