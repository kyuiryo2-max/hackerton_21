"""AI 이해·대화 API 테스트 (할 일 33·38번). AI는 가짜 응답으로 바꿔서 외부 호출이 없어요."""
import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app import config
from app.services import assistant, llm, rules

EXAMPLES = Path(__file__).resolve().parents[2] / "docs" / "design" / "api-examples"
AI_ONLY = ("engine",)  # 서버가 붙이는 필드


def examples(name: str) -> list[dict]:
    return json.loads((EXAMPLES / f"{name}.json").read_text(encoding="utf-8"))["examples"]


@pytest.fixture()
def client(tmp_path, monkeypatch):
    monkeypatch.setattr("app.config.DATABASE_PATH", str(tmp_path / "test.db"))
    from app.main import app

    with TestClient(app) as c:
        yield c


@pytest.fixture()
def ai(monkeypatch):
    """AI 키가 있는 상태로 만들고, AI가 돌려줄 값을 정해요."""
    replies = []
    monkeypatch.setattr(config, "OPENAI_API_KEY", "TEST")
    monkeypatch.setattr(config, "LLM_MODEL", "test-model")
    monkeypatch.setattr(llm, "_chat_json", lambda system, user: replies.pop(0))
    return replies


@pytest.fixture()
def no_ai(monkeypatch):
    monkeypatch.setattr(config, "OPENAI_API_KEY", "")
    monkeypatch.setattr(config, "LLM_MODEL", "")


def ask(client, text, user_id="demo", demo=True):
    return client.post("/api/ask", json={"user_id": user_id, "text": text, "demo": demo}).json()


# ---------- 문서와 같은 응답 ----------
def test_할_일_이해_응답이_문서_예시와_같음(client, ai):
    for e in examples("tasks_parse"):
        want = e["response"]["body"]
        ai.append({k: v for k, v in want.items() if k not in AI_ONLY})
        res = client.post(e["request"]["path"], json=e["request"]["body"])
        assert res.status_code == e["response"]["status"]
        assert res.json() == want


def test_질문_응답이_문서_예시와_같음(client, ai):
    for e in examples("ask"):
        want = e["response"]["body"]
        ai.append({"intents": want["intents"], "needs_confirm": want["needs_confirm"], "question": want["question"]})
        res = client.post(e["request"]["path"], json=e["request"]["body"])
        assert res.status_code == e["response"]["status"]
        assert res.json() == want, e["request"]["body"]["text"]


# ---------- AI가 없을 때 ----------
def test_AI_키가_없으면_키워드_규칙(client, no_ai):
    body = ask(client, "다음 버스 언제야?")
    assert body["engine"] == "rule"
    assert body["answer"] == "2115번이 12분 뒤에 와요. 그다음 차는 20분 뒤예요."


def test_AI가_실패하면_키워드_규칙(client, monkeypatch):
    monkeypatch.setattr(config, "OPENAI_API_KEY", "TEST")
    monkeypatch.setattr(config, "LLM_MODEL", "test-model")

    def broken(system, user):
        raise TimeoutError("AI 응답 없음")

    monkeypatch.setattr(llm, "_chat_json", broken)
    assert ask(client, "다음 버스 언제야?")["engine"] == "rule"
    assert client.post("/api/tasks/parse", json={"user_id": "u1", "text": "커피 사기"}).json()["engine"] == "rule"


# ---------- 시연 대본 ----------
def test_대본_편의점은_들를_수_있음(client, no_ai):
    body = ask(client, "아 이어폰 사야 돼")
    assert body["result"]["feasible"] is True
    assert body["result"]["max_stay_min"] == 6
    assert body["todo"]["status"] == "포함"


def test_대본_다이소는_시간이_부족(client, no_ai):
    body = ask(client, "다이소도 들러도 돼?")
    assert body["result"]["feasible"] is False
    assert body["answer"] == "시간이 부족해요. 도착한 뒤에 들르는 걸 추천해요."
    assert body["todo"]["status"] == "대기"


def test_대본_10분_늦으면_다시_계산(client, no_ai):
    body = ask(client, "10분 늦을 것 같아")
    assert body["result"]["delay_minutes"] == 10
    assert body["result"]["board_at"] == "2026-11-21T08:44:00+09:00"
    assert body["result"]["on_time"] is True


def test_늦어서_다음_차를_타면_늦는다고_알림(client, no_ai):
    body = ask(client, "15분 늦을 것 같아")
    assert body["result"]["on_time"] is False
    assert body["answer"].endswith("도착 희망 시각보다 늦어요.")


def test_남은_시간은_여유를_빼고_알림(client, no_ai):
    body = ask(client, "몇 분까지 나가면 돼?")
    assert body["result"]["leave_by"] == "2026-11-21T08:42:00+09:00"
    assert body["result"]["minutes"] == 10


def test_장소_정보(client, no_ai):
    assert ask(client, "근처 편의점 어디야?")["answer"] == "가까운 곳은 CU 안암센트럴점이에요. (서울 성북구 고려대로28길 16)"
    assert ask(client, "근처 약국 어디야?")["answer"] == "시연 지역에서는 약국을 찾지 못했어요."


def test_범위_밖_질문(client, no_ai):
    body = ask(client, "점심 뭐 먹지?")
    assert body["result"] == {"intent": "unsupported"}


def test_장소가_없으면_되물음(client, no_ai):
    body = ask(client, "거기 들러도 돼?")
    assert body["needs_confirm"] is True
    assert body["result"] is None
    assert body["answer"] == body["question"]


# ---------- 저장 ----------
def test_질문과_답변을_기록(client, no_ai):
    ask(client, "다음 버스 언제야?", user_id="u1")
    messages = client.get("/api/messages", params={"user_id": "u1"}).json()
    assert [m["role"] for m in messages] == ["user", "assistant"]
    assert messages[0]["intents"][0]["intent"] == "next_vehicle"


def test_들르기_질문은_필수_할_일로_저장(client, no_ai):
    body = ask(client, "아 이어폰 사야 돼", user_id="u1")
    saved = client.get("/api/todos", params={"user_id": "u1"}).json()
    assert len(saved) == 1
    assert (saved[0]["id"], saved[0]["source"], saved[0]["importance"], saved[0]["status"]) == (
        body["todo"]["id"], "질문", "필수", "포함",
    )


def test_시연_사용자의_할_일은_저장하지_않음(client, no_ai):
    ask(client, "아 이어폰 사야 돼")
    texts = [t["text"] for t in client.get("/api/todos", params={"user_id": "demo"}).json()]
    assert texts == ["이어폰 사기", "다이소 들르기", "커피 사기"]


def test_할_일_빼기(client, no_ai):
    client.post("/api/todos", json={"user_id": "u1", "text": "커피 사기", "place_types": ["카페"]})
    assert ask(client, "커피는 안 사도 돼", user_id="u1")["answer"] == "커피 사기는 이번엔 뺄게요."
    assert client.get("/api/todos", params={"user_id": "u1"}).json()[0]["status"] == "제외"


def test_이미_넣은_할_일과_함께_판단(client, no_ai):
    ask(client, "아 이어폰 사야 돼", user_id="u1")
    assert ask(client, "커피 사야 돼", user_id="u1")["result"]["feasible"] is False


def test_실시간_모드는_아직_안내만(client, no_ai):
    body = ask(client, "다음 버스 언제야?", user_id="u1", demo=False)
    assert body["result"] == {"intent": "next_vehicle", "available": False}
    assert body["answer"] == assistant.NOT_READY_ANSWER


# ---------- 입력 ----------
def test_너무_긴_질문은_오류_형식(client):
    res = client.post("/api/ask", json={"user_id": "u1", "text": "가" * 201})
    assert res.status_code == 422
    assert res.json()["error"]["code"] == "invalid_request"


# ---------- 키워드 규칙 ----------
@pytest.mark.parametrize("text, places", [
    ("우유 사기", ["편의점"]),
    ("과제 출력", ["프린트"]),
    ("엄마 생신 선물 사야 해", []),  # 규칙으로는 알 수 없어서 되묻기
])
def test_할_일_규칙(text, places):
    assert rules.parse_todo(text)["place_types"] == places


def test_할_일_규칙_중요도():
    assert rules.parse_todo("과제 출력 꼭 해야 함")["importance"] == "필수"


def test_질문_규칙_늦어짐과_분():
    item = rules.classify_question("몇 분 늦을 것 같아, 10분")["intents"][0]
    assert (item["intent"], item["delay_minutes"]) == ("running_late", 10)


def test_질문_규칙_구매_문장():
    assert rules.todo_text("아 이어폰 사야 돼") == "이어폰 사기"
