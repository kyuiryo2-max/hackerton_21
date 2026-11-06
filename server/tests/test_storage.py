"""저장·조회 API 테스트 (작업 표 16번). test_health.py 처럼 임시 DB를 써요."""
import sqlite3

import pytest
from fastapi.testclient import TestClient


@pytest.fixture()
def client(tmp_path, monkeypatch):
    monkeypatch.setattr("app.config.DATABASE_PATH", str(tmp_path / "test.db"))
    from app.main import app

    with TestClient(app) as c:
        yield c


# ---------- 일정 ----------
def test_일정_저장하고_조회(client):
    res = client.post("/api/schedules", json={
        "user_id": "u1", "destination": "공학관", "arrive_by": "2026-11-21T09:00", "prep_minutes": 40,
    })
    assert res.status_code == 201
    saved = res.json()
    assert saved["arrive_by"] == "2026-11-21T09:00"
    assert client.get(f"/api/schedules/{saved['id']}").json() == saved
    assert client.get("/api/schedules", params={"user_id": "u1"}).json() == [saved]


def test_시간대가_붙어_와도_한국_시간으로(client):
    res = client.post("/api/schedules", json={
        "user_id": "u1", "destination": "공학관", "arrive_by": "2026-11-21T00:00:00Z",
    })
    assert res.json()["arrive_by"] == "2026-11-21T09:00"
    assert res.json()["prep_minutes"] == 30  # 기본값


def test_일정_수정은_보낸_값만(client):
    s = client.post("/api/schedules", json={
        "user_id": "u1", "destination": "공학관", "arrive_by": "2026-11-21T09:00",
    }).json()
    res = client.patch(f"/api/schedules/{s['id']}", json={"prep_minutes": 10})
    assert res.json()["prep_minutes"] == 10
    assert res.json()["destination"] == "공학관"


def test_일정_삭제(client):
    s = client.post("/api/schedules", json={
        "user_id": "u1", "destination": "공학관", "arrive_by": "2026-11-21T09:00",
    }).json()
    assert client.delete(f"/api/schedules/{s['id']}").json() == {"ok": True}
    assert client.get(f"/api/schedules/{s['id']}").status_code == 404


# ---------- 할 일 ----------
def test_할_일_저장하고_필수_먼저_조회(client):
    client.post("/api/todos", json={"user_id": "u1", "text": "선물", "place_types": ["꽃집"]})
    client.post("/api/todos", json={"user_id": "u1", "text": "약 사기", "place_types": ["약국"], "importance": "필수"})
    todos = client.get("/api/todos", params={"user_id": "u1"}).json()
    assert [t["text"] for t in todos] == ["약 사기", "선물"]
    assert todos[0]["place_types"] == ["약국"]
    assert todos[0]["done"] is False


def test_들르기_질문은_필수_할_일로(client):
    """stopover_check: '아 우유 사야 돼' → 중요도 높은(필수) 할 일로 등록"""
    res = client.post("/api/todos", json={
        "user_id": "u1", "text": "우유 사기", "place_types": ["편의점"], "importance": "필수",
    })
    assert res.status_code == 201
    assert res.json()["importance"] == "필수"


def test_할_일_변경_완료_삭제(client):
    """change_todo: '선물이 더 급해', '약은 안 사도 돼'"""
    t = client.post("/api/todos", json={"user_id": "u1", "text": "선물", "place_types": ["꽃집"]}).json()
    assert client.patch(f"/api/todos/{t['id']}", json={"importance": "필수"}).json()["importance"] == "필수"
    client.patch(f"/api/todos/{t['id']}", json={"done": True})
    assert client.get("/api/todos", params={"user_id": "u1", "done": False}).json() == []
    assert client.delete(f"/api/todos/{t['id']}").json() == {"ok": True}
    assert client.patch(f"/api/todos/{t['id']}", json={"done": True}).status_code == 404


def test_목록에_없는_장소_종류는_거절(client):
    res = client.post("/api/todos", json={"user_id": "u1", "text": "x", "place_types": ["우주정거장"]})
    assert res.status_code == 422


def test_목록에_없는_중요도는_거절(client):
    res = client.post("/api/todos", json={"user_id": "u1", "text": "x", "importance": "보통"})
    assert res.status_code == 422


# ---------- 설정 ----------
def test_설정_기본값과_저장(client):
    assert client.get("/api/settings/u1").json() == {
        "user_id": "u1", "w_time": 0.6, "w_transfer": 0.3, "w_fare": 0.1,
    }
    res = client.put("/api/settings/u1", json={"w_transfer": 0.5})
    assert res.json()["w_transfer"] == 0.5
    assert res.json()["w_time"] == 0.6  # 안 보낸 값은 그대로
    assert client.get("/api/settings/u1").json()["w_transfer"] == 0.5


# ---------- 경로 선택 기록 ----------
def test_경로_선택_기록(client):
    res = client.post("/api/choices", json={
        "user_id": "u1",
        "chosen_route": {"total_min": 42, "transfers": 1, "fare": 1500},
        "other_routes": [{"total_min": 48, "transfers": 0, "fare": 1500}],
    })
    assert res.status_code == 201
    choices = client.get("/api/choices", params={"user_id": "u1"}).json()
    assert choices[0]["chosen_route"]["transfers"] == 1
    assert choices[0]["other_routes"][0]["total_min"] == 48


# ---------- 공통 ----------
def test_시연_데이터가_조회됨(client):
    assert client.get("/api/schedules", params={"user_id": "demo"}).json()[0]["destination"] == "공학관"
    texts = [t["text"] for t in client.get("/api/todos", params={"user_id": "demo"}).json()]
    assert texts == ["약 사기", "엄마 생신 선물"]


def test_사용자끼리_섞이지_않음(client):
    client.post("/api/todos", json={"user_id": "u1", "text": "약 사기", "place_types": ["약국"]})
    assert client.get("/api/todos", params={"user_id": "u2"}).json() == []


def test_없는_항목은_404_오류_형식(client):
    res = client.get("/api/schedules/9999")
    assert res.status_code == 404
    assert res.json()["error"]["code"] == "not_found"


def test_위치는_저장하지_않음(client, tmp_path):
    client.post("/api/schedules", json={
        "user_id": "u1", "destination": "공학관", "arrive_by": "2026-11-21T09:00",
        "lat": 37.58, "lng": 127.02,  # 보내도 무시
    })
    with sqlite3.connect(tmp_path / "test.db") as conn:
        for table in ("schedules", "todos", "settings", "route_choices"):
            cols = {r[1] for r in conn.execute(f"PRAGMA table_info({table})")}
            assert not cols & {"lat", "lng", "location", "current_location"}
