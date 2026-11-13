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
from app.services import demo, live, llm, planner, rules, trip
from app.services.planner import ACTIVE, KST, STATUS, _demo_place
from app.services.stopover import DEFAULT_BUFFER_SECONDS, StopCandidate, decide_stops
from app.services.timecalc import travel_minutes_from_seconds, wait_minutes_from_seconds

log = logging.getLogger(__name__)

NOT_READY_ANSWER = "실시간 계산은 아직 준비 중이에요. 시연 모드에서 확인해 주세요."
NO_PLAN_ANSWER = "먼저 길찾기에서 경로를 추천받아 주세요. 그 경로로 계산해 드릴게요."
# 새벽처럼 운행하지 않는 시간이거나, 마을버스처럼 서울시 API가 실시간을 주지 않는 노선이에요 (11/13)
NO_ARRIVAL_ANSWER = ("지금은 {label} 실시간 도착 정보가 없어요. "
                     "운행 시간이 아니거나, 실시간 정보를 주지 않는 노선(마을버스 등)일 수 있어요.")
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
    return f"{dt.hour}시" if dt.minute == 0 else f"{dt.hour}시 {dt.minute}분"


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


def _stop_text(item: dict, state: dict) -> str:
    """들르기로 저장할 할 일 이름. 한 질문에 들를 곳이 여러 개면 장소 종류로 나눠 이름 붙여요."""
    if item.get("todo_text"):
        return item["todo_text"]
    if state.get("stopovers", 1) > 1 and item["place_types"]:
        return f"{item['place_types'][0]} 들르기"
    # AI 출력에는 들르기 할 일 이름이 없어서 문장에서 다듬어요 ("아 이어폰 사야 돼" → "이어폰 사기")
    return rules.todo_text(state["text"])


def _judge_stop(timing, included: list, place: dict, state: dict, deadline: int):
    """이미 넣은 할 일 + 이 질문에서 앞서 물은 들를 곳 + 새 장소를 함께 판단해요.

    "편의점 들렀다가 약국도 갈 수 있어?" → 편의점을 먼저 넣고, 약국은 편의점과 함께 되는지 봐요.
    """
    earlier = state.setdefault("new_stops", [])
    known = included + earlier
    same = [c.todo_id for c, p in known if p["name"] == place["name"]]
    new = StopCandidate(-(len(earlier) + 1), "필수", place["round_trip_walk_seconds"], place["stay_seconds"])
    result = decide_stops(timing, [c for c, _ in known] + ([] if same else [new]), deadline)
    if not same:
        earlier.append((new, place))
    target = same[0] if same else new.todo_id
    decision = next(d for d in result.decisions if d.todo_id == target)
    state["stop_final"] = result  # 한 질문에 두 곳이면 마지막 판단이 둘을 함께 본 최종 결과예요
    return result, decision


def _short_answer(place: dict, state: dict) -> str:
    """들를 시간이 없을 때. 한 질문에 들를 곳이 여러 개면 어느 곳인지 이름을 넣어요."""
    if state.get("stopovers", 1) > 1:
        return f"{place['name']}까지 들르기엔 시간이 부족해요. 도착한 뒤에 들르는 걸 추천해요."
    return "시간이 부족해요. 도착한 뒤에 들르는 걸 추천해요."


def _remember_todo(state: dict, item: dict, decision, place: dict, now) -> None:
    todo = {"text": _stop_text(item, state), "place_types": item["place_types"], "importance": "필수",
            "status": STATUS[decision.status], "source": "질문"}
    state["todo"] = todo
    state.setdefault("todos", []).append(todo)
    state.setdefault("stop_refs", []).append((decision.todo_id, place["name"]))
    state["stop_now"] = now


def _combine_stops(state: dict, results: list[dict], answers: list[str], intents: list[dict]) -> list[str]:
    """한 질문에 들를 곳이 두 군데 이상이면, 마지막(둘을 함께 본) 판단 하나로 답을 합쳐요.

    장소마다 따로 답하면 "편의점 최대 8분, 약국 최대 11분"처럼 서로 다른 버스 기준 숫자가 섞여 헷갈려요.
    저장할 할 일 상태와 결과(feasible, max_stay_min, board_at)도 최종 판단으로 맞춰요.
    """
    final, refs = state.get("stop_final"), state.get("stop_refs", [])
    if state["stopovers"] < 2 or final is None or len(refs) < 2:
        return answers
    status = {d.todo_id: d.status for d in final.decisions}
    ok_names, no_names = [], []
    for todo, (stop_id, name) in zip(state["todos"], refs):
        todo["status"] = STATUS[status.get(stop_id, "excluded")]
        (ok_names if status.get(stop_id) == "included" else no_names).append(name)
    now = state["stop_now"]
    board_at = now + timedelta(seconds=final.board_seconds) if final.board_seconds is not None else None
    max_stay = wait_minutes_from_seconds(final.max_stay_seconds) if final.max_stay_seconds is not None else None
    for r in results:
        if r.get("intent") == "stopover_check" and r.get("place"):
            ok = r["place"]["name"] in ok_names
            r.update(feasible=ok, max_stay_min=max_stay if ok else None,
                     board_at=board_at.isoformat() if ok and board_at else None)

    def both(names):
        return names[0] if len(names) == 1 else ", ".join(names[:-2] + [f"{_josa(names[-2], '과와')} {names[-1]}"])
    if not no_names:
        combined = f"{both(ok_names)}에 모두 들를 수 있어요."
        if final.board_seconds is None and state.get("stop_depart"):
            combined += f" {_hhmm(state['stop_depart'])}에 출발하면 돼요."
        elif board_at:
            combined += f" {_hhmm(board_at)} 차를 타면 되고"
            combined += f", 여유는 최대 {max_stay}분이에요." if max_stay is not None else "요."
    elif ok_names:
        combined = f"{both(ok_names)}에는 들를 수 있지만, {both(no_names)}까지 들르기엔 시간이 부족해요."
    else:
        combined = f"{both(no_names)}에 모두 들르기엔 시간이 부족해요. 도착한 뒤에 들르는 걸 추천해요."
    # 들르기 답들을 첫 들르기 자리에 합친 답 하나로 바꿔요
    out, placed = [], False
    for item, answer in zip(intents, answers):
        if item["intent"] == "stopover_check":
            if not placed:
                out.append(combined)
                placed = True
        else:
            out.append(answer)
    return out


def _stopover_check(item: dict, state: dict) -> tuple[dict, str]:
    places = {p["place_type"]: p for p in demo.scenario()["places"]}
    place = next((places[t] for t in item["place_types"] if t in places), None)
    if place is None:
        kind = item["place_types"][0]
        return ({"intent": "stopover_check", "feasible": False, "place": None, "max_stay_min": None, "board_at": None},
                f"시연 지역에서는 {_josa(kind, '을를')} 찾지 못했어요.")
    # 이미 들르기로 한 장소면 다시 더하지 않아요 (이어폰을 넣은 뒤 "편의점 들러도 돼?")
    result, decision = _judge_stop(demo.route_timing(state["elapsed"]), _included(state["user_id"]), place, state,
                                   demo.deadline_seconds(state["elapsed"]))
    feasible = decision.status == "included"
    now = demo.current_time(state["elapsed"])
    out = {
        "intent": "stopover_check",
        "feasible": feasible,
        "place": {"name": place["name"], "address": place["address"]},
        "max_stay_min": wait_minutes_from_seconds(result.max_stay_seconds) if feasible and result.max_stay_seconds is not None else None,
        "board_at": (now + timedelta(seconds=result.board_seconds)).isoformat() if feasible and result.board_seconds is not None else None,
    }
    _remember_todo(state, item, decision, place, now)
    if feasible:
        return out, f"{place['name']}에 들를 수 있어요. 최대 {out['max_stay_min']}분 있을 수 있어요."
    return out, _short_answer(place, state)


def _late_answer(delay, board_at, arrive_at, on_time: bool | None) -> str:
    """늦어짐 답변. delay가 None이면 차를 놓친 경우, 0이면 "지금 출발하면 늦어?" (11/12)."""
    when = "지금 차를 놓쳤다면" if delay is None else "지금 출발하면" if delay == 0 else f"{delay}분 늦으면"
    if board_at is None:
        return f"{when} 탈 수 있는 차가 없어요."
    answer = f"{when} {_hhmm(board_at)} 차를 타고 {_hhmm(arrive_at)}에 도착해요."
    if on_time is False:
        return answer + " 도착 희망 시각보다 늦어요."
    return answer + (" 늦지 않아요." if delay == 0 and on_time else "")


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
    return out, _late_answer(delay, board_at, arrive_at, on_time)


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
        elif action == "done":  # "우유는 샀어" (11/12)
            repo.update_todo(todo["id"], state["user_id"], status="완료")
        else:
            repo.update_todo(todo["id"], state["user_id"], importance="필수" if action == "raise" else "선택")
    words = {"delete": "이번엔 뺄게요", "done": "완료로 표시할게요", "raise": "필수로 바꿀게요", "lower": "선택으로 바꿀게요"}
    return {"intent": "change_todo", "todo_id": todo["id"], "action": action}, f"{_josa(todo['text'], '은는')} {words.get(action, '바꿀게요')}."


# AI 답변 문장(#37). 11/12부터 모든 질문 종류에 써요 (현장 평가에서 대화가 자연스럽게 느껴지도록).
# 대신 코드가 만든 기본 답변을 AI에 "초안"으로 주고, AI 문장이 아래 검사를 통과할 때만 써요.
#   1) 숫자: 계산 결과와 초안에 있는 숫자만 (llm.numbers_match)
#   2) 경고 유지: 시간이 부족하거나 늦는 결과면 "부족해요·늦어요·어려워요·없어요·못 찾았어요" 같은 말이 있어야 해요
#   3) 하지 않은 일 금지: 할 일 변경이 아닌데 "삭제했·변경했·예약…"을 말하면 안 돼요 (11/11 측정에서 발견)
#   4) 길이: 200자 이내
# 하나라도 걸리면 코드가 만든 기본 답변을 그대로 보여 줘요.
AI_SENTENCE_INTENTS = {"next_vehicle", "stopover_check", "running_late", "time_left",
                       "place_info", "change_route", "change_todo", "unsupported"}
# "늦으셔도 도착할 수 있어요"처럼 경고를 뒤집는 표현은 통과하지 않게, 경고로 끝나는 말만 셉니다
WARNING_WORDS = ("부족", "늦어", "늦게", "늦습", "늦는", "늦을 거", "어려", "어렵", "없어", "없습", "없는", "없고",
                 "못 ", "못했", "못해", "못합", "못 찾")
FALSE_ACTION_WORDS = ("삭제했", "삭제하였", "변경했", "변경하였", "바꿨", "바꾸었", "예약", "취소했", "등록했", "추가했")
MAX_AI_ANSWER_CHARS = 200


def _needs_warning(result: dict) -> bool:
    return (result.get("feasible") is False or result.get("on_time") is False
            or (result.get("intent") == "running_late" and result.get("board_at") is None)
            or (result.get("intent") in ("place_info", "stopover_check") and "place" in result
                and result["place"] is None))


def _ai_sentence_ok(intents: list[dict], results: list[dict] | dict) -> bool:
    """AI 문장을 써도 되는 결과인지. 계산을 못 한 안내(계획 없음, 도착 정보 없음, 할 일 못 찾음)는 정해진 문장을 써요."""
    results = results if isinstance(results, list) else [results]
    if not results or any(i.get("intent") not in AI_SENTENCE_INTENTS for i in intents):
        return False
    for r in results:
        if r.get("intent") not in AI_SENTENCE_INTENTS or r.get("available") is False:
            return False
        if r["intent"] in ("next_vehicle", "time_left") and r.get("minutes") is None:
            return False
        if r["intent"] == "change_todo" and r.get("todo_id") is None:
            return False
    return True


def _ai_content_ok(answer: str, results: list[dict]) -> bool:
    """AI 문장 내용 검사 (숫자 검사는 llm.explain_result가 해요)."""
    if not answer or len(answer) > MAX_AI_ANSWER_CHARS:
        return False
    if any(_needs_warning(r) for r in results) and not any(w in answer for w in WARNING_WORDS):
        return False
    if not any(r.get("intent") == "change_todo" for r in results) and any(w in answer for w in FALSE_ACTION_WORDS):
        return False
    return True


# ---------- 질문 종류별 계산 (실제 모드, #59) ----------
def _now() -> datetime:
    return datetime.now(KST).replace(microsecond=0)


def _live_context(state: dict):
    """(계획, 지금, 출발 뒤 걸은 초, 실시간 차 도착 초). 계획이 없으면 None.

    출발 시각(depart_at)이 지났으면 그만큼 정류장으로 걸어갔다고 봐요 (현재 위치를 다시 받지 않아서 추정).
    도착 시각에서 거꾸로 계산한 계획인데 출발이 아직 멀면, 지금 오는 차는 탈 차가 아니라서 실시간을 부르지 않아요.
    """
    now = _now()
    plan = live.recall(state["user_id"], now)
    if plan is None:
        return None
    walked = max(int((now - (plan.depart_at or plan.planned_at)).total_seconds()), 0)
    vehicles = [] if _departure_far(plan, now) else planner._vehicle_seconds(plan.leg)
    return plan, now, walked, vehicles


def _departure_far(plan: live.LivePlan, now: datetime) -> bool:
    return (plan.basis == "arrive_by" and plan.depart_at is not None
            and (plan.depart_at - now).total_seconds() > planner.REALTIME_WINDOW_SECONDS)


def _depart_for(plan: live.LivePlan, now: datetime, total_seconds: int) -> datetime:
    """실시간 차 없이, 도착 희망 5분 전에 닿으려면 늦어도 출발해야 하는 시각 (지났으면 지금)."""
    return max(now, plan.arrive_by - timedelta(seconds=planner.ARRIVE_MARGIN_SECONDS + total_seconds))


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
        now = ctx[1]
        if _departure_far(plan, now):
            result["depart_at"] = plan.depart_at.isoformat()
            return result, (f"{_josa(label, '은는')} {_hhmm(plan.depart_at)}에 출발하면 타요. "
                            "출발 30분 전부터 실시간 도착을 알려 드릴게요.")
        return result, NO_ARRIVAL_ANSWER.format(label=label)
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
        # 실시간 차가 없으면 계획한 출발 시각으로 답해요 (도착 시각에서 거꾸로 계산한 값)
        if plan.depart_at and plan.depart_at > now:
            minutes = wait_minutes_from_seconds(int((plan.depart_at - now).total_seconds()))
            return ({"intent": "time_left", "minutes": minutes, "leave_by": plan.depart_at.isoformat()},
                    f"{_hhmm(plan.depart_at)}에 출발하면 돼요. {minutes}분 남았어요.")
        if not plan.has_target:
            return {"intent": "time_left", "minutes": None, "leave_by": None}, NO_ARRIVAL_ANSWER.format(label=label)
        return ({"intent": "time_left", "minutes": 0, "leave_by": now.isoformat()}, "지금 바로 출발해야 해요.")
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
    stop = tuple(plan.leg["start"])
    place = planner._near_place({"place_types": item["place_types"]}, stop, {}) if item["place_types"] else None
    if place is None:
        kind = item["place_types"][0] if item["place_types"] else "들를 곳"
        return ({"intent": "stopover_check", "feasible": False, "place": None, "max_stay_min": None, "board_at": None},
                f"정류장 근처에서 {_josa(kind, '을를')} 찾지 못했어요.")
    timing = replace(plan.timing, first_walk_seconds=max(plan.timing.first_walk_seconds - elapsed, 0),
                     vehicle_seconds=vehicles)
    deadline = int((plan.arrive_by - now).total_seconds())
    result, decision = _judge_stop(timing, _live_included(plan, state["user_id"]), place, state, deadline)
    feasible = decision.status == "included"
    out = {
        "intent": "stopover_check",
        "feasible": feasible,
        "place": {"name": place["name"], "address": place["address"]},
        "max_stay_min": wait_minutes_from_seconds(result.max_stay_seconds) if feasible and result.max_stay_seconds is not None else None,
        "board_at": (now + timedelta(seconds=result.board_seconds)).isoformat() if feasible and result.board_seconds is not None else None,
    }
    _remember_todo(state, item, decision, place, now)
    if feasible and not vehicles and plan.has_target:
        # 실시간 차가 없으면(출발이 멀거나 운행 전) 들르는 만큼 일찍 나가면 돼요
        depart = _depart_for(plan, now, result.total_seconds)
        out["depart_at"] = depart.isoformat()
        state["stop_depart"] = depart
        return out, f"{place['name']}에 들를 수 있어요. {_hhmm(depart)}에 출발하면 돼요."
    if feasible:
        if out["max_stay_min"] is None:
            return out, f"{place['name']}에 들를 수 있어요."
        return out, f"{place['name']}에 들를 수 있어요. 최대 {out['max_stay_min']}분 있을 수 있어요."
    return out, _short_answer(place, state)


def _live_running_late(item: dict, state: dict) -> tuple[dict, str]:
    """늦는 만큼 시각을 미뤄 다시 계산해요. 분이 없으면("버스 하나 놓쳤어") 지금 차를 놓친 것으로 봐요."""
    ctx = _live_context(state)
    if ctx is None:
        return _no_plan("running_late")
    plan, now, elapsed, vehicles = ctx
    delay = item.get("delay_minutes")
    if not vehicles:
        return _late_without_realtime(plan, now, delay)
    shift = vehicles[0] + 1 if delay is None else delay * 60
    later = now + timedelta(seconds=shift)
    included = [c for c, _ in _live_included(plan, state["user_id"])]
    timing = replace(plan.timing, first_walk_seconds=max(plan.timing.first_walk_seconds - elapsed, 0),
                     vehicle_seconds=[v - shift for v in vehicles if v - shift >= 0])
    deadline = int((plan.arrive_by - later).total_seconds())
    result = decide_stops(timing, included, deadline)
    arrive_at = later + timedelta(seconds=result.total_seconds)
    board_at = None if result.board_seconds is None else later + timedelta(seconds=result.board_seconds)
    on_time = result.total_seconds <= deadline if plan.has_target else None
    out = {"intent": "running_late", "delay_minutes": delay, "missed": delay is None, "on_time": on_time,
           "board_at": board_at and board_at.isoformat(), "arrive_at": arrive_at.isoformat()}
    return out, _late_answer(delay, board_at, arrive_at, on_time)


def _late_without_realtime(plan: live.LivePlan, now: datetime, delay: int | None) -> tuple[dict, str]:
    """실시간 차 없이 늦어짐 계산. "N분 늦게"는 계획한 출발 시각 기준, "지금 출발하면"은 지금 기준이에요."""
    if delay is None:  # "버스 놓쳤어"인데 다음 차를 모르면 추측하지 않아요
        return ({"intent": "running_late", "available": False, "missed": True},
                "지금은 다음 차 정보를 알 수 없어요. 실시간 도착 정보가 없어요.")
    base = now if delay == 0 else max(now, plan.depart_at or now)
    start = base + timedelta(minutes=delay)
    arrive = start + timedelta(seconds=plan.total_seconds)
    on_time = arrive <= plan.arrive_by if plan.has_target else None
    out = {"intent": "running_late", "delay_minutes": delay, "missed": False, "on_time": on_time,
           "depart_at": start.isoformat(), "board_at": None, "arrive_at": arrive.isoformat()}
    when = "지금 출발하면" if delay == 0 else f"{delay}분 늦게 출발하면"
    answer = f"{when} {_hhmm(start)}에 나가서 {_hhmm(arrive)}에 도착해요."
    if on_time is False:
        answer += " 도착 희망 시각보다 늦어요."
    elif on_time and delay == 0:
        answer += " 늦지 않아요."
    return out, answer


def _live_included(plan: live.LivePlan, user_id: str) -> list[tuple[StopCandidate, dict]]:
    """계획한 경로에 이미 넣은(포함) 할 일과 그 장소."""
    included_ids = {t["id"] for t in repo.list_todos(user_id, status="포함")}
    return [(StopCandidate(tid, "필수", p["round_trip_walk_seconds"], p["stay_seconds"]), p)
            for tid, p in plan.places.items() if p and tid in included_ids]


def _live_place_info(item: dict, state: dict) -> tuple[dict, str]:
    """탑승 정류장 근처의 장소 (가까운 순 최대 3곳). 종류가 없으면 이미 넣은 할 일의 장소를 알려요."""
    ctx = _live_context(state)
    if ctx is None:
        return _no_plan("place_info")
    plan = ctx[0]
    if item["place_types"]:
        found = planner._near_place({"place_types": item["place_types"]}, tuple(plan.leg["start"]), {})
        places = (found or {}).get("candidates", [])
    else:
        places = [p for _, p in _live_included(plan, state["user_id"])]
    if not places:
        kind = item["place_types"][0] if item["place_types"] else "들를 곳"
        return {"intent": "place_info", "place": None, "places": []}, f"정류장 근처에서 {_josa(kind, '을를')} 찾지 못했어요."
    out_places = [{"name": p["name"], "address": p["address"],
                   "round_trip_min": travel_minutes_from_seconds(p["round_trip_walk_seconds"])} for p in places]
    first = out_places[0]
    answer = f"가까운 곳은 {_copula(first['name'])}. ({first['address']}, 정류장에서 왕복 {first['round_trip_min']}분)"
    if len(out_places) > 1:
        answer += " 다른 곳: " + ", ".join(p["name"] for p in out_places[1:]) + "."
    return {"intent": "place_info", "place": {"name": first["name"], "address": first["address"]},
            "places": out_places}, answer


def _live_change_route(item: dict, state: dict) -> tuple[dict, str]:
    """추천한 다른 경로를 알려 줘요. 경로를 바꾸는 건 길찾기 화면에서 해요 (여기서 바꾸지 않아요)."""
    ctx = _live_context(state)
    if ctx is None:
        return _no_plan("change_route")
    routes = ctx[0].routes
    pref = item.get("preference")
    out = {"intent": "change_route", "route": routes[0]["name"] if routes else None, "preference": pref,
           "routes": routes}
    if len(routes) < 2:
        return out, "추천한 경로가 하나뿐이에요. 다른 경로는 없어요."
    if pref in PREFERENCE_KEYS:
        # 사용자가 말한 기준(환승 적은·빠른·싼)으로 가장 좋은 경로를 알려 줘요. 같으면 추천 순서
        key, word = PREFERENCE_KEYS[pref]
        best = min(routes, key=lambda r: (r.get(key) is None, r.get(key) or 0, r["rank"]))
        if best["rank"] == 1:
            return out, f"지금 추천한 {_route_name(best)} 경로가 {word} 경로예요."
        return out, (f"{word} 경로는 {_route_name(best)}({_route_detail(best)})예요. 길찾기에서 골라 주세요.")
    parts = [f"{_route_name(r)}({_route_detail(r)})" for r in routes[1:]]
    return out, f"다른 경로는 {', '.join(parts)}이 있어요. 길찾기에서 골라 주세요."


PREFERENCE_KEYS = {"transfer": ("transfers", "환승이 가장 적은"), "time": ("total_min", "가장 빠른"),
                   "fare": ("fare", "요금이 가장 싼")}


def _route_name(r: dict) -> str:
    return f"{r['name']}번" if r["name"].isdigit() else r["name"]


def _route_detail(r: dict) -> str:
    detail = f"{r['total_min']}분, 환승 {r['transfers']}번"
    return detail + (f", {r['fare']:,}원" if r.get("fare") else "")


LIVE_HANDLERS = {
    "next_vehicle": _live_next_vehicle,
    "stopover_check": _live_stopover_check,
    "running_late": _live_running_late,
    "time_left": _live_time_left,
    "place_info": _live_place_info,
    "change_route": _live_change_route,
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


def ask(user_id: str, text: str, use_demo: bool, explain_with_ai: bool | None = None,
        trip_context: trip.TripIn | None = None) -> dict:
    """질문을 분류하고 순서대로 계산해 답해요. 질문과 답변은 messages에 저장해요 (demo 제외).

    trip_context: 이동 중이면 지금 단계와 시각 (11/13). 남은 시간·다음 차·늦어짐은 이 값으로 답해요."""
    # demo는 부스에서 여러 사람이 함께 써서, 앞사람 질문이 섞이지 않게 기록도 이전 대화도 쓰지 않아요
    keep_history = user_id != DEMO_USER_ID
    history = repo.recent_messages(user_id) if keep_history else []
    classified, engine = _with_fallback(lambda t: _classify(t, history), rules.classify_question, text)
    classified = rules.ask_delay_if_unknown(classified, text)
    intents = classified["intents"]
    if keep_history:
        repo.add_message(user_id, "user", text, intents)

    result, results, answers = None, [], []
    used_trip = False
    state = {"user_id": user_id, "text": text, "elapsed": 0, "todo": None, "todos": [],
             "stopovers": sum(i["intent"] == "stopover_check" for i in intents)}
    if classified["needs_confirm"]:
        answers.append(classified["question"])
    else:
        for item in intents:
            name = item["intent"]
            by_trip = trip.answer(item, trip_context, text) if trip_context is not None else None
            if by_trip is not None:
                (result, answer), used_trip = by_trip, True
            elif name == "unsupported":
                result, answer = {"intent": "unsupported"}, UNSUPPORTED_ANSWER
            elif name in NEEDS_TRANSIT and not use_demo:
                if name in LIVE_HANDLERS:
                    result, answer = LIVE_HANDLERS[name](item, state)
                else:
                    result, answer = {"intent": name, "available": False}, NOT_READY_ANSWER
            else:
                result, answer = HANDLERS[name](item, state)
            results.append(result)
            answers.append(answer)

    if not classified["needs_confirm"]:
        answers = _combine_stops(state, results, answers, intents)

    # 들르기 질문으로 생긴 할 일 저장. 한 질문에 두 곳이면 둘 다 (todo는 마지막 것, 예전 앱 호환)
    todos = state["todos"]
    if user_id != DEMO_USER_ID:
        todos = [{**t, "id": repo.add_todo(user_id, t["text"], t["place_types"], status=t["status"],
                                           source="질문")["id"]} for t in todos]
    todo = todos[-1] if todos else None
    answer = " ".join(dict.fromkeys(answers))

    # #37: AI 답변 문장 생성 및 숫자 대조 검증 (기존 코드 안전망 유지)
    should_explain = explain_with_ai if explain_with_ai is not None else config.EXPLAIN_WITH_AI
    # 이동 중 단계 답변은 앱 시각으로 만든 짧은 문장이라 AI로 다듬지 않아요
    if (should_explain and not used_trip and _ai_ready() and results and not classified["needs_confirm"]
            and _ai_sentence_ok(intents, results)):
        # 질문이 여러 개면 결과 목록을 함께 줘서 AI가 하나의 답으로 이어 말하게 해요
        answer = llm.explain_result(text, results if len(results) > 1 else results[0], answer,
                                    check=lambda a: _ai_content_ok(a, results))

    if keep_history:
        repo.add_message(user_id, "assistant", answer)
    return {
        "intents": intents,
        "needs_confirm": classified["needs_confirm"],
        "question": classified["question"],
        "result": None if classified["needs_confirm"] else result,
        "answer": answer,
        "todo": todo,
        "todos": todos,
        "engine": engine,
    }
