"""이동 중 질문 (11/13): 앱이 보낸 지금 단계와 시각으로 답해요."""
import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.services import trip

NOW = "2026-11-21T08:36:00+09:00"
BASE = {"now": NOW, "place_name": "CU 안암점", "leave_place_at": "2026-11-21T08:40:00+09:00",
        "stop_name": "안암역3번출구", "board_at": "2026-11-21T08:44:00+09:00", "ride_name": "2115번",
        "arrive_at": "2026-11-21T08:59:00+09:00", "destination": "청량리역", "next_vehicles_min": [8, 16]}


@pytest.fixture()
def client(tmp_path, monkeypatch):
    monkeypatch.setattr("app.config.DATABASE_PATH", str(tmp_path / "test.db"))
    monkeypatch.setattr("app.config.OPENAI_API_KEY", "")  # 질문 분류는 규칙으로 (외부 호출 없이)
    with TestClient(app) as c:
        yield c


def ask(client, text, phase, **extra):
    body = {"user_id": "u1", "text": text, "demo": False, "trip": {**BASE, "phase": phase, **extra}}
    res = client.post("/api/ask", json=body)
    assert res.status_code == 200, res.text
    return res.json()


def test_가게에_있을_때_남은_시간(client):
    out = ask(client, "몇 분 남았어?", "at_place")
    assert out["answer"] == "CU 안암점에서 4분 더 있어도 돼요. 8시 40분에 나오면 2115번을 탈 수 있어요."
    assert out["result"]["minutes"] == 4 and out["result"]["phase"] == "at_place"


def test_가게에서_나갈_시간이_지났으면_지금_나가기(client):
    out = ask(client, "몇 분 남았어?", "at_place", now="2026-11-21T08:41:00+09:00")
    assert out["answer"] == "지금 나가야 2115번을 탈 수 있어요."


def test_정류장으로_가는_중_남은_시간(client):
    out = ask(client, "몇 분 남았어?", "to_stop")
    assert out["answer"] == "안암역3번출구에서 8시 44분에 2115번을 타요. 8분 남았어요."


def test_타는_중이면_도착까지(client):
    out = ask(client, "몇 분 남았어?", "riding")
    assert out["answer"] == "청량리역에 8시 59분 도착 예정이에요. 23분 남았어요."


def test_다음_차는_앱이_보낸_실시간으로(client):
    out = ask(client, "다음 버스 언제야?", "waiting")
    assert out["answer"] == "2115번이 8분 뒤에 와요. 그다음 차는 16분 뒤예요."


def test_타고_있으면_다음_차_대신_도착(client):
    out = ask(client, "다음 버스 언제야?", "riding")
    assert out["answer"] == "이미 2115번을 탔어요. 8시 59분 도착 예정이에요."


def test_가게에서_조금_늦어도_괜찮음(client):
    out = ask(client, "3분 늦을 것 같아", "at_place")
    assert out["result"]["on_time"] is True
    assert out["answer"].startswith("3분 늦어도 괜찮아요.")


def test_가게에서_많이_늦으면_가게를_빼라고(client):
    out = ask(client, "10분 늦을 것 같아", "at_place")
    assert out["result"]["on_time"] is False
    assert "CU 안암점은 빼고 바로 정류장으로" in out["answer"]


def test_정류장_가는_중_늦으면_다음_차(client):
    # 8분 뒤 차를 타려다 10분 늦으면 18분 뒤에 정류장 → 16분 뒤 차도 못 타고 20분 뒤 차
    out = ask(client, "10분 늦을 것 같아", "to_stop", next_vehicles_min=[8, 16, 20])
    assert out["answer"] == "10분 늦으면 8시 44분 2115번을 놓쳐요. 다음 차는 20분 뒤예요."


def test_늦었는데_탈_차를_모르면_새로고침(client):
    out = ask(client, "10분 늦을 것 같아", "to_stop")
    assert out["answer"].endswith("경로를 새로고침해서 다음 차를 확인해 주세요.")


def test_이동_중이_아니면_예전처럼(client):
    res = client.post("/api/ask", json={"user_id": "u1", "text": "점심 뭐 먹지?", "demo": False})
    assert res.json()["result"]["intent"] == "unsupported"


def test_단계로_답하지_않는_질문은_원래_처리():
    item = {"intent": "place_info", "place_types": ["약국"], "delay_minutes": None}
    t = trip.TripIn(phase="at_place", now=NOW)
    assert trip.answer(item, t) is None


def test_지하철_이름_조사():
    assert trip._josa("2호선", "을를") == "2호선을"
    assert trip._josa("2115번", "이가") == "2115번이"
    assert trip._josa("7720", "이가") == "7720이"


def test_버스를_놓치면_다음_차(client):
    # 11/13: 기다리는 중 "응 버스 놓쳤어" → 남은 시간을 그대로 말하던 문제
    out = ask(client, "응 버스 놓쳤어", "waiting")
    assert out["answer"] == "2115번을 놓쳤으면 다음 차는 16분 뒤(8시 52분)에 와요."
    assert out["result"]["missed"] is True


def test_놓쳤는데_다음_차를_모르면_새로고침(client):
    out = ask(client, "버스 놓쳤어", "to_stop", next_vehicles_min=[8])
    assert "새로고침" in out["answer"]


def test_범위_밖으로_분류돼도_놓쳤으면_다음_차():
    item = {"intent": "unsupported", "place_types": [], "delay_minutes": None}
    t = trip.TripIn(**{**BASE, "phase": "waiting", "next_vehicles_min": [8, 16]})
    result, answer = trip.answer(item, t, "아 놓쳐버렸네")
    assert result["missed"] is True and "16분 뒤" in answer
