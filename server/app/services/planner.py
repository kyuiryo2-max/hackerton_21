"""⑤ 추천: /api/plan 응답 만들기 (할 일 33번).

할 일(DB)과 경로·도착 정보를 경유 계산(stopover)에 넣고, 결과를 앱이 쓰는 모양으로 바꿔요.
지금은 시연 모드(data/demo/scenario.json)만 계산해요. 실시간 경로는 출발 위치가 정해지면 연결해요.

시간은 계산할 때 초, 응답할 때 분이에요.
이동·도보는 올림, 교통편까지 남은 시간과 최대 체류 시간은 내림해요. (늦지 않는 쪽)
"""
from datetime import timedelta

from app.db import repository as repo
from app.db.database import DEMO_USER_ID
from app.services import demo
from app.services.stopover import StopCandidate, decide_stops
from app.services.timecalc import travel_minutes_from_seconds, wait_minutes_from_seconds

# 계산 결과 → DB 상태 (api.md "할 일 상태·출처")
STATUS = {"included": "포함", "excluded": "제외", "ask": "대기"}
ASK_OPTIONS = ["이번엔 빼기", "늦더라도 들르기"]
ACTIVE = ("대기", "포함", "제외")  # 완료한 할 일은 다시 계산하지 않아요


class PlanError(Exception):
    def __init__(self, status: int, code: str, message: str):
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


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
    places = {p["place_type"]: p for p in demo.scenario()["places"]}
    return next((places[t] for t in todo["place_types"] if t in places), None)


def _explanation(route_name: str, included: list[dict], arrive_at) -> str:
    """AI 문장(#36)이 붙기 전까지 쓰는 정해진 문장. 숫자는 계산값만 써요."""
    time = f"{arrive_at.hour}시 {arrive_at.minute}분"
    if not included:
        return f"{route_name}번을 타면 {time}에 도착해요."
    names = ", ".join(t["text"] for t in included)
    return f"{route_name}번을 타면 {names}까지 하고 {time}에 도착해요."


def plan_demo(user_id: str, todo_ids: list[int] | None = None) -> dict:
    """시연 모드 계획. 시각·위치·일정·도착 정보는 시나리오 고정값이고 할 일은 DB에서 읽어요.

    demo 사용자가 아니면 계산한 상태(포함·제외·대기)를 할 일에 저장해요.
    부스에서 관객이 자기 할 일로 시연해 볼 때 쓰는 경로예요.
    """
    data = demo.scenario()
    todos = [t for t in _todos(user_id, todo_ids) if t["place_types"]]  # 들를 곳이 없는 할 일은 빼요
    places = {t["id"]: _demo_place(t) for t in todos}
    candidates = [
        StopCandidate(t["id"], t["importance"], places[t["id"]]["round_trip_walk_seconds"],
                      places[t["id"]]["stay_seconds"])
        for t in todos if places[t["id"]]
    ]
    route = demo.route_timing()
    result = decide_stops(route, candidates, demo.deadline_seconds())

    now = demo.current_time()
    arrive_at = now + timedelta(seconds=result.total_seconds)
    by_id = {t["id"]: t for t in todos}
    decided = {d.todo_id: d for d in result.decisions}

    todo_rows = []
    for todo_id in [d.todo_id for d in result.decisions] + [t["id"] for t in todos if not places[t["id"]]]:
        todo, place = by_id[todo_id], places[todo_id]
        decision = decided.get(todo_id)
        # 시연 지역에 장소가 없으면 계산을 못 한 것이라 저장하지 않고, 필수는 사라지지 않게 대기로 보여 줘요
        status = STATUS[decision.status] if decision else ("대기" if todo["importance"] == "필수" else "제외")
        row = {
            "todo_id": todo_id,
            "text": todo["text"],
            "importance": todo["importance"],
            "status": status,
            "place": place and {k: place[k] for k in ("place_type", "name", "address")},
            "detour_min": travel_minutes_from_seconds(place["round_trip_walk_seconds"]) if place else None,
            "reason": decision.reason if decision else "시연 지역에 없는 장소예요",
        }
        if decision and decision.status == "ask":
            row["options"] = ASK_OPTIONS
        todo_rows.append(row)
        if decision and user_id != DEMO_USER_ID:
            repo.update_todo(todo_id, user_id, status=status)

    route_info = data["route"]
    wait_seconds = (result.board_seconds or route.first_walk_seconds) - route.first_walk_seconds
    included = [by_id[d.todo_id] for d in result.decisions if d.status == "included"]
    return {
        "now": data["now"],
        "schedule": data["schedule"],
        "board_at": None if result.board_seconds is None
        else (now + timedelta(seconds=result.board_seconds)).isoformat(),
        "arrive_at": arrive_at.isoformat(),
        "routes": [{
            "rank": 1,
            "type": route_info["type"],
            "name": route_info["name"],
            "guidance": route_info["guidance"],
            "total_min": travel_minutes_from_seconds(result.total_seconds),
            "wait_min": wait_minutes_from_seconds(wait_seconds),
            "moving_min": travel_minutes_from_seconds(route.moving_seconds),
            "last_walk_min": travel_minutes_from_seconds(route.last_walk_seconds),
            "transfers": route_info["transfers"],
            "fare": route_info["fare_min"],
            "stops": route_info["stops"],
            "max_stay_min": None if result.max_stay_seconds is None
            else wait_minutes_from_seconds(result.max_stay_seconds),
            "has_realtime": result.has_realtime,
        }],
        "todos": todo_rows,
        "explanation": _explanation(route_info["name"], included, arrive_at),
    }
