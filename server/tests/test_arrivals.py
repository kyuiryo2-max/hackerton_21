"""실시간 도착 API 테스트. 서울시 버스·지하철 응답은 data/samples 실제 응답으로 바꿔서 외부 호출이 없어요."""
import json
from datetime import datetime
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

from app import config
from app.services import seoul_bus, seoul_subway

SAMPLES = Path(__file__).resolve().parents[2] / "data" / "samples"
BUS = json.loads((SAMPLES / "seoul_bus_arrivals.json").read_text(encoding="utf-8"))
SUBWAY = json.loads((SAMPLES / "seoul_subway.json").read_text(encoding="utf-8"))
SUBWAY_TIME = datetime(2026, 11, 5, 17, 8, 0, tzinfo=seoul_subway.KST)  # 샘플을 받은 시각


@pytest.fixture()
def client(tmp_path, monkeypatch):
    monkeypatch.setattr("app.config.DATABASE_PATH", str(tmp_path / "test.db"))
    monkeypatch.setattr(config, "DATA_GO_KR_SERVICE_KEY", "TEST-KEY")
    monkeypatch.setattr(config, "SEOUL_OPEN_API_KEY", "TEST-KEY")
    seoul_bus.clear_cache()
    seoul_subway.clear_cache()
    from app.main import app

    with TestClient(app) as c:
        yield c


@pytest.fixture()
def upstream(monkeypatch):
    """서울시 API 대신 샘플을 돌려줘요. 호출된 주소를 기록해요."""
    calls = []

    def handler(request):
        calls.append(request)
        if "ws.bus.go.kr" in str(request.url):
            return httpx.Response(200, json=BUS)
        return httpx.Response(200, json=SUBWAY)

    transport = httpx.MockTransport(handler)
    monkeypatch.setattr(seoul_bus, "_client", lambda: httpx.Client(transport=transport))
    monkeypatch.setattr(seoul_subway, "_client", lambda: httpx.Client(transport=transport))
    # 지하철 샘플의 수신 시각 기준으로 남은 시간을 계산해요
    original = seoul_subway.parse_arrivals
    monkeypatch.setattr(seoul_subway, "parse_arrivals", lambda data, now=None: original(data, SUBWAY_TIME))
    return calls


# ---------- 버스 ----------
def test_버스_실시간_도착(client, upstream):
    res = client.get("/api/arrivals", params={"stop_id": "08301"})
    assert res.status_code == 200
    body = res.json()
    by_route = {a["route"]: a for a in body["arrivals"]}
    # 샘플: 2115번 39초(곧 도착), 613초 → 분은 내림
    assert by_route["2115"] == {"route": "2115", "minutes": 0, "next_minutes": 10, "direction": "중랑공영차고지"}
    assert body["fetched_at"].endswith("+09:00")


def test_버스_같은_정류소는_잠시_저장(client, upstream):
    client.get("/api/arrivals", params={"stop_id": "08301"})
    client.get("/api/arrivals", params={"stop_id": "08301"})
    assert len(upstream) == 1


def test_버스_정류소가_없으면_빈_목록(client, monkeypatch):
    transport = httpx.MockTransport(lambda r: httpx.Response(200, json={
        "msgHeader": {"headerCd": "4", "headerMsg": "결과가 없습니다."}, "msgBody": {"itemList": None},
    }))
    monkeypatch.setattr(seoul_bus, "_client", lambda: httpx.Client(transport=transport))
    assert client.get("/api/arrivals", params={"stop_id": "00000"}).json()["arrivals"] == []


# ---------- 지하철 ----------
def test_지하철_방향별로_묶음(client, upstream):
    res = client.get("/api/arrivals", params={"station": "안암(고대병원앞)"})
    assert res.status_code == 200
    arrivals = res.json()["arrivals"]
    assert {(a["route"], a["direction"]) for a in arrivals} == {("6호선", "보문방면"), ("6호선", "고려대방면")}
    assert all(a["minutes"] is not None for a in arrivals)
    assert all("estimated" in a for a in arrivals)


def test_지하철_호선으로_거름(client, upstream):
    res = client.get("/api/arrivals", params={"station": "안암(고대병원앞)", "line": "1호선"})
    assert res.json()["arrivals"] == []


# ---------- 오류 ----------
def test_정류소와_역을_둘_다_보내면_오류(client):
    res = client.get("/api/arrivals", params={"stop_id": "08301", "station": "안암"})
    assert res.status_code == 422
    assert res.json()["error"]["code"] == "invalid_request"


def test_둘_다_없으면_오류(client):
    assert client.get("/api/arrivals").status_code == 422


def test_키가_없으면_503(client, monkeypatch):
    monkeypatch.setattr(config, "DATA_GO_KR_SERVICE_KEY", "")
    res = client.get("/api/arrivals", params={"stop_id": "08301"})
    assert res.status_code == 503
    assert res.json()["error"]["code"] == "not_configured"


def test_외부_API_실패는_502이고_키를_숨김(client, monkeypatch):
    def handler(request):
        raise httpx.ConnectError(f"실패 {request.url}")

    monkeypatch.setattr(seoul_bus, "_client", lambda: httpx.Client(transport=httpx.MockTransport(handler)))
    res = client.get("/api/arrivals", params={"stop_id": "08301"})
    assert res.status_code == 502
    assert res.json()["error"]["code"] == "upstream_error"
    assert "TEST-KEY" not in res.text
