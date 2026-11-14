"""AI v3 테스트: 상세 경로 삽입 위치 + 일정/할 일 추가 (AI 호출 없이 확인)."""
import json
from datetime import datetime

import pytest
from fastapi.testclient import TestClient

from app import config
from app.services import assistant, llm, rules, trip

NOW = "2026-11-21T08:36:12+09:00"


def steps(*items) -> list[dict]:
    return [{"index": i, **s} for i, s in enumerate(items)]


WALK_STEPS = steps(
    {"kind": "walk", "from": "현재 위치", "to": "안암역 3번 출구",
     "start": "2026-11-21T08:32:00+09:00", "end": "2026-11-21T08:36:00+09:00", "minutes": 4},
    {"kind": "wait", "at": "안암역 3번 출구",
     "start": "2026-11-21T08:36:00+09:00", "end": "2026-11-21T08:44:00+09:00", "minutes": 8},
    {"kind": "ride", "line": "2115번", "from": "안암역 3번 출구", "to": "청량리역환승센터",
     "start": "2026-11-21T08:44:00+09:00", "end": "2026-11-21T08:56:00+09:00", "minutes": 12},
)

TRIP = {
    "phase": "to_stop", "now": NOW,
    "stop_name": "안암역 3번 출구", "board_at": "2026-11-21T08:44:00+09:00",
    "ride_name": "2115번", "arrive_at": "2026-11-21T08:59:17+09:00",
    "destination": "청량리역", "next_vehicles_min": [8, 16],
    "current_step": 0, "steps": WALK_STEPS,
}


@pytest.fixture()
def client(tmp_path, monkeypatch):
    monkeypatch.setattr("app.config.DATABASE_PATH", str(tmp_path / "test.db"))
    from app.main import app

    with TestClient(app) as c:
        yield c


@pytest.fixture()
def ai(monkeypatch):
    replies: list[dict] = []
    monkeypatch.setattr(config, "OPENAI_API_KEY", "TEST")
    monkeypatch.setattr(config, "LLM_MODEL", "test-model")
    monkeypatch.setattr(llm, "_chat_json", lambda system, user: replies.pop(0))
    return replies


@pytest.fixture()
def no_ai(monkeypatch):
    monkeypatch.setattr(config, "OPENAI_API_KEY", "")
    monkeypatch.setattr(config, "LLM_MODEL", "")


def ask(client, text, user_id="demo", demo=True, trip_body=None):
    body = {"user_id": user_id, "text": text, "demo": demo}
    if trip_body is not None:
        body["trip"] = trip_body
    return client.post("/api/ask", json=body).json()


# ---------- trip.insert_at (순수 계산) ----------
def _trip(**kwargs) -> trip.TripIn:
    return trip.TripIn.model_validate({**TRIP, **kwargs})


def test_도보_구간이_정류장까지면_걷는_길에():
    ins = trip.insert_at({"name": "CU 안암센트럴점"}, _trip())
    assert ins["step_index"] == 0 and ins["position"] == "during"
    assert ins["label"] == "안암역 3번 출구로 걷는 길에"


def test_이미_경유지에_있으면_체류_구간():
    body = _trip(
        phase="at_place", place_name="CU 안암센트럴점",
        steps=steps(
            {"kind": "walk", "from": "현재 위치", "to": "CU 안암센트럴점"},
            {"kind": "stay", "at": "CU 안암센트럴점"},
            {"kind": "walk", "from": "CU 안암센트럴점", "to": "안암역 3번 출구"},
        ),
    )
    ins = trip.insert_at({"name": "대학약국"}, body)
    assert ins["step_index"] == 1 and ins["position"] == "at"
    assert ins["label"] == "CU 안암센트럴점에 있는 동안"


def test_정류장에서_기다리는_중이면_대기_구간():
    ins = trip.insert_at({"name": "CU 안암센트럴점"}, _trip(phase="waiting"))
    assert ins["step_index"] == 1 and ins["position"] == "at"
    assert ins["label"] == "안암역 3번 출구에서 기다리는 동안"


def test_장소_이름이_구간에_있으면_그_구간():
    body = _trip(steps=steps(
        {"kind": "walk", "from": "현재 위치", "to": "CU 안암센트럴점"},
        {"kind": "walk", "from": "CU 안암센트럴점", "to": "안암역 3번 출구"},
    ))
    ins = trip.insert_at({"name": "CU 안암센트럴점"}, body)
    assert ins["step_index"] == 0 and ins["position"] == "during"


def test_상세_경로가_없으면_삽입_위치_없음():
    assert trip.insert_at({"name": "CU 안암센트럴점"}, _trip(steps=[])) is None
    assert trip.insert_at({"name": "CU 안암센트럴점"}, _trip(phase="riding")) is None


# ---------- 응답에 삽입 위치 ----------
def test_상세_경로를_보내면_답변에_삽입_위치가_들어감(client, no_ai):
    body = ask(client, "아 이어폰 사야 돼", trip_body=TRIP)
    assert body["result"]["insert_at"]["step_index"] == 0
    assert body["answer"].startswith("안암역 3번 출구로 걷는 길에 CU 안암센트럴점에 들를 수 있어요.")


def test_상세_경로가_없으면_기존_문장_그대로(client, no_ai):
    body = ask(client, "아 이어폰 사야 돼")
    assert "insert_at" not in body["result"]
    assert body["answer"] == "CU 안암센트럴점에 들를 수 있어요. 최대 6분 있을 수 있어요."


# ---------- AI에 주는 context ----------
def test_AI에_현재_시각과_상세_경로와_할일을_보냄(client, ai, monkeypatch):
    sent = {}

    def fake_chat(system, user):
        sent.update(json.loads(user))
        return {"intents": [{"intent": "stopover_check", "place_types": ["편의점"]}]}

    monkeypatch.setattr(llm, "_chat_json", fake_chat)
    client.post("/api/todos", json={"user_id": "u1", "text": "우유 사기", "place_types": ["편의점"]})
    ask(client, "편의점 들러도 돼?", user_id="u1", demo=False, trip_body=TRIP)

    ctx = sent["context"]
    assert ctx["now"] == NOW
    assert ctx["today"] == "2026-11-21 (토)"
    assert ctx["phase_label"] == "정류장으로 가는 중"
    assert [s["label"] for s in ctx["steps"]][0] == "현재 위치 → 안암역 3번 출구"
    assert ctx["steps"][0]["start"] == "08:32"
    assert ctx["current_step"] == 0
    assert any(t["text"] == "우유 사기" for t in ctx["todos"])


def test_상세_경로가_없어도_context에_현재_시각은_들어감(client, ai, monkeypatch):
    sent = {}

    def fake_chat(system, user):
        sent.update(json.loads(user))
        return {"intents": [{"intent": "unsupported"}]}

    monkeypatch.setattr(llm, "_chat_json", fake_chat)
    ask(client, "점심 뭐 먹지?", user_id="u1", demo=False)
    assert "steps" not in sent["context"] and "phase" not in sent["context"]
    assert sent["context"]["now"].startswith("20")


# ---------- 일정 추가 ----------
def test_일정_추가는_이름과_목적지만_초안으로_준다(client, ai):
    ai.append({"intents": [{"intent": "add_schedule", "title": "치과 예약",
                            "location": "강남역", "place_types": []}]})
    body = ask(client, "내일 오후 3시에 강남역에서 치과 예약 추가해 줘", user_id="u1", demo=False)
    assert body["schedule"] == {"title": "치과 예약", "location": "강남역"}
    assert body["result"]["intent"] == "add_schedule"
    assert body["result"]["schedule"] == {"title": "치과 예약", "location": "강남역"}
    assert "치과 예약" in body["answer"]
    # 저장하지 않았어요 (앱의 일정 화면에서 확인 후 저장)
    assert client.get("/api/schedules", params={"user_id": "u1"}).json() == []


def test_일정_이름이_없으면_되묻고_일정은_안_만듦(client, ai):
    ai.append({"intents": [{"intent": "add_schedule", "title": "", "location": "", "place_types": []}]})
    body = ask(client, "일정 추가해 줘", user_id="u1", demo=False)
    assert body["needs_confirm"] is True
    assert "무슨 일정" in body["question"]
    assert body["result"] is None and "schedule" not in body


def test_일정_요청_표현이_없으면_일정_추가가_아님(no_ai):
    out = rules.classify_question("내일 3시까지 광화문에 가야 해")
    assert all(i["intent"] != "add_schedule" for i in out["intents"])


def test_키워드_규칙으로도_일정_초안(no_ai):
    out = rules.classify_question("내일 오후 3시에 강남역에서 치과 예약 추가해 줘")
    item = out["intents"][0]
    assert item["intent"] == "add_schedule"
    assert item["title"] == "치과" and item["location"] == "강남역"


# ---------- 할 일 추가 ----------
def test_나중에_할_일은_할일_초안으로_준다(client, no_ai):
    body = ask(client, "나중에 약국에서 약 사기", user_id="u1", demo=False)
    assert body["result"]["intent"] == "add_todo"
    assert body["result"]["text"] == "약 사기"
    assert body["todo"]["text"] == "약 사기"
    assert body["todo"]["place_types"] == ["약국"]
    assert "환각" not in body["answer"]
    # 자동 저장하지 않음 → 앱의 "할 일 목록에 추가" 버튼으로 확인
    assert "id" not in body["todo"]
    assert client.get("/api/todos", params={"user_id": "u1"}).json() == []


def test_시간이_부족해도_나중에_할_일로_남길_수_있음(client, no_ai):
    body = ask(client, "다이소에서 슬리퍼 사야되는데")
    assert body["result"]["feasible"] is False
    assert body["result"]["can_add_todo"] is True
    assert body["todo"] is not None and "id" not in body["todo"]
    assert body["answer"] == "시간이 부족해요. 도착한 뒤에 들르는 걸 추천해요."


def test_아_우유_사야_돼는_여전히_들르기(client, no_ai):
    body = ask(client, "아 우유 사야 돼")
    assert body["intents"][0]["intent"] == "stopover_check"
    assert body["result"]["feasible"] is True


def test_들르기와_할일_추가를_한_번에(client, ai):
    ai.append({"intents": [
        {"intent": "stopover_check", "place_types": ["편의점"]},
        {"intent": "add_todo", "text": "약 사기", "place_types": ["약국"], "importance": None},
    ]})
    # stopover_check는 시연 경로로 계산하므로 demo 사용자로 물어봐요
    body = ask(client, "지금 편의점 들러서 우유 사고, 나중에 약국에서 약 사기")
    assert [i["intent"] for i in body["intents"]] == ["stopover_check", "add_todo"]
    assert body["todo"]["text"] == "약 사기"
    assert "들를 수 있어요" in body["answer"]
    assert "약 사기" in body["answer"]


def test_질문형_들르기는_할_일_이름을_다듬음():
    """11/14: '커피 사도 돼?'가 할 일 이름 그대로 저장되던 문제."""
    from app.services import rules
    assert rules.todo_text("커피 사도 돼?") == "커피 사기"
    assert rules.todo_text("편의점 들러도 돼?") == "편의점 들르기"
    assert rules.todo_text("약국 들렀다 가도 안 늦어?") == "약국 들르기"
    assert rules.todo_text("아 우유 사야 돼") == "우유 사기"
