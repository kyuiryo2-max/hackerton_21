"""장소 검색 API 테스트 (할 일 61번). 카카오 호출은 가짜 응답으로 바꿔서 외부 호출이 없어요."""
import pytest
from fastapi.testclient import TestClient

from app import config
from app.services import kakao

# 카카오 키워드 검색 응답 모양 (필요한 칸만)
KAKAO_DOCS = {"documents": [
    {"place_name": "청량리역 경의중앙선", "road_address_name": "서울 동대문구 왕산로 214",
     "address_name": "서울 동대문구 전농동 588-1", "x": "127.04691", "y": "37.58029",
     "distance": "8200", "place_url": "http://place.map.kakao.com/1"},
    {"place_name": "청량리역 1호선", "road_address_name": "", "address_name": "서울 동대문구 전농동 591-53",
     "x": "127.04725", "y": "37.58010", "distance": "", "place_url": ""},
]}


@pytest.fixture()
def client(tmp_path, monkeypatch):
    monkeypatch.setattr("app.config.DATABASE_PATH", str(tmp_path / "test.db"))
    monkeypatch.setattr(config, "KAKAO_REST_API_KEY", "TEST")
    from app.main import app

    with TestClient(app) as c:
        yield c


@pytest.fixture()
def calls(monkeypatch):
    """카카오에 보낸 요청을 기록하고 가짜 응답을 돌려줘요."""
    sent = []

    def fake_get(path, params):
        sent.append((path, params))
        return KAKAO_DOCS
    monkeypatch.setattr(kakao, "_get", fake_get)
    return sent


def test_검색어로_장소_목록을_돌려줌(client, calls):
    res = client.get("/api/places/search", params={"query": "청량리역"})
    assert res.status_code == 200
    body = res.json()
    assert body[0] == {"name": "청량리역 경의중앙선", "address": "서울 동대문구 왕산로 214",
                       "lat": 37.58029, "lng": 127.04691}
    # 도로명 주소가 없으면 지번 주소
    assert body[1]["address"] == "서울 동대문구 전농동 591-53"


def test_위치가_없으면_서울_전체에서_정확도순(client, calls):
    client.get("/api/places/search", params={"query": "청량리역"})
    path, params = calls[0]
    assert path.endswith("keyword.json")
    assert params["query"] == "청량리역"
    assert params["sort"] == "accuracy"
    assert params["radius"] == 20000
    assert (params["x"], params["y"]) == (126.9780, 37.5665)


def test_위치를_주면_그_근처에서_찾음(client, calls):
    client.get("/api/places/search", params={"query": "꽃집", "lat": 37.5862, "lng": 127.0304})
    _, params = calls[0]
    assert (params["x"], params["y"]) == (127.0304, 37.5862)


def test_빈_검색어는_거절(client, calls):
    assert client.get("/api/places/search", params={"query": "  "}).json()["error"]["code"] == "invalid_request"
    assert client.get("/api/places/search").status_code == 422
    assert calls == []


def test_키가_없으면_503(client, calls, monkeypatch):
    monkeypatch.setattr(config, "KAKAO_REST_API_KEY", "")
    res = client.get("/api/places/search", params={"query": "청량리역"})
    assert res.status_code == 503
    assert res.json()["error"]["code"] == "not_configured"


def test_카카오_오류는_502(client, monkeypatch):
    def fail(path, params):
        raise kakao.KakaoError("카카오 API 오류: HTTP 500")
    monkeypatch.setattr(kakao, "_get", fail)
    res = client.get("/api/places/search", params={"query": "청량리역"})
    assert res.status_code == 502
    assert res.json()["error"]["code"] == "upstream_error"
