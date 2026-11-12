"""② 이해 + ⑦ 대화형 질문 (할 일 33·37·38번).

- understand_todo: 할 일 문장 → 장소 종류 (/api/tasks/parse)
- ask: 질문 분류 → 질문 종류별 계산 → 답변 (/api/ask)

AI 키가 없거나 AI 호출이 실패하면 키워드 규칙(rules.py)으로 처리하고 engine="rule"로 알려요.
시연 모드(demo=true)는 시나리오 고정값으로, 실제 모드는 마지막 실시간 계획(live.py)의 경로로 계산해요.
실제 모드는 다음 차·들르기·남은 시간(#59)만 계산하고, 나머지 교통 질문은 아직 준비 중이라고 안내해요.
답변 문장의 숫자는 모두 코드가 계산한 값이에요.
"""
import logging
from dataclasses import replace
from datetime import datetime, timedelta

from app import config
from app.db import repository as repo
from app.db.database import DEMO_USER_ID
from app.services import demo, live, llm, planner, rules
from app.services.planner import ACTIVE, KST, STATUS, _demo_place
from app.services.stopover import DEFAULT_BUFFER_SECONDS, StopCandidate, decide_stops
from app.services.timecalc import wait_minutes_from_seconds

log = logging.getLogger(__name__)

NOT_READY_ANSWER = "실시간 계산은 아직 준비 중이에요. 시연 모드에서 확인해 주세요."
NO_PLAN_ANSWER = "먼저 길찾기에서 경로를 추천받아 주세요. 그 경로로 계산해 드릴게요."
NO_ARRIVAL_ANSWER = "지금은 실시간 도착 정보를 찾지 못했어요."
UNSUPPORTED_ANSWER = "이동과 할 일에 관한 질문만 도와드릴 수 있어요."
NEEDS_TRANSIT = {"next_vehicle", "stopover_check", "running_late", "time_left", "place_info", "change_route"}


def _ai_ready() -> bool:
    return bool(config.OPENAI_API_KEY and config.LLM_MODEL)


def _with_fallback(ai_call, rule_call, text: str) -> tuple[dict, str]:
    if _ai_ready():
        try:
            return ai_call(text), "ai"
        except Exception as e:  # noqa: BLE001 - AI가 실패해도 답은 해야 해요
            log.warning("AI 호출 실패, 키워드 규칙으로 처리: %s", type(e).__name__)
    return rule_call(text), "rule"


def _broken(classified: dict) -> bool:
    """AI 출력 형식이 깨져서 질문 종류가 하나도 안 남고 기본 되묻기 문장이 된 경우."""
    return not classified["intents"] and classified["question"] == llm.DEFAULT_CONFIRM_QUESTION


def _classify(text: str, history: list[dict]) -> dict:
    out = llm.classify_question(text, history=history)
    if _broken(out):
        raise ValueError("AI 질문 분류 형식이 맞지 않아요")
    return out


def understand_todo(text: str) -> dict:
    out, engine = _with_fallback(llm.parse_todo, rules.parse_todo, text)
    return {**out, "engine": engine}


def _josa(word: str, pair: str) -> str:
    """받침에 맞는 조사. pair는 "은는", "을를", "이가"."""
    last = word[-1] if word else ""
    has_final = "가" <= last <= "힣" and (ord(last) - ord("가")) % 28 > 0
    return word + (pair[0] if has_final else pair[1])


def _copula(word: str) -> str:
    """'편의점이에요', '카페예요'"""
    return _josa(word, "은는")[:-1] + ("이에요" if _josa(word, "은는").endswith("은") else "예요")


# ---------- 질문 종류별 계산 (시연 모드) ----------
def _hhmm(dt) -> str:
    return f"{dt.hour}시 {dt.minute}분"


def _demo_route_arrival(elapsed: int) -> dict:
    data = demo.scenario()
    return next(a for a in demo.arrivals(data["stop"]["ars_id"], elapsed) if a["route"] == data["route"]["name"])


def _next_vehicle(item: dict, state: dict) -> tuple[dict, str]:
    a = _demo_route_arrival(state["elapsed"])
    first, second = (None if s is None else wait_minutes_from_seconds(s) for s in (a["first_seconds"], a["second_seconds"]))
    result = {"intent": "next_vehicle", "route": a["route"], "minutes": first, "next_minutes": second}
    if first is None:
        return result, f"{a['route']}번은 오늘 더 오지 않아요."
    answer = f"{a['route']}번이 {first}분 뒤에 와요."
    if second is not None:
        answer += f" 그다음 차는 {second}분 뒤예요."
    return result, answer


def _included(user_id: str) -> list[tuple[StopCandidate, dict]]:
    """이미 경로에 들어간 할 일과 그 장소. 새로 들를 곳은 이 뒤에 더해서 판단해요.

    demo 사용자는 할 일 상태를 저장하지 않아서, 시연 계획(/api/plan)에서 포함되는 할 일(이어폰)을 써요.
    그래야 같은 시연 안에서 /api/plan 과 /api/ask 의 답이 엇갈리지 않아요.
    """
    if user_id == DEMO_USER_ID:
        todos = [t for t in repo.list_todos(user_id) if t["status"] in ACTIVE]
    else:
        todos = repo.list_todos(user_id, status="포함")
    rows = []
    for todo in todos:
        place = _demo_place(todo)
        if place:
            rows.append((StopCandidate(todo["id"], todo["importance"], place["round_trip_walk_seconds"],
                                       place["stay_seconds"]), place))
    if user_id == DEMO_USER_ID:
        planned = decide_stops(demo.route_timing(), [c for c, _ in rows], demo.deadline_seconds())
        keep = {d.todo_id for d in planned.decisions if d.status == "included"}
        rows = [r for r in rows if r[0].todo_id in keep]
    return rows


def _stopover_check(item: dict, state: dict) -> tuple[dict, str]:
    places = {p["place_type"]: p for p in demo.scenario()["places"]}
    place = next((places[t] for t in item["place_types"] if t in places), None)
    # AI 출력에는 들르기 할 일 이름이 없어서 문장에서 다듬어요 ("아 이어폰 사야 돼" → "이어폰 사기")
    text = item.get("todo_text") or rules.todo_text(state["text"])
    if place is None:
        kind = item["place_types"][0]
        return ({"intent": "stopover_check", "feasible": False, "place": None, "max_stay_min": None, "board_at": None},
                f"시연 지역에서는 {_josa(kind, '을를')} 찾지 못했어요.")
    included = _included(state["user_id"])
    # 이미 들르기로 한 장소면 다시 더하지 않아요 (이어폰을 넣은 뒤 "편의점 들러도 돼?")
    same = [c.todo_id for c, p in included if p["name"] == place["name"]]
    new = StopCandidate(-1, "필수", place["round_trip_walk_seconds"], place["stay_seconds"])
    candidates = [c for c, _ in included] + ([] if same else [new])
    result = decide_stops(demo.route_timing(state["elapsed"]), candidates, demo.deadline_seconds(state["elapsed"]))
    target = same[0] if same else -1
    decision = next(d for d in result.decisions if d.todo_id == target)
    feasible = decision.status == "included"
    now = demo.current_time(state["elapsed"])
    out = {
        "intent": "stopover_check",
        "feasible": feasible,
        "place": {"name": place["name"], "address": place["address"]},
        "max_stay_min": wait_minutes_from_seconds(result.max_stay_seconds) if feasible and result.max_stay_seconds is not None else None,
        "board_at": (now + timedelta(seconds=result.board_seconds)).isoformat() if feasible and result.board_seconds is not None else None,
    }
    state["todo"] = {"text": text, "place_types": item["place_types"], "importance": "필수",
                     "status": STATUS[decision.status], "source": "질문"}
    if feasible:
        return out, f"{place['name']}에 들를 수 있어요. 최대 {out['max_stay_min']}분 있을 수 있어요."
    return out, "시간이 부족해요. 도착한 뒤에 들르는 걸 추천해요."


def _running_late(item: dict, state: dict) -> tuple[dict, str]:
    """늦은 시간만큼 지난 장면으로 다시 계산해요. 분이 없으면("버스 하나 놓쳤어") 지금 차를 놓친 것으로 봐요."""
    delay = item.get("delay_minutes")
    if delay is None:
        first = _demo_route_arrival(state["elapsed"])["first_seconds"]
        state["elapsed"] += 0 if first is None else first + 1
    else:
        state["elapsed"] += delay * 60
    result = decide_stops(demo.route_timing(state["elapsed"]), [c for c, _ in _included(state["user_id"])],
                          demo.deadline_seconds(state["elapsed"]))
    now = demo.current_time(state["elapsed"])
    arrive_at = now + timedelta(seconds=result.total_seconds)
    board_at = None if result.board_seconds is None else now + timedelta(seconds=result.board_seconds)
    on_time = result.total_seconds <= demo.deadline_seconds(state["elapsed"])
    out = {"intent": "running_late", "delay_minutes": delay, "missed": delay is None, "on_time": on_time,
           "board_at": board_at and board_at.isoformat(), "arrive_at": arrive_at.isoformat()}
    when = "지금 차를 놓쳤다면" if delay is None else f"{delay}분 늦으면"
    if board_at is None:
        return out, f"{when} 탈 수 있는 차가 없어요."
    answer = f"{when} {_hhmm(board_at)} 차를 타고 {_hhmm(arrive_at)}에 도착해요."
    return out, answer if on_time else answer + " 도착 희망 시각보다 늦어요."


def _time_left(item: dict, state: dict) -> tuple[dict, str]:
    a = _demo_route_arrival(state["elapsed"])
    if a["first_seconds"] is None:
        return {"intent": "time_left", "minutes": None, "leave_by": None}, f"{a['route']}번은 오늘 더 오지 않아요."
    # 차가 오는 시각이 아니라 여유를 두고 정류장에 있어야 하는 시각을 알려요
    seconds_left = max(a["first_seconds"] - DEFAULT_BUFFER_SECONDS, 0)
    minutes = wait_minutes_from_seconds(a["first_seconds"])
    leave_by = demo.current_time(state["elapsed"] + seconds_left)
    return ({"intent": "time_left", "minutes": wait_minutes_from_seconds(seconds_left), "leave_by": leave_by.isoformat()},
            f"{a['route']}번이 {minutes}분 뒤에 와요. {_hhmm(leave_by)}까지 정류장에 있으면 돼요.")


def _place_info(item: dict, state: dict) -> tuple[dict, str]:
    places = {p["place_type"]: p for p in demo.scenario()["places"]}
    place = next((places[t] for t in item["place_types"] if t in places), None)
    if place is None:
        return {"intent": "place_info", "place": None}, f"시연 지역에서는 {_josa(item['place_types'][0], '을를')} 찾지 못했어요."
    return ({"intent": "place_info", "place": {"name": place["name"], "address": place["address"]}},
            f"가까운 곳은 {_copula(place['name'])}. ({place['address']})")


def _change_route(item: dict, state: dict) -> tuple[dict, str]:
    route = demo.scenario()["route"]["name"]
    return {"intent": "change_route", "route": route}, f"시연 구간에는 {route}번 경로 하나만 있어요."


def _change_todo(item: dict, state: dict) -> tuple[dict, str]:
    action = item.get("action") or "delete"
    target = item.get("todo_text") or ""
    todos = repo.list_todos(state["user_id"])
    todo = next((t for t in todos if target and (target in t["text"] or t["text"] in target)), None)
    if todo is None:
        return {"intent": "change_todo", "todo_id": None, "action": action}, "어떤 할 일인지 찾지 못했어요. 할 일 화면에서 바꿔 주세요."
    if state["user_id"] != DEMO_USER_ID:
        if action == "delete":
            repo.update_todo(todo["id"], state["user_id"], status="제외")
        else:
            repo.update_todo(todo["id"], state["user_id"], importance="필수" if action == "raise" else "선택")
    words = {"delete": "이번엔 뺄게요", "raise": "필수로 바꿀게요", "lower": "선택으로 바꿀게요"}
    return {"intent": "change_todo", "todo_id": todo["id"], "action": action}, f"{_josa(todo['text'], '은는')} {words.get(action, '바꿀게요')}."


# AI 답변 문장(#37)은 계산 결과를 그대로 말로 풀면 되는 질문에만 써요.
# 할 일 변경·경로 변경·장소 정보는 "삭제했어요", "바꿨어요"처럼 하지 않은 일을 말할 수 있어서 정해진 문장을 써요.
AI_SENTENCE_INTENTS = {"next_vehicle", "stopover_check", "time_left"}


def _ai_sentence_ok(intents: list[dict], result: dict) -> bool:
    """질문 종류가 하나이고 AI_SENTENCE_INTENTS 안에 있을 때만 AI 문장을 써요.
    질문이 두 개면 AI가 앞 질문의 답을 빠뜨려서 정해진 문장을 써요."""
    if len(intents) != 1 or intents[0].get("intent") not in AI_SENTENCE_INTENTS:
        return False
    if result.get("available") is False:  # 계산을 못 한 안내 문장은 그대로 써요 (실제 모드 계획 없음 등)
        return False
    return result.get("intent") in AI_SENTENCE_INTENTS


# ---------- 질문 종류별 계산 (실제 모드, #59) ----------
def _now() -> datetime:
    return datetime.now(KST).replace(microsecond=0)


def _live_context(state: dict):
    """(계획, 지금, 계획 뒤 지난 초, 실시간 차 도착 초). 계획이 없으면 None."""
    now = _now()
    plan = live.recall(state["user_id"], now)
    if plan is None:
        return None
    elapsed = int((now - plan.planned_at).total_seconds())
    return plan, now, elapsed, planner._vehicle_seconds(plan.leg)


def _route_label(leg: dict) -> tuple[str, str]:
    """(결과에 넣을 노선 이름, 답변에 쓸 이름). 버스 "2115" → "2115번", 지하철 "6호선" → "6호선"."""
    name = (leg.get("vehicles") or [""])[0] or leg.get("guidance", "")
    return name, f"{name}번" if leg["type"] == "BUS" and not name.endswith("번") else name


def _no_plan(name: str) -> tuple[dict, str]:
    return {"intent": name, "available": False}, NO_PLAN_ANSWER


def _live_next_vehicle(item: dict, state: dict) -> tuple[dict, str]:
    ctx = _live_context(state)
    if ctx is None:
        return _no_plan("next_vehicle")
    plan, _, _, vehicles = ctx
    route, label = _route_label(plan.leg)
    # 실시간 값 뒤로 배차 간격으로 추정한 차가 붙어 있어서, 두 번째 차는 추정일 수 있어요
    first = wait_minutes_from_seconds(vehicles[0]) if vehicles else None
    second = wait_minutes_from_seconds(vehicles[1]) if len(vehicles) > 1 else None
    result = {"intent": "next_vehicle", "route": route, "minutes": first, "next_minutes": second}
    if first is None:
        return result, NO_ARRIVAL_ANSWER
    answer = f"{_josa(label, '이가')} {first}분 뒤에 와요."
    if second is not None:
        answer += f" 그다음 차는 {second}분 뒤예요."
    return result, answer


def _live_time_left(item: dict, state: dict) -> tuple[dict, str]:
    ctx = _live_context(state)
    if ctx is None:
        return _no_plan("time_left")
    plan, now, _, vehicles = ctx
    _, label = _route_label(plan.leg)
    if not vehicles:
        return {"intent": "time_left", "minutes": None, "leave_by": None}, NO_ARRIVAL_ANSWER
    # 시연 모드와 같이, 여유를 두고 정류장에 있어야 하는 시각을 알려요
    seconds_left = max(vehicles[0] - DEFAULT_BUFFER_SECONDS, 0)
    leave_by = now + timedelta(seconds=seconds_left)
    return ({"intent": "time_left", "minutes": wait_minutes_from_seconds(seconds_left), "leave_by": leave_by.isoformat()},
            f"{_josa(label, '이가')} {wait_minutes_from_seconds(vehicles[0])}분 뒤에 와요. "
            f"{_hhmm(leave_by)}까지 정류장에 있으면 돼요.")


def _live_stopover_check(item: dict, state: dict) -> tuple[dict, str]:
    """계획한 경로의 탑승 정류장 근처에서 장소를 찾아, 이미 넣은 할 일과 함께 지금 시각 기준으로 다시 판단해요.

    계획 뒤에 지난 시간만큼 정류장까지 걸어갔다고 보고 처음 도보를 줄여요 (현재 위치를 다시 받지 않아서 추정이에요).
    """
    ctx = _live_context(state)
    if ctx is None:
        return _no_plan("stopover_check")
    plan, now, elapsed, vehicles = ctx
    text = item.get("todo_text") or rules.todo_text(state["text"])
    stop = tuple(plan.leg["start"])
    place = planner._near_place({"place_types": item["place_types"]}, stop, {}) if item["place_types"] else None
    if place is None:
        kind = item["place_types"][0] if item["place_types"] else "들를 곳"
        return ({"intent": "stopover_check", "feasible": False, "place": None, "max_stay_min": None, "board_at": None},
                f"정류장 근처에서 {_josa(kind, '을를')} 찾지 못했어요.")
    included_ids = {t["id"] for t in repo.list_todos(state["user_id"], status="포함")}
    included = [(StopCandidate(tid, "필수", p["round_trip_walk_seconds"], p["stay_seconds"]), p)
                for tid, p in plan.places.items() if p and tid in included_ids]
    same = [c.todo_id for c, p in included if p["name"] == place["name"]]
    new = StopCandidate(-1, "필수", place["round_trip_walk_seconds"], place["stay_seconds"])
    timing = replace(plan.timing, first_walk_seconds=max(plan.timing.first_walk_seconds - elapsed, 0),
                     vehicle_seconds=vehicles)
    deadline = int((plan.arrive_by - now).total_seconds())
    result = decide_stops(timing, [c for c, _ in included] + ([] if same else [new]), deadline)
    target = same[0] if same else -1
    decision = next(d for d in result.decisions if d.todo_id == target)
    feasible = decision.status == "included"
    out = {
        "intent": "stopover_check",
        "feasible": feasible,
        "place": {"name": place["name"], "address": place["address"]},
        "max_stay_min": wait_minutes_from_seconds(result.max_stay_seconds) if feasible and result.max_stay_seconds is not None else None,
        "board_at": (now + timedelta(seconds=result.board_seconds)).isoformat() if feasible and result.board_seconds is not None else None,
    }
    state["todo"] = {"text": text, "place_types": item["place_types"], "importance": "필수",
                     "status": STATUS[decision.status], "source": "질문"}
    if feasible:
        if out["max_stay_min"] is None:
            return out, f"{place['name']}에 들를 수 있어요."
        return out, f"{place['name']}에 들를 수 있어요. 최대 {out['max_stay_min']}분 있을 수 있어요."
    return out, "시간이 부족해요. 도착한 뒤에 들르는 걸 추천해요."


LIVE_HANDLERS = {
    "next_vehicle": _live_next_vehicle,
    "stopover_check": _live_stopover_check,
    "time_left": _live_time_left,
}


HANDLERS = {
    "next_vehicle": _next_vehicle,
    "stopover_check": _stopover_check,
    "running_late": _running_late,
    "time_left": _time_left,
    "place_info": _place_info,
    "change_route": _change_route,
    "change_todo": _change_todo,
}


def ask(user_id: str, text: str, use_demo: bool, explain_with_ai: bool | None = None) -> dict:
    """질문을 분류하고 순서대로 계산해 답해요. 질문과 답변은 messages에 저장해요 (demo 제외)."""
    # demo는 부스에서 여러 사람이 함께 써서, 앞사람 질문이 섞이지 않게 기록도 이전 대화도 쓰지 않아요
    keep_history = user_id != DEMO_USER_ID
    history = repo.recent_messages(user_id) if keep_history else []
    classified, engine = _with_fallback(lambda t: _classify(t, history), rules.classify_question, text)
    classified = rules.ask_delay_if_unknown(classified, text)
    intents = classified["intents"]
    if keep_history:
        repo.add_message(user_id, "user", text, intents)

    result, answers = None, []
    state = {"user_id": user_id, "text": text, "elapsed": 0, "todo": None}
    if classified["needs_confirm"]:
        answers.append(classified["question"])
    else:
        for item in intents:
            name = item["intent"]
            if name == "unsupported":
                result, answer = {"intent": "unsupported"}, UNSUPPORTED_ANSWER
            elif name in NEEDS_TRANSIT and not use_demo:
                if name in LIVE_HANDLERS:
                    result, answer = LIVE_HANDLERS[name](item, state)
                else:
                    result, answer = {"intent": name, "available": False}, NOT_READY_ANSWER
            else:
                result, answer = HANDLERS[name](item, state)
            answers.append(answer)

    todo = state["todo"]
    if todo and user_id != DEMO_USER_ID:
        saved = repo.add_todo(user_id, todo["text"], todo["place_types"], status=todo["status"], source="질문")
        todo = {**todo, "id": saved["id"]}
    answer = " ".join(dict.fromkeys(answers))

    # #37: AI 답변 문장 생성 및 숫자 대조 검증 (기존 코드 안전망 유지)
    should_explain = explain_with_ai if explain_with_ai is not None else config.EXPLAIN_WITH_AI
    if should_explain and _ai_ready() and result and not classified["needs_confirm"] and _ai_sentence_ok(intents, result):
        answer = llm.explain_result(text, result, answer)

    if keep_history:
        repo.add_message(user_id, "assistant", answer)
    return {
        "intents": intents,
        "needs_confirm": classified["needs_confirm"],
        "question": classified["question"],
        "result": None if classified["needs_confirm"] else result,
        "answer": answer,
        "todo": todo,
        "engine": engine,
    }
