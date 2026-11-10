"""실시간 경로 계획 테스트. 카카오·서울시 호출은 실제 응답 샘플과 가짜 값으로 바꿔서 외부 호출이 없어요."""
import json
import sqlite3
from datetime import datetime, timedelta
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app import config
from app.services import kakao, planner, seoul_bus

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
