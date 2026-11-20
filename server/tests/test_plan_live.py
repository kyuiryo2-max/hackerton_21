"""실시간 경로 계획 테스트. 카카오·서울시 호출은 실제 응답 샘플과 가짜 값으로 바꿔서 외부 호출이 없어요."""
import json
import sqlite3
from datetime import datetime, timedelta
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app import config
from app.services import assistant, kakao, planner, seoul_bus

SAMPLE = Path(__file__).resolve().parents[2] / "data" / "samples" / "kakao_transit.json"
ROUTES = kakao.parse_transit(json.loads(SAMPLE.read_text(encoding="utf-8")))  # 안암역 → 청량리역
ORIGIN = {"lat": 37.5861234, "lng": 127.0291234}  # 저장되지 않아야 하는 값
CU = {"name": "CU 안암역점", "address": "서울 성북구 고려대로 95", "lng": 127.0300, "lat": 37.5864}


@pytest.fixture()
def client(tmp_path, monkeypatch):
    monkeypatch.setattr("app.config.DATABASE_PATH", str(tmp_path / "test.db"))
    monkeypatch.setattr(config, "KAKAO_REST_API_KEY", "TEST")
    from app.main import app

    with TestClient(app) as c:
        yield c


@pytest.fixture()
def world(monkeypatch):
    """외부 API 대신 쓸 값. 테스트마다 바꿀 수 있어요."""
    w = {"routes": ROUTES, "bus": [600, 1200], "places": {"편의점": [CU]}}
    monkeypatch.setattr(planner.kakao, "transit_routes", lambda s, e, **kw: w["routes"])
    monkeypatch.setattr(planner.kakao, "walk_seconds", lambda s, e, via=None, **kw: 300 if via else 120)
    # 실제 모드 도보: 출발지 → 정류장 120초, 경유하면 출발지 → 장소 150초 + 장소 → 정류장 150초 (11/13)
    monkeypatch.setattr(planner.kakao, "walk_route", lambda s, e, via=None, **kw: (
        {"seconds": 300, "legs": [{"seconds": 150, "points": [list(s), [9.0, 9.0]]},
                                  {"seconds": 150, "points": [[9.0, 9.0], list(e)]}]} if via else
        {"seconds": 120, "legs": [{"seconds": 120, "points": [list(s), [5.0, 5.0], list(e)]}]}))
    monkeypatch.setattr(planner.places, "search_by_place_type",
                        lambda t, center, radius_m=300, size=1, **kw: w["places"].get(t, []))
    monkeypatch.setattr(planner.seoul_bus, "match_leg", lambda leg: {"arrival": {
        "first_seconds": w["bus"][0], "second_seconds": w["bus"][1], "interval_minutes": 10}})
    monkeypatch.setattr(planner.seoul_subway, "match_leg", lambda leg: {"trains": [{"seconds": 300}]})
    return w


# 기본 일정은 40분 뒤 도착: 출발이 임박해서 실시간 차로 계산해요 (멀면 도착 시각에서 거꾸로)
def setup_user(client, hours=40 / 60, todos=(("우유 사기", ["편의점"], "필수"),)):
    arrive_by = (datetime.now(planner.KST) + timedelta(hours=hours)).isoformat(timespec="seconds")
    client.post("/api/schedules", json={
        "user_id": "u1", "destination": "청량리역", "destination_lat": 37.58029,
        "destination_lng": 127.04691, "arrive_by": arrive_by,
    })
    for text, place_types, importance in todos:
        client.post("/api/todos", json={"user_id": "u1", "text": text, "place_types": place_types,
                                        "importance": importance})


def plan(client, **body):
    return client.post("/api/plan", json={"user_id": "u1", "origin": ORIGIN, **body})


def test_실시간_경로_카드와_할_일(client, world):
    setup_user(client)
    res = plan(client)
    assert res.status_code == 200
    body = res.json()
    assert 1 <= len(body["routes"]) <= 3
    first = body["routes"][0]
    assert first["first_walk_min"] == 2 and first["has_realtime"] is True
    todo = body["todos"][0]
    # 경유 시간 = 바로 갈 때보다 더 걷는 만큼: 출발지 → CU 150초 + CU → 정류장 150초 − 바로 120초 = 3분 (11/13)
    assert (todo["status"], todo["place"]["name"], todo["detour_min"]) == ("포함", "CU 안암역점", 3)
    assert (todo["place"]["walk_to_min"], todo["place"]["walk_back_min"]) == (3, 3)


def test_실시간_계산_결과를_할_일에_저장(client, world):
    setup_user(client)
    plan(client)
    assert client.get("/api/todos", params={"user_id": "u1"}).json()[0]["status"] == "포함"


def test_현재_위치는_저장하지_않음(client, world, tmp_path):
    setup_user(client)
    plan(client)
    dump = "\n".join(sqlite3.connect(tmp_path / "test.db").iterdump())
    assert str(ORIGIN["lat"]) not in dump and str(ORIGIN["lng"]) not in dump


def test_실시간_도착이_실패해도_대기_없이_계산(client, world, monkeypatch):
    def broken(leg):
        raise seoul_bus.SeoulBusError("서울시 버스 API 오류")

    monkeypatch.setattr(planner.seoul_bus, "match_leg", broken)
    setup_user(client)
    res = plan(client)
    assert res.status_code == 200
    assert res.json()["routes"][-1]["has_realtime"] is False or res.json()["routes"][0]["has_realtime"] is False


def test_근처에_장소가_없으면_필수는_대기이고_저장_안_함(client, world):
    setup_user(client, todos=(("꽃 사기", ["꽃집"], "필수"),))
    todo = plan(client).json()["todos"][0]
    assert (todo["status"], todo["place"], todo["reason"]) == ("대기", None, "근처에서 찾지 못했어요")
    assert client.get("/api/todos", params={"user_id": "u1"}).json()[0]["status"] == "대기"


def test_시간이_부족하면_선택_할_일은_제외(client, world):
    setup_user(client, hours=0.25, todos=(("우유 사기", ["편의점"], "선택"),))  # 15분 뒤 도착
    assert plan(client).json()["todos"][0]["status"] == "제외"


def test_일정이_없으면_404(client, world):
    res = plan(client)
    assert (res.status_code, res.json()["error"]["code"]) == (404, "not_found")


def test_지난_일정은_고르지_않고_다가오는_일정을_고름(client, world):
    setup_user(client, hours=-1, todos=())  # 지난 일정
    setup_user(client, hours=3)              # 다가오는 일정
    setup_user(client, hours=1, todos=())    # 가장 가까운 다가오는 일정
    body = plan(client).json()
    arrive_by = datetime.fromisoformat(body["schedule"]["arrive_by"])
    assert timedelta(minutes=50) < arrive_by - datetime.now(planner.KST) < timedelta(minutes=70)


def test_지난_일정만_있으면_404(client, world):
    setup_user(client, hours=-1)
    res = plan(client)
    assert (res.status_code, res.json()["error"]["message"]) == (404, "다가오는 일정이 없어요")


def test_현재_좌표가_들어간_호출은_5분만_기억(client, world, monkeypatch):
    # 11/13: 새로고침마다 도보를 15번씩 불러 하루 한도(1,000)를 다 써서, 현재 좌표 호출도 5분은 기억해요
    seen = []
    monkeypatch.setattr(planner.kakao, "transit_routes",
                        lambda s, e, use_cache=True, ttl_seconds=None: seen.append(("transit", s, ttl_seconds))
                        or world["routes"])
    real_walk_route = planner.kakao.walk_route
    monkeypatch.setattr(planner.kakao, "walk_route",
                        lambda s, e, via=None, use_cache=True, ttl_seconds=None:
                        seen.append(("walk", s, ttl_seconds)) or real_walk_route(s, e, via=via))
    setup_user(client)
    plan(client)
    origin = (ORIGIN["lng"], ORIGIN["lat"])
    from_origin = [ttl for kind, start, ttl in seen if start == origin]
    assert from_origin and all(ttl == kakao.ORIGIN_TTL_SECONDS for ttl in from_origin)


def test_경로가_없으면_404(client, world):
    world["routes"] = []
    setup_user(client)
    res = plan(client)
    assert (res.status_code, res.json()["error"]["code"]) == (404, "no_route")


def test_카카오_실패는_502(client, world, monkeypatch):
    def broken(s, e, **kw):
        raise kakao.KakaoError("카카오 API 오류: HTTP 429")

    monkeypatch.setattr(planner.kakao, "transit_routes", broken)
    setup_user(client)
    res = plan(client)
    assert (res.status_code, res.json()["error"]["code"]) == (502, "upstream_error")


def test_카카오_한도_초과는_503과_안내(client, world, monkeypatch):
    def used_up(s, e, **kw):
        raise kakao.KakaoError("카카오 API 오류: HTTP 400 (API limit has been exceeded.)", status=400, code=-10)

    monkeypatch.setattr(planner.kakao, "transit_routes", used_up)
    setup_user(client)
    res = plan(client)
    err = res.json()["error"]
    assert (res.status_code, err["code"]) == (503, "quota_exceeded")
    assert "자정" in err["message"]


def test_키가_없으면_503(client, world, monkeypatch):
    monkeypatch.setattr(config, "KAKAO_REST_API_KEY", "")
    setup_user(client)
    assert plan(client).status_code == 503


def test_한국_밖_좌표는_오류(client, world):
    res = client.post("/api/plan", json={"user_id": "u1", "origin": {"lat": 0, "lng": 0}})
    assert res.status_code == 422


def test_필수_할_일을_넣는_경로가_먼저(client, world):
    setup_user(client)
    body = plan(client).json()
    assert body["todos"][0]["status"] == "포함"
    assert body["routes"][0]["max_stay_min"] is not None


def test_실시간_뒤로_배차_간격만큼_차를_이어_붙임():
    assert planner.extend_by_interval([300, 900], 600)[:4] == [300, 900, 1500, 2100]
    assert planner.extend_by_interval([300], None) == [300]
    assert planner.extend_by_interval([], 600) == []
    assert max(planner.extend_by_interval([300], 600)) <= planner.LOOKAHEAD_SECONDS


# ---------- 경유 후보 여러 곳 (#62), 머물 시간 (11/12) ----------
GS = {"name": "GS25 안암점", "address": "서울 성북구 안암로 1", "lng": 127.0310, "lat": 37.5866, "distance_m": 120}
DAISO = {"name": "다이소 안암점", "address": "서울 성북구 고려대로24길 51", "lng": 127.0297, "lat": 37.5839,
         "distance_m": 260}
FAR = {"name": "CU 먼곳점", "address": "서울 성북구 먼길 9", "lng": 127.0400, "lat": 37.5900, "distance_m": 290}
WALK_BY_LNG = {CU["lng"]: 300, GS["lng"]: 200, DAISO["lng"]: 600, FAR["lng"]: 400}


@pytest.fixture()
def walks(world, monkeypatch):
    """경유 장소마다 다른 도보 시간. 어느 장소의 도보를 쟀는지도 기록해요."""
    asked = []

    def walk(s, e, via=None, **kw):
        if not via:
            return 120
        asked.append(via[0][0])
        return WALK_BY_LNG[via[0][0]]
    monkeypatch.setattr(planner.kakao, "walk_seconds", walk)

    def route(s, e, via=None, **kw):
        # 실제 모드: 출발지 → 장소 → 정류장. 바로 가는 120초보다 WALK_BY_LNG 만큼 더 걸어요
        if not via:
            return {"seconds": 120, "legs": [{"seconds": 120, "points": []}]}
        asked.append(via[0][0])
        total = 120 + WALK_BY_LNG[via[0][0]]
        return {"seconds": total, "legs": [{"seconds": total // 2, "points": []},
                                           {"seconds": total - total // 2, "points": []}]}
    monkeypatch.setattr(planner.kakao, "walk_route", route)
    world["places"] = {"편의점": [{**CU, "distance_m": 80}, GS], "다이소": [DAISO]}
    return asked


def test_장소_종류_여러_개에서_후보를_모아_도보가_짧은_순(client, walks, monkeypatch):
    monkeypatch.setattr(planner, "_later_segments", lambda *a, **k: [])  # 버스 타기 전 후보만 봐요
    setup_user(client, todos=(("이어폰 사기", ["편의점", "다이소"], "필수"),))
    todo = plan(client).json()["todos"][0]
    assert [c["name"] for c in todo["candidates"]] == ["GS25 안암점", "CU 안암역점", "다이소 안암점"]
    assert [c["detour_min"] for c in todo["candidates"]] == [4, 5, 10]
    assert {c["place_type"] for c in todo["candidates"]} == {"편의점", "다이소"}
    # 계산은 가장 가까운 후보로 해요
    assert todo["place"]["name"] == "GS25 안암점" and todo["detour_min"] == 4
    assert (todo["place"]["lng"], todo["place"]["lat"]) == (GS["lng"], GS["lat"])


def test_후보는_최대_3곳이고_먼_곳은_도보를_재지_않음(client, walks, world, monkeypatch):
    monkeypatch.setattr(planner, "_later_segments", lambda *a, **k: [])  # 버스 타기 전 후보만 봐요
    world["places"] = {"편의점": [{**CU, "distance_m": 80}, GS, FAR], "다이소": [DAISO]}
    setup_user(client, todos=(("이어폰 사기", ["편의점", "다이소"], "필수"),))
    todos = plan(client).json()["todos"]
    assert len(todos[0]["candidates"]) == 3
    # 직선거리 순: CU 80m, GS 120m, 다이소 260m, 먼곳 290m → 4번째인 먼곳은 도보를 재지 않아요
    assert FAR["lng"] not in walks and DAISO["lng"] in walks


def test_같은_가게가_두_종류에_나와도_한_번만(client, walks, world):
    world["places"] = {"편의점": [GS], "다이소": [GS]}
    setup_user(client, todos=(("이어폰 사기", ["편의점", "다이소"], "필수"),))
    assert [c["name"] for c in plan(client).json()["todos"][0]["candidates"]] == ["GS25 안암점"]


def test_할_일에_정한_머물_시간으로_계산(client, world):
    setup_user(client)
    body = plan(client).json()
    assert (body["todos"][0]["stay_min"], body["todos"][0]["status"]) == (4, "포함")  # 기본 4분

    todo_id = body["todos"][0]["todo_id"]
    client.patch(f"/api/todos/{todo_id}", params={"user_id": "u1"}, json={"stay_minutes": 90})
    todo = plan(client).json()["todos"][0]
    assert (todo["stay_min"], todo["status"]) == (90, "대기")  # 90분 머물면 탈 차가 없어요


# ---------- 실제 모드 질문 (#59) ----------
@pytest.fixture()
def live_ask(client, world, monkeypatch):
    """AI 없이(키워드 규칙) 실제 모드로 묻기. 차는 10분·20분 뒤에 와요."""
    monkeypatch.setattr(config, "OPENAI_API_KEY", "")
    monkeypatch.setattr(config, "LLM_MODEL", "")
    monkeypatch.setattr(planner, "_vehicle_seconds", lambda leg: [600, 1200])

    def ask(text):
        return client.post("/api/ask", json={"user_id": "u1", "text": text, "demo": False}).json()
    return ask


def test_실제_모드_다음_차는_추천받은_경로로_답함(client, live_ask):
    setup_user(client)
    route = plan(client).json()["routes"][0]
    body = live_ask("다음 버스 언제야?")
    assert body["result"] == {"intent": "next_vehicle", "route": body["result"]["route"],
                              "minutes": 10, "next_minutes": 20}
    assert body["result"]["route"] in route["name"]
    assert "10분 뒤에 와요" in body["answer"] and "20분 뒤" in body["answer"]


def test_실제_모드_남은_시간(client, live_ask):
    setup_user(client)
    plan(client)
    body = live_ask("몇 분 남았어?")
    left = (600 - assistant.DEFAULT_BUFFER_SECONDS) // 60
    assert body["result"]["minutes"] == left
    assert "10분 뒤에 와요" in body["answer"] and "정류장에 있으면 돼요" in body["answer"]


def test_실제_모드_들르기는_이미_넣은_할_일과_함께_판단(client, live_ask):
    setup_user(client)  # 우유 사기(편의점, 필수)가 CU에 포함돼요
    plan(client)
    body = live_ask("편의점 들러도 돼?")
    assert body["result"]["feasible"] is True
    assert body["result"]["place"]["name"] == "CU 안암역점"
    assert body["todo"]["status"] == "포함" and body["todo"]["id"]


def test_실제_모드_들르기_근처에_없으면_안내(client, live_ask):
    setup_user(client)
    plan(client)
    body = live_ask("꽃집 들러도 돼?")
    assert body["result"]["feasible"] is False
    assert body["answer"] == "정류장 근처에서 꽃집을 찾지 못했어요."


def test_실제_모드_계획이_오래되면_다시_추천받으라고_안내(client, live_ask, monkeypatch):
    setup_user(client)
    plan(client)
    later = datetime.now(planner.KST) + timedelta(hours=1, minutes=5)
    monkeypatch.setattr(assistant, "_now", lambda: later)
    assert live_ask("다음 버스 언제야?")["answer"] == assistant.NO_PLAN_ANSWER


def test_실제_모드_계획은_사용자마다_따로(client, live_ask):
    setup_user(client)
    plan(client)
    other = client.post("/api/ask", json={"user_id": "u2", "text": "다음 버스 언제야?", "demo": False}).json()
    assert other["answer"] == assistant.NO_PLAN_ANSWER


def test_실제_모드_늦어짐은_늦은_만큼_다음_차로_다시_계산(client, live_ask):
    setup_user(client)
    plan(client)
    body = live_ask("10분 늦을 것 같아")
    r = body["result"]
    assert r["intent"] == "running_late" and r["delay_minutes"] == 10 and r["missed"] is False
    # 10분 뒤에 오는 차는 못 타고 20분 차를 타요
    board = datetime.fromisoformat(r["board_at"])
    now = datetime.now(planner.KST)
    assert 9 * 60 <= (board - now).total_seconds() <= 21 * 60
    assert "10분 늦으면" in body["answer"]


def test_실제_모드_버스를_놓치면_다음_차(client, live_ask):
    setup_user(client)
    plan(client)
    r = live_ask("버스 놓쳤어")["result"]
    assert r["missed"] is True and r["board_at"]


def test_실제_모드_장소_정보는_정류장_근처_후보(client, live_ask, world):
    world["places"] = {"편의점": [CU, GS]}
    setup_user(client)
    plan(client)
    body = live_ask("편의점 어디야?")
    names = [p["name"] for p in body["result"]["places"]]
    assert set(names) == {"CU 안암역점", "GS25 안암점"}
    assert body["answer"].startswith("가까운 곳은") and "왕복" in body["answer"]


def test_실제_모드_다른_경로는_말한_기준으로_가장_좋은_경로(client, live_ask):
    setup_user(client)
    routes = plan(client).json()["routes"]
    body = live_ask("환승 적은 걸로 없어?")  # 키워드 규칙: preference = transfer
    r = body["result"]
    assert r["preference"] == "transfer"
    assert [x["name"] for x in r["routes"]] == [x["name"] for x in routes]
    best = min(routes, key=lambda x: x["transfers"])
    assert best["name"] in body["answer"] and "환승이 가장 적은" in body["answer"]


def _ai_says(monkeypatch, intent: dict):
    """AI 분류 결과를 정해 줘요 (키워드 규칙이 모르는 표현을 시험할 때)."""
    monkeypatch.setattr(assistant, "_ai_ready", lambda: True)
    monkeypatch.setattr(assistant, "_classify", lambda text, history, context=None: {
        "type": "question", "intents": [{"place_types": [], "delay_minutes": None, **intent}],
        "needs_confirm": False, "question": None, "engine": "ai"})


def test_실제_모드_지금_출발하면_늦어(client, live_ask, monkeypatch):
    setup_user(client)
    plan(client)
    _ai_says(monkeypatch, {"intent": "running_late", "delay_minutes": 0})
    body = live_ask("지금 출발하면 늦어?")
    assert body["answer"].startswith("지금 출발하면") and body["answer"].endswith("늦지 않아요.")


def test_할_일_완료(client, live_ask, monkeypatch):
    setup_user(client)
    todo_id = plan(client).json()["todos"][0]["todo_id"]
    _ai_says(monkeypatch, {"intent": "change_todo", "action": "done", "todo_text": "우유"})
    body = live_ask("우유는 샀어")
    assert body["answer"] == "우유 사기는 완료로 표시할게요."
    todos = client.get("/api/todos", params={"user_id": "u1"}).json()
    assert next(t for t in todos if t["id"] == todo_id)["status"] == "완료"


def test_실제_모드_두_곳_모두_들를_수_있으면_하나로_답함(client, live_ask, world, monkeypatch):
    world["places"] = {"편의점": [CU], "약국": [{**GS, "name": "대학약국", "address": "서울 성북구 고려대로 89"}]}
    setup_user(client, hours=47 / 60, todos=())  # 실시간 범위 안에서 가장 넉넉하게
    plan(client)
    monkeypatch.setattr(planner, "_vehicle_seconds", lambda leg: [600, 1200, 1800])  # 두 곳을 들르면 30분 차
    monkeypatch.setattr(assistant, "_ai_ready", lambda: True)
    monkeypatch.setattr(assistant, "_classify", lambda text, history, context=None: {
        "type": "question", "needs_confirm": False, "question": None, "engine": "ai",
        "intents": [{"intent": "stopover_check", "place_types": [k], "delay_minutes": None} for k in ("편의점", "약국")]})
    body = live_ask("편의점 들렀다가 약국도 갈 수 있어?")
    assert body["answer"].startswith("CU 안암역점과 대학약국에 모두 들를 수 있어요.")
    assert "차를 타면 되고" in body["answer"]
    assert [t["status"] for t in body["todos"]] == ["포함", "포함"]
    assert body["result"]["feasible"] is True and body["result"]["board_at"]



# ---------- 출발 기준 (11/13): 일정은 거꾸로, 홈 검색은 지금 출발 ----------
def test_일정이_멀면_도착_시각에서_거꾸로_출발_시각을_계산(client, world, monkeypatch):
    called = []
    monkeypatch.setattr(planner, "_vehicle_seconds", lambda leg: called.append(leg) or [600, 1200])
    setup_user(client, hours=5)
    body = plan(client).json()
    arrive_by = datetime.fromisoformat(body["schedule"]["arrive_by"])
    depart, arrive = (datetime.fromisoformat(body[k]) for k in ("depart_at", "arrive_at"))
    assert body["basis"] == "arrive_by"
    # 도착 희망 5분 전에 닿도록, 지금이 아니라 몇 시간 뒤에 출발해요 (912분 여유 문제)
    assert arrive_by - arrive == timedelta(minutes=5)
    assert depart - datetime.now(planner.KST) > timedelta(hours=4)
    assert called == []  # 지금 오는 차는 그때 탈 차가 아니라서 실시간을 부르지 않아요
    card = body["routes"][0]
    assert card["basis"] == "arrive_by" and card["has_realtime"] is False
    assert card["depart_at"] == body["depart_at"]


def test_적용_안_한_할_일은_탑승_시각에_안_들어감(client, world):
    # 11/13: 할 일을 적용 안 했는데 "대기 57분, 18:23 탑승"(도착 17:55보다 늦음)으로 나오던 문제
    setup_user(client, hours=5)
    body = plan(client).json()
    assert body["todos"][0]["status"] == "포함"  # 할 일 판정은 그대로 줘요
    card = body["routes"][0]
    depart, board, arrive = (datetime.fromisoformat(card[k]) for k in ("depart_at", "board_at", "arrive_at"))
    assert board - depart == timedelta(minutes=card["first_walk_min"])  # 처음 도보만
    assert depart < board < arrive


def test_가까운_일정은_곧_오는_차와_탈_차를_알려_줌(client, world):
    # 11/13: 지도앱처럼 "2분 뒤 · 11분 뒤"를 카드에 보여 주려고
    setup_user(client)  # 40분 뒤
    card = next(r for r in plan(client).json()["routes"] if r["type"] == "BUS")
    assert card["next_vehicles_min"][:2] == [10, 20]  # 가짜 버스: 600초, 1200초
    assert card["board_in_min"] in card["next_vehicles_min"]
    assert card["ride_name"].endswith("번")


def test_일정이_멀면_곧_오는_차는_비어_있음(client, world):
    setup_user(client, hours=5)
    card = plan(client).json()["routes"][0]
    assert card["next_vehicles_min"] == [] and card["board_in_min"] is None


def test_출발이_임박하면_실시간_차로_탈_차를_정함(client, world):
    setup_user(client)  # 40분 뒤
    body = plan(client).json()
    assert body["basis"] == "realtime" and body["routes"][0]["has_realtime"] is True
    depart, board = (datetime.fromisoformat(body[k]) for k in ("depart_at", "board_at"))
    assert depart <= board


def test_홈_검색창은_일정_없이_지금_출발(client, world):
    res = client.post("/api/plan", json={"user_id": "nobody", "demo": False, "origin": ORIGIN,
                                         "destination": {"name": "서울역", "lat": 37.5547, "lng": 126.9707}})
    assert res.status_code == 200  # 일정이 없어도 돼요 ("다가오는 일정이 없어요" 오류 해결)
    body = res.json()
    assert body["basis"] == "now"
    assert body["schedule"]["destination"]["name"] == "서울역" and body["schedule"]["arrive_by"] is None
    assert body["todos"] == []  # 고른 할 일이 없으면 길만 찾아요
    now = datetime.now(planner.KST)
    assert abs((datetime.fromisoformat(body["depart_at"]) - now).total_seconds()) < 15 * 60


def test_홈_검색창도_고른_할_일은_넣음(client, world):
    setup_user(client)
    todo_id = client.get("/api/todos", params={"user_id": "u1"}).json()[0]["id"]
    body = client.post("/api/plan", json={"user_id": "u1", "demo": False, "origin": ORIGIN, "todo_ids": [todo_id],
                                          "destination": {"lat": 37.5547, "lng": 126.9707}}).json()
    assert [t["todo_id"] for t in body["todos"]] == [todo_id]


def test_경로_카드에_구간_목록(client, world):
    setup_user(client)
    legs = next(r for r in plan(client).json()["routes"] if r["name"] == "2115")["legs"]
    assert [leg["type"] for leg in legs] == ["WALK", "BUS", "WALK"]
    walk, bus, last = legs
    assert (walk["from"], walk["to"]) == ("출발지", "안암역3번출구") and walk["minutes"] == 2
    assert bus["name"] == "2115" and (bus["from"], bus["to"]) == ("안암역3번출구", "청량리역환승센터")
    assert bus["minutes"] == 14 and bus["stop_count"] == 5
    assert 2 <= len(bus["points"]) <= 40  # 지도에 그릴 선 (카카오 57개 → 40개로 줄임)
    assert last["to"] == "도착지"


# ---------- 실시간이 없을 때 질문 (11/13 새벽 2시 테스트에서 발견) ----------
@pytest.fixture()
def far_plan(client, world, monkeypatch):
    """5시간 뒤 일정: 도착 시각에서 거꾸로 계산하고, 질문할 때도 실시간을 부르지 않아요."""
    called = []
    monkeypatch.setattr(planner, "_vehicle_seconds", lambda leg: called.append(1) or [600, 1200])
    monkeypatch.setattr(config, "OPENAI_API_KEY", "")
    monkeypatch.setattr(config, "LLM_MODEL", "")
    setup_user(client, hours=5)
    body = plan(client).json()

    def ask(text):
        return client.post("/api/ask", json={"user_id": "u1", "text": text, "demo": False}).json()
    return body, ask, called


def _hm(iso: str) -> str:
    t = datetime.fromisoformat(iso)
    return f"{t.hour}시" if t.minute == 0 else f"{t.hour}시 {t.minute}분"


def test_먼_일정_다음_버스는_출발_시각으로_안내(far_plan):
    body, ask, called = far_plan
    answer = ask("다음 버스 언제야?")["answer"]
    assert _hm(body["depart_at"]) in answer and "출발 30분 전부터" in answer
    assert called == []


def test_먼_일정_남은_시간은_출발_시각까지(far_plan):
    body, ask, _ = far_plan
    r = ask("몇 분 남았어?")
    assert r["result"]["leave_by"] == body["depart_at"]
    assert r["answer"].startswith(f"{_hm(body['depart_at'])}에 출발하면 돼요.")


def test_먼_일정_늦어짐은_계획한_출발_시각_기준(far_plan):
    body, ask, _ = far_plan
    r = ask("10분 늦을 것 같아")
    assert r["result"]["on_time"] is False  # 도착 5분 전 여유보다 10분 늦어서
    assert r["answer"].startswith("10분 늦게 출발하면") and r["answer"].endswith("도착 희망 시각보다 늦어요.")


def test_먼_일정_들르기는_일찍_나가면_됨(far_plan):
    body, ask, _ = far_plan
    r = ask("편의점 들러도 돼?")
    assert r["result"]["feasible"] is True
    assert r["answer"].endswith("에 출발하면 돼요.") and r["result"]["depart_at"] <= body["depart_at"]


def test_새벽처럼_실시간이_없으면_이유를_안내(client, world, monkeypatch):
    monkeypatch.setattr(planner, "_vehicle_seconds", lambda leg: [])
    monkeypatch.setattr(config, "OPENAI_API_KEY", "")
    monkeypatch.setattr(config, "LLM_MODEL", "")
    setup_user(client)
    plan(client)
    answer = client.post("/api/ask", json={"user_id": "u1", "text": "다음 버스 언제야?", "demo": False}).json()["answer"]
    assert answer.startswith("지금은 2115번 실시간 도착 정보가 없어요.") and "마을버스" in answer


def test_도보는_실제_길_모양으로_그림(client, world):
    # 11/13: 출발지 → 정류장 도보가 지도에 직선으로 그려지던 문제
    setup_user(client)
    legs = plan(client).json()["routes"][0]["legs"]
    assert legs[0]["type"] == "WALK" and [5.0, 5.0] in legs[0]["points"]


def test_경유지_도보는_출발지에서_가게_가게에서_정류장(client, world):
    # 11/13: 화면에 "현재 위치 → 가게 도보 3분"으로 나와 출발지 → 정류장 12분이 빠지던 문제
    setup_user(client, hours=5)
    place = plan(client).json()["todos"][0]["place"]
    assert (place["walk_to_min"], place["walk_back_min"]) == (3, 3)
    assert place["walk_to_points"][-1] == [9.0, 9.0] and place["walk_back_points"][0] == [9.0, 9.0]


def test_경유_구간이_하나로_오면_장소에서_나눔():
    points = [[0.0, 0.0], [1.0, 0.0], [2.0, 0.0], [3.0, 0.0]]
    to, back, to_pts, back_pts = planner._split_at(points, 300, (1.0, 0.1))
    assert (to, back) == (100, 200) and to_pts[-1] == back_pts[0] == [1.0, 0.0]


def test_거쳐_가는_길을_못_찾으면_정류장_왕복으로(client, world, monkeypatch):
    # 카카오가 출발지 → 가게 → 정류장 길을 못 찾아도(400 → None) 후보가 사라지지 않아요
    monkeypatch.setattr(planner.kakao, "walk_route", lambda s, e, via=None, **kw: (
        None if via else {"seconds": 120, "legs": [{"seconds": 120, "points": []}]}))
    setup_user(client, hours=5)
    todo = plan(client).json()["todos"][0]
    assert todo["status"] == "포함" and todo["detour_min"] == 5  # 정류장 왕복 300초
    assert "walk_to_min" not in todo["place"]


def test_목적지가_가까우면_걸어가라고(client, world, monkeypatch):
    monkeypatch.setattr(planner.kakao, "transit_routes", lambda s, e, **kw: [])
    res = client.post("/api/plan", json={"user_id": "u", "demo": False, "origin": {"lat": 37.5861, "lng": 127.0291},
                                         "destination": {"name": "근처", "lat": 37.5871, "lng": 127.0301}})
    assert res.status_code == 404 and "걸어서" in res.json()["error"]["message"]


def test_도보_한도를_다_쓰면_어림값으로_계획하고_표시(client, world, monkeypatch):
    # 11/13: 도보 한도를 넘어도 경로 추천은 계속 나와야 해요. 앱이 "어림" 표시를 할 수 있게 알려 줘요
    monkeypatch.setattr(planner.kakao, "walk_quota_used_up", lambda: True)
    setup_user(client)
    res = plan(client)
    assert res.status_code == 200 and res.json()["walk_estimated"] is True


def test_평소에는_어림_표시가_없음(client, world):
    setup_user(client)
    assert plan(client).json()["walk_estimated"] is False


def test_추천_경로는_동시에_계산해서_빠름(client, world, monkeypatch):
    # 11/14: 첫 조회가 오래 걸렸어요. 카카오 도보 호출 하나가 0.2초 걸린다고 치면
    # 순서대로는 경로 3개 × (처음·마지막 도보 2번) = 1.2초 이상, 동시에 하면 0.2초 남짓이에요
    import time as clock
    route = dict(world["routes"][0])
    world["routes"] = [route, dict(route), dict(route)]
    fake = planner.kakao.walk_route

    def slow(*args, **kw):
        clock.sleep(0.2)
        return fake(*args, **kw)

    monkeypatch.setattr(planner.kakao, "walk_route", slow)
    setup_user(client)
    started = clock.monotonic()
    res = plan(client, todo_ids=[])
    took = clock.monotonic() - started
    assert res.status_code == 200 and len(res.json()["routes"]) == 3
    assert took < 0.8, f"{took:.2f}초 걸렸어요"


def test_장소_종류가_여러_개면_검색을_동시에(monkeypatch):
    """편의점·다이소처럼 장소 종류가 둘이면 검색 두 번을 순서대로 기다리지 않아요."""
    import time as clock
    calls = []

    def slow(place_type, center, radius_m=300, size=1, **kw):
        clock.sleep(0.3)
        calls.append(place_type)
        return []

    monkeypatch.setattr(planner.places, "search_by_place_type", slow)
    todo = {"id": 1, "text": "이어폰 사기", "place_types": ["편의점", "다이소"], "importance": "필수"}
    started = clock.monotonic()
    result = planner._near_place(todo, (127.0, 37.5), {})
    took = clock.monotonic() - started
    assert result is None
    assert set(calls) == {"편의점", "다이소"}
    assert took < 0.55, f"{took:.2f}초 걸렸어요"


def test_실시간_도착은_경유_후보와_동시에_계산(client, world, monkeypatch):
    """실시간 도착 조회가 경유 후보 검색이 끝날 때까지 기다리지 않아요."""
    import time as clock

    def slow_vehicle(leg):
        clock.sleep(0.3)
        return [600]

    def slow_near(*args, **kwargs):
        clock.sleep(0.3)
        return None

    def slow_later(*args, **kwargs):
        clock.sleep(0.3)
        return []

    monkeypatch.setattr(planner, "_vehicle_seconds", slow_vehicle)
    monkeypatch.setattr(planner, "_near_place", slow_near)
    monkeypatch.setattr(planner, "_later_segments", slow_later)
    setup_user(client)
    started = clock.monotonic()
    res = plan(client)
    took = clock.monotonic() - started
    assert res.status_code == 200
    assert took < 0.55, f"{took:.2f}초 걸렸어요"


def test_이동_중_들르기는_지난_출발_시각을_말하지_않음(client, far_plan):
    """11/14: 이동 중(18:33)에 '커피 사도 돼?'라고 물었더니 '17시 58분에 출발하시면 돼요'라고 답하던 문제."""
    trip = {"phase": "waiting", "now": datetime.now().astimezone().isoformat(), "stop_name": "정류장",
            "destination": "목적지", "next_vehicles_min": []}
    r = client.post("/api/ask", json={"user_id": "u1", "text": "편의점 들러도 돼?", "demo": False,
                                      "trip": trip}).json()
    assert r["result"]["feasible"] is True
    assert "출발하면 돼요" not in r["answer"] and "출발하시면" not in r["answer"]
    assert "depart_at" not in r["result"]
    assert "들를 수 있어요" in r["answer"]


def test_이동_중_들르기는_저장한_할_일_id를_줌(client, far_plan):
    """이동 중 팝업의 '경유지로 추가' 버튼이 이 id로 지금 경로에 경유지를 넣어요 (11/14)."""
    trip = {"phase": "waiting", "now": datetime.now().astimezone().isoformat(), "stop_name": "정류장",
            "destination": "목적지", "next_vehicles_min": []}
    r = client.post("/api/ask", json={"user_id": "u1", "text": "편의점 들러도 돼?", "demo": False,
                                      "trip": trip}).json()
    assert r["result"]["feasible"] is True
    assert r["todo"] and r["todo"].get("id")


def test_이동_중_들르기_할_일_이름은_질문_문장이_아님(client, far_plan):
    trip = {"phase": "waiting", "now": datetime.now().astimezone().isoformat(), "stop_name": "정류장",
            "destination": "목적지", "next_vehicles_min": []}
    r = client.post("/api/ask", json={"user_id": "u1", "text": "편의점 들러도 돼?", "demo": False,
                                      "trip": trip}).json()
    assert r["todo"]["text"] == "편의점 들르기"


def test_타는_중_들르기는_목적지에_내려서_들르라고_안내(client, far_plan):
    """11/14: 버스를 타는 중이면 중간에 내리라고 하지 않고 목적지 근처 가게를 알려 줘요."""
    trip = {"phase": "riding", "now": datetime.now().astimezone().isoformat(), "ride_name": "2115번",
            "destination": "청량리역", "next_vehicles_min": []}
    r = client.post("/api/ask", json={"user_id": "u1", "text": "편의점 들러도 돼?", "demo": False,
                                      "trip": trip}).json()
    assert r["result"]["feasible"] is False and r["result"]["after_arrival"] is True
    assert "청량리역에 내려서" in r["answer"] or "청량리역에 내린 뒤" in r["answer"]
    assert r["result"]["place"]["name"] in r["answer"]
    assert r["todo"]["text"] == "편의점 들르기"


# ---------- 인터뷰·사용 테스트 반영 (11/14) ----------
OTHER_CU = {"name": "GS25 환승점", "address": "서울 종로구 종로 100", "lng": 127.0310, "lat": 37.5870}


def _transfer_trip(minutes_to_board: int, phase: str = "waiting") -> dict:
    """버스 → 1호선 경로에서 1호선으로 갈아타는 곳 (인터뷰 P1·P3)."""
    now = datetime.now().astimezone().replace(microsecond=0)
    trip = {"phase": phase, "now": now.isoformat(), "ride_name": "273번" if phase == "riding" else "1호선",
            "stop_name": "종로3가역", "destination": "시청", "next_vehicles_min": [],
            "transfer": {"get_off_name": "종로3가", "stop_name": "종로3가역", "lat": 37.5704, "lng": 126.9921,
                         "ride_name": "1호선",
                         "get_off_at": (now + timedelta(minutes=1)).isoformat() if phase == "riding" else now.isoformat(),
                         "reach_at": (now + timedelta(minutes=3)).isoformat() if phase == "riding" else now.isoformat(),
                         "board_at": (now + timedelta(minutes=minutes_to_board)).isoformat()}}
    return trip


def _trip_ask(client, text, trip):
    return client.post("/api/ask", json={"user_id": "u1", "text": text, "demo": False, "trip": trip}).json()


def test_환승_대기_중_들르기는_갈아탈_곳_근처에서_계산(client, far_plan):
    r = _trip_ask(client, "편의점 들러도 돼?", _transfer_trip(15))
    res = r["result"]
    assert res["at_transfer"] is True and res["feasible"] is True and res["add_now"] is True
    assert res["place"]["name"] == "CU 안암역점" and res["max_stay_min"] >= 1 and res["return_by"]
    assert "1호선 타기 전에" in r["answer"] and "종로3가역에 돌아오면 돼요" in r["answer"]
    # 들를 수 있으면 '포함'으로 저장해서 앱이 [경유지로 추가]를 보여 줘요
    assert r["todo"]["status"] == "포함" and r["todo"]["id"]


def test_환승_전_시간이_부족하면_안내하고_대기로_저장(client, far_plan):
    r = _trip_ask(client, "편의점 들러도 돼?", _transfer_trip(3))
    assert r["result"]["feasible"] is False and r["result"]["at_transfer"] is True
    assert "부족해요" in r["answer"] and r["todo"]["status"] == "대기"


def test_첫_차_타는_중이면_갈아타기_전에_들를_수_있는지_미리_알려줌(client, far_plan):
    r = _trip_ask(client, "편의점 들러도 돼?", _transfer_trip(20, phase="riding"))
    res = r["result"]
    assert res["feasible"] is True and res["add_now"] is False  # 아직 버스 안이라 지금 경로에 넣지 않아요
    assert "종로3가에서 내려 1호선으로 갈아타기 전에" in r["answer"]
    assert r["todo"]["status"] == "대기"


def test_갈아타기_정보가_없으면_타는_중은_예전처럼_도착_후_안내(client, far_plan):
    trip = {"phase": "riding", "now": datetime.now().astimezone().isoformat(), "ride_name": "2115번",
            "destination": "청량리역", "next_vehicles_min": []}
    r = _trip_ask(client, "편의점 들러도 돼?", trip)
    assert r["result"]["after_arrival"] is True and "at_transfer" not in r["result"]


def test_다른_가게를_물으면_앞에서_말한_곳을_빼고_답함(client, world, live_ask):
    """사용 테스트 1번: "다른 카페 갈래"에 같은 가게만 답하던 문제."""
    world["places"]["편의점"] = [CU, OTHER_CU]
    setup_user(client, todos=())
    plan(client)
    first = live_ask("편의점 들러도 돼?")
    assert first["result"]["place"]["name"] == "CU 안암역점"
    other = live_ask("다른 편의점도 안 될까?")
    assert other["result"]["intent"] == "stopover_check"
    assert other["result"]["place"]["name"] == "GS25 환승점"
    again = live_ask("다른 편의점은 없어?")
    assert again["result"]["place"] is None and "다른 편의점은 찾지 못했어요" in again["answer"]


def test_가는_길에_부족하면_목적지_근처_대안과_출발_전_안내(client, world, live_ask):
    """인터뷰 P4: 이동 중이 빠듯하면 도착 후·출발 전에 들르기."""
    setup_user(client, hours=0.2, todos=())  # 12분 뒤 도착이라 들를 시간이 없어요
    plan(client)
    r = live_ask("편의점 들러도 돼?")
    assert r["result"]["feasible"] is False
    assert r["result"]["after_arrival_place"]["name"] == "CU 안암역점"
    assert "부족해요" in r["answer"] and "출발 전에 미리" in r["answer"] and "내려서 걸어서" in r["answer"]


def test_시연_모드_다른_가게는_한_곳뿐이라고_안내(client, monkeypatch):
    monkeypatch.setattr(config, "OPENAI_API_KEY", "")
    monkeypatch.setattr(config, "LLM_MODEL", "")
    r = client.post("/api/ask", json={"user_id": "demo", "text": "다른 편의점도 안 될까?", "demo": True}).json()
    assert r["result"]["intent"] == "stopover_check"
    assert "한 곳뿐이에요" in r["answer"]


def test_첫차_시각으로_출발하면_실시간_없이_그_시각_기준(client, world):
    """밤에 다니는 차가 없으면 앱이 다음 첫차 시각(depart_at)으로 다시 물어봐요 (11/15)"""
    res = plan(client, todo_ids=[], depart_at="2026-11-16T05:30:00+09:00",
               destination={"name": "서울역", "lat": 37.5547, "lng": 126.9707})
    assert res.status_code == 200
    first = res.json()["routes"][0]
    assert first["basis"] == "scheduled" and first["has_realtime"] is False
    assert first["depart_at"].startswith("2026-11-16T05:30")


def test_목적지를_고르고_도착_희망_시간을_넣으면_거꾸로_계산(client, world):
    """이동 탭에서 출발·도착을 직접 골라도 도착 희망 시간 기준으로 계산해요 (11/16 피드백 5)"""
    target = (datetime.now(planner.KST) + timedelta(hours=3)).replace(microsecond=0)
    res = plan(client, todo_ids=[], arrive_by=target.isoformat(),
               destination={"name": "서울역", "lat": 37.5547, "lng": 126.9707})
    assert res.status_code == 200
    body = res.json()
    assert body["basis"] == "arrive_by"
    assert datetime.fromisoformat(body["schedule"]["arrive_by"]) == target
    assert target - datetime.fromisoformat(body["arrive_at"]) == timedelta(minutes=5)


def test_도착_희망_시간이_지났으면_안내(client, world):
    past = (datetime.now(planner.KST) - timedelta(minutes=10)).isoformat(timespec="seconds")
    res = plan(client, todo_ids=[], arrive_by=past,
               destination={"name": "서울역", "lat": 37.5547, "lng": 126.9707})
    assert res.status_code == 422
    assert "지났어요" in res.json()["error"]["message"]


def test_도착_희망_시간_없이_목적지만_고르면_지금_출발(client, world):
    res = plan(client, todo_ids=[], destination={"name": "서울역", "lat": 37.5547, "lng": 126.9707})
    assert res.json()["basis"] == "now" and res.json()["schedule"]["arrive_by"] is None



# ---------- 어느 구간에서 들를지 (11/16 피드백 3) ----------
TRANSFER_ROUTES = [{
    "type": "BUS_AND_SUBWAY", "moving_seconds": 1500, "kakao_total_seconds": 1800, "transfers": 1,
    "fare_min": 1550, "fare_max": 1550,
    "legs": [
        {"type": "BUS", "seconds": 600, "guidance": "273", "stops": ["안암역", "회기역"], "vehicles": ["273"],
         "start": (127.0300, 37.5860), "end": (127.0580, 37.5900), "points": []},
        {"type": "WALKING", "seconds": 120, "guidance": "", "stops": [], "vehicles": [],
         "start": (127.0580, 37.5900), "end": (127.0582, 37.5902), "points": []},
        {"type": "SUBWAY", "seconds": 780, "guidance": "1호선", "stops": ["회기역", "청량리역"], "vehicles": ["1호선"],
         "start": (127.0582, 37.5902), "end": (127.0469, 37.5803), "points": []},
    ],
}]


def _segment_world(monkeypatch, world, extra_by_start):
    """출발 좌표별로 경유하면 더 걷는 초를 정해요. 출발지·환승역·하차역 어디서 들를지 비교하려고요."""
    world["routes"] = TRANSFER_ROUTES

    def route(s, e, via=None, **kw):
        if not via:
            return {"seconds": 120, "legs": [{"seconds": 120, "points": []}]}
        total = 120 + extra_by_start.get(tuple(s), 600)
        return {"seconds": total, "legs": [{"seconds": total // 2, "points": [list(s), list(via[0])]},
                                           {"seconds": total - total // 2, "points": [list(via[0]), list(e)]}]}
    monkeypatch.setattr(planner.kakao, "walk_route", route)


def test_갈아탈_때_들르는_게_가장_덜_늦으면_환승역에서(client, world, monkeypatch):
    # 출발지에서는 10분 더 걷고, 회기역(환승)에서는 1분, 하차역에서는 5분 더 걸어요
    _segment_world(monkeypatch, world, {(127.0580, 37.5900): 60, (127.0469, 37.5803): 300})
    # 54분 뒤 도착: 출발까지 30분 안이라 실시간 차 기준이고, 일찍 나갈 여유로 채울 수 없어요
    setup_user(client, hours=0.9)
    body = plan(client).json()
    stop = body["routes"][0]["todo_stops"][0]
    assert (stop["kind"], stop["leg"]) == ("transfer", 1)
    assert stop["label"] == "회기역에서 갈아타기 전"  # 버스 정류장 이름은 그대로
    assert stop["extra_min"] == 5  # 더 걷는 1분 + 편의점 머무는 4분
    assert {a["kind"] for a in stop["alternatives"]} == {"before", "transfer", "after"}
    todo = body["todos"][0]
    assert todo["segment"]["kind"] == "transfer" and todo["status"] == "포함"


def test_내려서_들르는_게_가장_덜_늦으면_하차역에서(client, world, monkeypatch):
    _segment_world(monkeypatch, world, {(127.0580, 37.5900): 600, (127.0469, 37.5803): 30})
    setup_user(client, hours=0.9)
    stop = plan(client).json()["routes"][0]["todo_stops"][0]
    assert (stop["kind"], stop["leg"]) == ("after", 2)
    assert stop["label"] == "청량리역에서 내려서 목적지 가기 전"  # 이미 "역"으로 끝나면 안 붙여요


def test_출발까지_여유가_많으면_일찍_나가서_타기_전에_들름(client, world, monkeypatch):
    """11/20: 08시에 10시 도착(이동 1시간)인데 편의점 10분이 "갈아타기 전"으로 잡혀 3분밖에 안 되던 문제.
    타기 전에 들르면 그만큼 일찍 나가면 돼서 도착이 늦어지지 않아요."""
    _segment_world(monkeypatch, world, {(127.0580, 37.5900): 60, (127.0469, 37.5803): 300})
    setup_user(client, hours=3)
    body = plan(client).json()
    assert body["basis"] == "arrive_by"
    stop = body["routes"][0]["todo_stops"][0]
    assert (stop["kind"], stop["extra_min"]) == ("before", 0)
    assert {a["kind"] for a in stop["alternatives"]} == {"before", "transfer", "after"}
    assert body["todos"][0]["status"] == "포함"


def test_지금_출발이면_일찍_나갈_수_없어서_덜_늦는_구간(client, world, monkeypatch):
    """도착 희망 시간 없이 지금 출발이면 예전처럼 도착이 가장 덜 늦어지는 곳(갈아타기 전)이에요."""
    _segment_world(monkeypatch, world, {(127.0580, 37.5900): 60, (127.0469, 37.5803): 300})
    setup_user(client, hours=3)
    todo_id = client.get("/api/todos", params={"user_id": "u1"}).json()[0]["id"]
    body = plan(client, todo_ids=[todo_id], destination={"name": "청량리역", "lat": 37.58029, "lng": 127.04691}).json()
    assert body["basis"] == "now"
    assert body["routes"][0]["todo_stops"][0]["kind"] == "transfer"


def test_일찍_나갈_여유는_거꾸로_계산한_경로에서만():
    now = datetime(2026, 11, 21, 8, 0, tzinfo=planner.KST)
    option = planner.RouteOption(timing=None, card={}, places={}, leg={})
    option.times = {"basis": "arrive_by", "depart_at": now + timedelta(minutes=55)}
    assert planner._leave_early_seconds(option, now) == 55 * 60
    for basis in ("realtime", "now", "scheduled"):
        option.times = {"basis": basis, "depart_at": now + timedelta(minutes=55)}
        assert planner._leave_early_seconds(option, now) == 0
    option.times = {"basis": "arrive_by", "depart_at": now - timedelta(minutes=5)}  # 출발 시각이 지났으면 0
    assert planner._leave_early_seconds(option, now) == 0


def test_시간이_부족하면_고른_구간에서도_제외하거나_대기(client, world, monkeypatch):
    _segment_world(monkeypatch, world, {(127.0580, 37.5900): 60})
    setup_user(client, hours=0.5)  # 30분 뒤 도착: 경로만 29분이라 들를 시간이 없어요
    todo = plan(client).json()["todos"][0]
    assert todo["status"] == "대기"



def test_구간_이름은_역을_붙이고_겹친_노선은_한_번만():
    assert planner._stop_name({"type": "SUBWAY", "stops": ["서울역", "시청"]}, end=True) == "시청역"
    assert planner._stop_name({"type": "SUBWAY", "stops": ["동대문역사문화공원(DDP)"]}, end=True) == "동대문역사문화공원역(DDP)"
    assert planner._stop_name({"type": "BUS", "stops": ["안암역", "고려대앞"]}, end=True) == "고려대앞"
    assert planner._unique_lines("1호선·1호선·1호선") == "1호선"


def test_역_이름을_말하면_그_역_근처에서_장소를_찾음(client, live_ask, world, monkeypatch):
    """'동대문역에 꽃집 없어?'를 지금 정류장 근처로 답하던 문제 (11/16)"""
    world["places"] = {"꽃집": [{**CU, "name": "동대문꽃집"}]}
    centers = []
    monkeypatch.setattr(planner.places, "search_by_place_type",
                        lambda t, center, radius_m=300, size=1, **kw: centers.append(center) or world["places"].get(t, []))
    monkeypatch.setattr(planner.kakao, "search_places",
                        lambda near, keyword=None, **kw: [{"name": keyword, "lng": 127.0091, "lat": 37.5657}])
    setup_user(client)
    plan(client)
    body = live_ask("동대문역에 꽃집 어디야?")
    assert centers[-1] == (127.0091, 37.5657)
    assert body["answer"].startswith("동대문역 근처에서 가까운 곳은") and "동대문역에서 왕복" in body["answer"]


# ---------- 다음 차를 타면 더 머물 수 있는지 (11/20) ----------
def test_실시간이면_다음_차_중_도착_희망_안인_차를_알려줌(client, world):
    """40분 뒤 도착: 곧 오는 차(10분 뒤) 말고도 늦지 않는 차가 있으면 앱이 그 차로 머물 시간을 늘려요."""
    setup_user(client)
    body = plan(client).json()
    route = body["routes"][0]
    assert route["basis"] == "realtime"
    later = route["later_boards"]
    assert later, "다음 차 후보가 있어야 해요"
    boards = [datetime.fromisoformat(x["board_at"]) for x in later]
    arrives = [datetime.fromisoformat(x["arrive_at"]) for x in later]
    assert boards == sorted(boards) and boards[0] > datetime.fromisoformat(route["board_at"])
    assert max(arrives) <= datetime.fromisoformat(body["schedule"]["arrive_by"])


def test_거꾸로_계산하거나_지금_출발이면_다음_차_목록이_없음(client, world):
    setup_user(client, hours=3)
    assert "later_boards" not in plan(client).json()["routes"][0]
    body = plan(client, todo_ids=[], destination={"name": "청량리역", "lat": 37.58029, "lng": 127.04691}).json()
    assert body["basis"] == "now" and "later_boards" not in body["routes"][0]


def test_장소_종류가_없는_할_일도_이유와_함께_보여_줌(client, world):
    setup_user(client, todos=(("엄마한테 전화", [], "필수"),))
    todo = plan(client).json()["todos"][0]
    assert (todo["status"], todo["place"]) == ("제외", None)
    assert "장소 종류" in todo["reason"]


def test_실시간이_없으면_카카오_예상_대기로_체류_시간을_계산(client, world):
    """서울시 실시간이 비어도 '지금 출발' 할 일 후보를 통째로 숨기지 않아요 (11/20)."""
    bus_routes = [r for r in world["routes"] if any(leg["type"] == "BUS" for leg in r["legs"])]
    assert bus_routes
    world["routes"] = [dict(bus_routes[0], kakao_total_seconds=2000)]
    world["bus"] = [None, None]
    setup_user(client)
    body = plan(client).json()
    route = body["routes"][0]
    assert route["has_realtime"] is False
    assert route["wait_estimated"] is True
    assert route["max_stay_min"] is not None
    assert body["todos"][0]["place"] is not None

