"""오류 처리 테스트 (할 일 #42). 어떤 오류든 {"error": {"code", "message"}} 한 형식으로 답해요."""
import sqlite3

import pytest
from fastapi.testclient import TestClient

from app import config
from app.db import repository as repo
from app.services import demo, llm

WEB = {"Origin": "https://kyuiryo2-max.github.io"}  # 배포된 Flutter 웹 주소


@pytest.fixture()
def client(tmp_path, monkeypatch):
    monkeypatch.setattr("app.config.DATABASE_PATH", str(tmp_path / "test.db"))
    from app.main import app

    # 서버 오류를 테스트 실패로 올리지 않고 실제 응답으로 받아요
    with TestClient(app, raise_server_exceptions=False) as c:
        yield c


@pytest.fixture()
def ai(monkeypatch):
    replies = []
    monkeypatch.setattr(config, "OPENAI_API_KEY", "TEST")
    monkeypatch.setattr(config, "LLM_MODEL", "test-model")
    monkeypatch.setattr(llm, "_chat_json", lambda system, user: replies.pop(0))
    return replies


# ---------- 예상 못 한 오류 ----------
def test_코드_오류도_같은_형식(client, monkeypatch):
    monkeypatch.setattr(demo, "arrivals", lambda *a, **k: 1 / 0)
    res = client.get("/api/arrivals", params={"stop_id": "08301", "demo": True}, headers=WEB)
    assert res.status_code == 500
    assert res.json()["error"]["code"] == "server_error"


def test_오류_내용은_응답에_드러내지_않음(client, monkeypatch):
    def broken(*a, **k):
        raise RuntimeError("비밀 TEST-KEY 와 내부 경로 C:/dev")

    monkeypatch.setattr(demo, "arrivals", broken)
    res = client.get("/api/arrivals", params={"stop_id": "08301", "demo": True})
    assert "TEST-KEY" not in res.text and "C:/dev" not in res.text and "Traceback" not in res.text


def test_오류_응답에도_CORS_헤더(client, monkeypatch):
    """CORS 헤더가 없으면 Flutter 웹이 오류 본문을 읽지 못해요"""
    monkeypatch.setattr(demo, "arrivals", lambda *a, **k: 1 / 0)
    res = client.get("/api/arrivals", params={"stop_id": "08301", "demo": True}, headers=WEB)
    assert res.headers.get("access-control-allow-origin") == "*"


def test_DB가_잠기면_503(client, monkeypatch):
    def locked(*a, **k):
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(repo, "list_todos", locked)
    res = client.get("/api/todos", params={"user_id": "u1"})
    assert res.status_code == 503
    assert res.json()["error"]["code"] == "db_busy"


def test_정상_요청은_그대로(client):
    assert client.get("/health").json() == {"status": "ok"}


# ---------- AI 출력 형식 ----------
def test_AI_할_일_출력이_깨지면_키워드_규칙(client, ai):
    ai.append({"place_types": "편의점"})  # 목록이 아니라 글자
    body = client.post("/api/tasks/parse", json={"user_id": "u1", "text": "우유 사기"}).json()
    assert body["engine"] == "rule"
    assert body["place_types"] == ["편의점"]


def test_AI_할_일_출력은_항상_같은_모양(client, ai):
    ai.append({"place_types": ["카페"]})  # type, text, importance, needs_confirm 없음
    body = client.post("/api/tasks/parse", json={"user_id": "u1", "text": "커피 사기"}).json()
    assert set(body) == {"type", "text", "place_types", "importance", "needs_confirm", "engine"}
    assert (body["type"], body["text"], body["importance"], body["needs_confirm"]) == ("todo", "커피 사기", None, False)


def test_AI_질문_출력이_깨지면_키워드_규칙(client, ai):
    ai.append({"intents": "이상한 값"})
    body = client.post("/api/ask", json={"user_id": "u1", "text": "다음 버스 언제야?", "demo": True}).json()
    assert body["engine"] == "rule"
    assert body["answer"].startswith("2115번이")


def test_AI가_일부러_되물으면_그대로(client, ai):
    ai.append({"intents": [{"intent": "stopover_check", "place_types": []}], "needs_confirm": True,
               "question": "어디를 들르고 싶은지 알려 줄래요?"})
    body = client.post("/api/ask", json={"user_id": "u1", "text": "거기 들러도 돼?", "demo": True}).json()
    assert (body["engine"], body["question"]) == ("ai", "어디를 들르고 싶은지 알려 줄래요?")
