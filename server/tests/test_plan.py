"""경로 계획 API 테스트 (할 일 33번). 시연 모드라 외부 호출이 없어요."""
import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.services.llm import numbers_match

EXAMPLE = json.loads(
    (Path(__file__).resolve().parents[2] / "docs" / "design" / "api-examples" / "plan.json").read_text(encoding="utf-8")
)["examples"][0]


@pytest.fixture()
def client(tmp_path, monkeypatch):
    monkeypatch.setattr("app.config.DATABASE_PATH", str(tmp_path / "test.db"))
    from app.main import app

    with TestClient(app) as c:
        yield c


def plan(client, **body):
    return client.post("/api/plan", json={"demo": True, **body})


def add_todo(client, text, place_types, importance="선택"):
    return client.post("/api/todos", json={
        "user_id": "u1", "text": text, "place_types": place_types, "importance": importance,
    }).json()


def statuses(res) -> dict:
    return {t["text"]: t["status"] for t in res.json()["todos"]}


# ---------- 문서와 같은 응답 ----------
def test_응답이_문서_예시와_같음(client):
    res = client.post("/api/plan", json=EXAMPLE["request"]["body"])
    assert res.status_code == EXAMPLE["response"]["status"]
    assert res.json() == EXAMPLE["response"]["body"]


def test_시연_대본_숫자(client):
    body = plan(client, user_id="demo").json()
    route = body["routes"][0]
    assert (route["wait_min"], route["max_stay_min"], route["total_min"]) == (12, 6, 28)
    assert body["board_at"] == "2026-11-21T08:44:00+09:00"
    assert body["arrive_at"] == "2026-11-21T08:59:17+09:00"


def test_필수_먼저_그리고_상태(client):
    res = plan(client, user_id="demo")
    assert statuses(res) == {"이어폰 사기": "포함", "다이소 들르기": "대기", "커피 사기": "제외"}
    assert [t["text"] for t in res.json()["todos"]] == ["이어폰 사기", "다이소 들르기", "커피 사기"]


def test_대기는_선택지를_줌(client):
    todos = {t["text"]: t for t in plan(client, user_id="demo").json()["todos"]}
    assert todos["다이소 들르기"]["options"] == ["이번엔 빼기", "늦더라도 들르기"]
    assert "options" not in todos["이어폰 사기"]


def test_설명_문장의_숫자는_계산값(client):
    body = plan(client, user_id="demo").json()
    allowed = {2115, 8, 59, body["routes"][0]["wait_min"], body["routes"][0]["max_stay_min"]}
    assert numbers_match(body["explanation"], allowed)


def test_할_일을_고르지_않으면_남은_할_일_전부(client):
    assert len(plan(client, user_id="demo").json()["todos"]) == 3


def test_할_일_하나만_고르기(client):
    demo_id = client.get("/api/todos", params={"user_id": "demo"}).json()[0]["id"]
    res = plan(client, user_id="demo", todo_ids=[demo_id])
    assert statuses(res) == {"이어폰 사기": "포함"}


# ---------- 부스 관객 (자기 할 일로 시연) ----------
def test_관객_할_일도_계산하고_상태_저장(client):
    t = add_todo(client, "우유 사기", ["편의점"], "필수")
    res = plan(client, user_id="u1")
    assert statuses(res) == {"우유 사기": "포함"}
    saved = client.get("/api/todos", params={"user_id": "u1"}).json()
    assert {x["id"]: x["status"] for x in saved} == {t["id"]: "포함"}


def test_시연_지역에_없는_장소는_제외(client):
    add_todo(client, "꽃 사기", ["꽃집"])
    todo = plan(client, user_id="u1").json()["todos"][0]
    assert (todo["status"], todo["place"], todo["reason"]) == ("제외", None, "시연 지역에 없는 장소예요")


def test_들를_곳이_없는_할_일은_계산에서_뺌(client):
    add_todo(client, "엄마한테 전화", [])
    assert plan(client, user_id="u1").json()["todos"] == []


def test_완료한_할_일은_다시_계산하지_않음(client):
    t = add_todo(client, "우유 사기", ["편의점"])
    client.patch(f"/api/todos/{t['id']}", params={"user_id": "u1"}, json={"done": True})
    assert plan(client, user_id="u1").json()["todos"] == []


def test_시연_데이터는_바뀌지_않음(client):
    plan(client, user_id="demo")
    saved = client.get("/api/todos", params={"user_id": "demo"}).json()
    assert {t["status"] for t in saved} == {"대기"}


# ---------- 오류 ----------
def test_다른_사람_할_일은_404(client):
    t = add_todo(client, "우유 사기", ["편의점"])
    res = plan(client, user_id="u2", todo_ids=[t["id"]])
    assert res.status_code == 404
    assert res.json()["error"]["code"] == "not_found"


def test_실시간_계획은_아직_501(client):
    res = client.post("/api/plan", json={"user_id": "demo"})
    assert res.status_code == 501
    assert res.json()["error"]["code"] == "not_ready"


def test_user_id가_없으면_오류_형식(client):
    res = client.post("/api/plan", json={"demo": True})
    assert res.status_code == 422
    assert res.json()["error"]["code"] == "invalid_request"


def test_시연_계획은_외부_API를_부르지_않음(client, monkeypatch):
    from app.services import kakao, llm, seoul_bus, seoul_subway

    def blocked(*args, **kwargs):
        raise AssertionError("외부 호출 금지")

    for module in (kakao, seoul_bus, seoul_subway, llm):
        monkeypatch.setattr(module, "_client", blocked)
    assert plan(client, user_id="demo").status_code == 200
