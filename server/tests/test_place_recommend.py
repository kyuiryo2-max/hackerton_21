"""AI 장소 추천 API 테스트. AI와 카카오 호출은 가짜로 바꿔 외부 호출이 없어요."""
import pytest
from fastapi.testclient import TestClient

from app import config
from app.services import kakao, llm, place_recommendation


CANDIDATES = [
    {"name": "다이소", "search_query": "다이소", "category": "다이소", "reason": "생활용품을 살 수 있어요."},
    {"name": "올리브영", "search_query": "올리브영", "category": "올리브영", "reason": "생활용품을 살 수 있어요."},
    {"name": "편의점", "search_query": "편의점", "category": "편의점", "reason": "가까운 편의점이에요."},
]


@pytest.fixture()
def client(tmp_path, monkeypatch):
    monkeypatch.setattr("app.config.DATABASE_PATH", str(tmp_path / "test.db"))
    monkeypatch.setattr(config, "KAKAO_REST_API_KEY", "TEST-KAKAO")
    monkeypatch.setattr(config, "OPENAI_API_KEY", "TEST-AI")
    monkeypatch.setattr(config, "LLM_MODEL", "test-model")
    from app.main import app

    with TestClient(app) as c:
        yield c


@pytest.fixture()
def fake_ai(monkeypatch):
    def fake_recommend(text, center, limit=3):
        assert text == "고양이 사료 사야 돼"
        assert center == (127.0304, 37.5862)
        return CANDIDATES[:limit]

    monkeypatch.setattr(llm, "recommend_places", fake_recommend)
    return fake_recommend


@pytest.fixture()
def fake_kakao(monkeypatch):
    calls = []

    def fake_search(center, keyword=None, category=None, radius_m=500, size=5, sort="distance"):
        calls.append(
            {
                "center": center,
                "keyword": keyword,
                "category": category,
                "radius_m": radius_m,
                "size": size,
                "sort": sort,
            }
        )
        distances = {"다이소": 120, "올리브영": 340, "편의점": 80}
        return [
            {
                "name": f"{keyword} 안암점",
                "address": f"서울 성북구 {keyword}로 1",
                "lat": 37.5865,
                "lng": 127.0305,
                "distance_m": distances.get(keyword, 500),
                "place_url": "https://place.map.kakao.com/1",
            }
        ]

    monkeypatch.setattr(kakao, "search_places", fake_search)
    return calls


def test_AI_후보를_카카오_실제_지점으로_바꿔_가까운_순서로_돌려줌(client, fake_ai, fake_kakao):
    res = client.post(
        "/api/places/recommend",
        json={"text": "고양이 사료 사야 돼", "lat": 37.5862, "lng": 127.0304, "limit": 3},
    )
    assert res.status_code == 200
    body = res.json()
    assert body["source"] == "ai"
    assert body["engine"] == "ai+kakao"
    assert body["used_default_location"] is False
    assert [p["name"] for p in body["places"]] == [
        "편의점 안암점",
        "다이소 안암점",
        "올리브영 안암점",
    ]
    first = body["places"][0]
    assert first["address"] == "서울 성북구 편의점로 1"
    assert first["category"] == "편의점"
    assert first["distance_m"] == 80
    assert first["verified"] is True
    assert all(call["center"] == (127.0304, 37.5862) for call in fake_kakao)
    assert all(call["radius_m"] == 5000 for call in fake_kakao)
    assert all(call["sort"] == "distance" for call in fake_kakao)
    assert all(call["size"] == 3 for call in fake_kakao)


def test_위치가_없으면_서울시청_기준임을_알려줌(client, monkeypatch, fake_kakao):
    monkeypatch.setattr(llm, "recommend_places", lambda text, center, limit=3: CANDIDATES[:1])
    res = client.post("/api/places/recommend", json={"text": "고양이 사료"})
    assert res.status_code == 200
    body = res.json()
    assert body["used_default_location"] is True
    assert fake_kakao[0]["center"] == (126.9780, 37.5665)


def test_AI가_후보를_못_찾으면_빈_목록과_안내를_돌려줌(client, monkeypatch):
    monkeypatch.setattr(llm, "recommend_places", lambda text, center, limit=3: [])
    res = client.post("/api/places/recommend", json={"text": "회의 준비"})
    assert res.status_code == 200
    body = res.json()
    assert body["places"] == []
    assert "판매처" in body["message"]


def test_AI_설정이_없으면_503(client, monkeypatch):
    monkeypatch.setattr(config, "OPENAI_API_KEY", "")
    res = client.post("/api/places/recommend", json={"text": "고양이 사료"})
    assert res.status_code == 503
    assert res.json()["error"]["code"] == "ai_not_configured"


def test_카카오_키가_없으면_503이고_AI를_부르지_않음(client, monkeypatch):
    called = []
    monkeypatch.setattr(config, "KAKAO_REST_API_KEY", "")
    monkeypatch.setattr(llm, "recommend_places", lambda *args, **kwargs: called.append(True) or [])
    res = client.post("/api/places/recommend", json={"text": "고양이 사료"})
    assert res.status_code == 503
    assert res.json()["error"]["code"] == "not_configured"
    assert called == []


def test_AI_응답_형식이_깨지면_502(client, monkeypatch):
    def broken(text, center, limit=3):
        raise ValueError("AI 출력의 매장 목록이 배열이 아니에요")

    monkeypatch.setattr(llm, "recommend_places", broken)
    res = client.post("/api/places/recommend", json={"text": "고양이 사료"})
    assert res.status_code == 502
    assert res.json()["error"]["code"] == "ai_error"


def test_AI_연결이_실패해도_502(client, monkeypatch):
    def fail(text, center, limit=3):
        raise TimeoutError("AI 응답 시간 초과")

    monkeypatch.setattr(llm, "recommend_places", fail)
    res = client.post("/api/places/recommend", json={"text": "고양이 사료"})
    assert res.status_code == 502
    assert res.json()["error"]["code"] == "ai_error"


def test_카카오_오류는_502(client, monkeypatch):
    monkeypatch.setattr(llm, "recommend_places", lambda text, center, limit=3: CANDIDATES[:1])

    def fail(*args, **kwargs):
        raise kakao.KakaoError("카카오 API 오류: HTTP 500")

    monkeypatch.setattr(kakao, "search_places", fail)
    res = client.post("/api/places/recommend", json={"text": "고양이 사료"})
    assert res.status_code == 502
    assert res.json()["error"]["code"] == "upstream_error"


def test_위치_좌표는_둘_다_있어야_함(client):
    res = client.post("/api/places/recommend", json={"text": "고양이 사료", "lat": 37.5})
    assert res.status_code == 422
    assert res.json()["error"]["code"] == "invalid_request"


def test_공백_문장은_거절(client):
    res = client.post("/api/places/recommend", json={"text": "   "})
    assert res.status_code == 422
    assert res.json()["error"]["code"] == "invalid_request"


def test_AI_후보에서_목록에_없는_장소_종류는_기타로_바꿈(monkeypatch):
    monkeypatch.setattr(
        llm,
        "_chat_json",
        lambda system, user: {
            "items": [
                {"name": "동네가게", "search_query": "동네가게", "category": "없는종류", "reason": ""},
                {"name": "", "search_query": "버려짐"},
                "문구점",
            ]
        },
    )
    found = llm.recommend_places("고양이 사료", (127.0, 37.5), limit=3)
    assert [item["name"] for item in found] == ["동네가게", "문구점"]
    assert found[0]["category"] == "기타"
    assert found[0]["reason"] == "현재 위치 주변에서 찾은 매장이에요."


def test_카카오_결과가_없으면_빈_목록(monkeypatch):
    monkeypatch.setattr(llm, "recommend_places", lambda text, center, limit=3: CANDIDATES[:1])
    monkeypatch.setattr(kakao, "search_places", lambda *args, **kwargs: [])
    assert place_recommendation.recommend("고양이 사료", (127.0, 37.5)) == []


def test_AI_후보_검색에_음식점이_섞이면_판매점을_고름(monkeypatch):
    """'롯데마트' 검색 첫 결과가 '죠스 떡볶이 롯데마트점'이어도 마트로 추천하지 않아요 (11/20)."""
    monkeypatch.setattr(llm, "recommend_places", lambda text, center, limit=3: [
        {"name": "롯데마트", "search_query": "롯데마트", "category": "마트", "reason": "장보기"},
    ])
    monkeypatch.setattr(kakao, "search_places", lambda *args, **kwargs: [
        {"name": "죠스 떡볶이 롯데마트점", "category": "FD6", "category_name": "음식점 > 분식",
         "lng": 127.0, "lat": 37.5, "distance_m": 50, "place_url": ""},
        {"name": "롯데마트 서울역점", "category": "MT1", "category_name": "가정,생활 > 대형마트",
         "lng": 127.1, "lat": 37.6, "distance_m": 300, "place_url": ""},
    ])
    found = place_recommendation.recommend("롯데마트", (127.0, 37.5))
    assert [p["name"] for p in found] == ["롯데마트 서울역점"]
