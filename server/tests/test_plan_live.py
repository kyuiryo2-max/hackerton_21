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
    monkeypatch.setattr(planner.places, "search_by_place_type",
                        lambda t, center, radius_m=300, size=1: w["places"].get(t, []))
    monkeypatch.setattr(planner.seoul_bus, "match_leg", lambda leg: {"arrival": {
        "first_seconds": w["bus"][0], "second_seconds": w["bus"][1], "interval_minutes": 10}})
    monkeypatch.setattr(planner.seoul_subway, "match_leg", lambda leg: {"trains": [{"seconds": 300}]})
    return w


def setup_user(client, hours=2, todos=(("우유 사기", ["편의점"], "필수"),)):
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
    assert (todo["status"], todo["place"]["name"], todo["detour_min"]) == ("포함", "CU 안암역점", 5)


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


def test_현재_좌표가_들어간_호출은_캐시하지_않음(client, world, monkeypatch):
    seen = []
    monkeypatch.setattr(planner.kakao, "transit_routes",
                        lambda s, e, use_cache=True: seen.append(("transit", use_cache)) or world["routes"])
    monkeypatch.setattr(planner.kakao, "walk_seconds",
                        lambda s, e, via=None, use_cache=True: seen.append(("walk", s, use_cache)) or (300 if via else 120))
    setup_user(client)
    plan(client)
    origin = (ORIGIN["lng"], ORIGIN["lat"])
    assert ("transit", False) in seen
    assert all(not used for kind, *rest, used in seen if kind == "walk" and rest[0] == origin)


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
    world["places"] = {"편의점": [{**CU, "distance_m": 80}, GS], "다이소": [DAISO]}
    return asked


def test_장소_종류_여러_개에서_후보를_모아_도보가_짧은_순(client, walks):
    setup_user(client, todos=(("이어폰 사기", ["편의점", "다이소"], "필수"),))
    todo = plan(client).json()["todos"][0]
    assert [c["name"] for c in todo["candidates"]] == ["GS25 안암점", "CU 안암역점", "다이소 안암점"]
    assert [c["detour_min"] for c in todo["candidates"]] == [4, 5, 10]
    assert {c["place_type"] for c in todo["candidates"]} == {"편의점", "다이소"}
    # 계산은 가장 가까운 후보로 해요
    assert todo["place"]["name"] == "GS25 안암점" and todo["detour_min"] == 4
    assert (todo["place"]["lng"], todo["place"]["lat"]) == (GS["lng"], GS["lat"])


def test_후보는_최대_3곳이고_먼_곳은_도보를_재지_않음(client, walks, world):
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
