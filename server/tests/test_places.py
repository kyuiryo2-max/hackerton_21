"""장소 종류 목록 검사 (할 일 14번). 카카오 실제 호출 없음."""
import csv
from pathlib import Path

import pytest

from app.services import llm, places

ROOT = Path(__file__).resolve().parents[2]


def test_장소_종류는_10개에서_20개():
    # 문구점을 추가해 16개가 됐어요. 너무 적거나 과하게 늘어나지 않는지만 봐요.
    assert 10 <= len(places.place_searches()) <= 20


def test_이름이_겹치지_않음():
    names = llm.place_types()
    assert len(names) == len(set(names))


def test_모든_종류가_카카오_검색과_연결됨():
    for s in places.place_searches().values():
        assert s.search_type in ("category", "keyword"), s
        assert s.search_value, s
        if s.search_type == "category":
            assert s.search_value in places.KAKAO_CATEGORY_CODES, s


def test_AI_허용_목록과_같음():
    """프롬프트에 들어가는 목록(llm.place_types)과 검색 연결 목록이 같아야 해요."""
    assert list(places.place_searches()) == llm.place_types()


def test_테스트_문장의_정답이_목록_안에_있음():
    with open(ROOT / "ai" / "testcases" / "tasks.csv", encoding="utf-8") as f:
        expected = {p for row in csv.DictReader(f) for p in row["expected_place_types"].split("|") if p}
    assert expected <= set(llm.place_types())


def test_카테고리_종류는_카테고리로_검색(monkeypatch):
    calls = []
    monkeypatch.setattr(places.kakao, "search_places", lambda center, **kw: calls.append(kw) or [])
    places.search_by_place_type("약국", (127.0293, 37.5863))
    assert calls == [{"category": "PM9", "radius_m": 500, "size": 5}]


def test_키워드_종류는_키워드로_검색(monkeypatch):
    calls = []
    monkeypatch.setattr(places.kakao, "search_places", lambda center, **kw: calls.append(kw) or [])
    places.search_by_place_type("꽃집", (127.0293, 37.5863), radius_m=300)
    assert calls == [{"keyword": "꽃집", "radius_m": 300, "size": 5}]


def test_목록에_없는_종류는_거절():
    with pytest.raises(ValueError):
        places.search_by_place_type("우주정거장", (127.0293, 37.5863))


def test_병원은_할_일의_진료과로_검색(monkeypatch):
    # 11/13: "피부과 가기"인데 내과·치과까지 추천하던 문제
    calls = []
    monkeypatch.setattr(places.kakao, "search_places", lambda center, **kw: calls.append(kw) or [])
    places.search_by_place_type("병원", (127.0293, 37.5863), radius_m=300, text="피부과 가기")
    places.search_by_place_type("병원", (127.0293, 37.5863), radius_m=300, text="정신과 상담")
    places.search_by_place_type("병원", (127.0293, 37.5863), radius_m=300, text="병원 가기")
    assert calls == [{"keyword": "피부과", "radius_m": 300, "size": 5},
                     {"keyword": "정신건강의학과", "radius_m": 300, "size": 5},
                     {"category": "HP8", "radius_m": 300, "size": 5}]


def test_진료과_찾기는_긴_이름부터():
    assert places.specialty_of("정형외과 물리치료") == "정형외과"
    assert places.specialty_of("신경외과") == "신경외과"
    assert places.specialty_of("소아과 예방접종") == "소아청소년과"
    assert places.specialty_of("감기라 내과") == "내과"
    assert places.specialty_of("약 사기") is None


def test_마트_키워드_검색에서_음식점은_뺌(monkeypatch):
    """'롯데마트'가 들어간 음식점이 대형마트보다 먼저 와도 판매처로 쓰지 않아요 (11/20)."""
    def fake_search(center, **kwargs):
        return [
            {"name": "죠스 떡볶이 롯데마트점", "category": "FD6",
             "category_name": "음식점 > 분식", "lng": 127.0, "lat": 37.5},
            {"name": "롯데마트 서울역점", "category": "MT1",
             "category_name": "가정,생활 > 대형마트", "lng": 127.1, "lat": 37.6},
        ]

    monkeypatch.setattr(places.kakao, "search_places", fake_search)
    found = places.search_by_place_type("마트", (127.0, 37.5))
    assert [p["name"] for p in found] == ["롯데마트 서울역점"]


def test_카테고리_검색은_다른_업종_코드를_뺌(monkeypatch):
    monkeypatch.setattr(places.kakao, "search_places", lambda center, **kw: [
        {"name": "편의점", "category": "CS2", "category_name": "편의점"},
    ])
    assert places.search_by_place_type("약국", (127.0, 37.5)) == []


def test_다이소는_이름에_브랜드가_있는_곳만_남김(monkeypatch):
    monkeypatch.setattr(places.kakao, "search_places", lambda center, **kw: [
        {"name": "다이소 서울역점", "category": "", "category_name": "가정,생활 > 생활용품점"},
        {"name": "롯데마트 다이소점", "category": "FD6", "category_name": "음식점 > 분식"},
    ])
    found = places.search_by_place_type("다이소", (127.0, 37.5))
    assert [p["name"] for p in found] == ["다이소 서울역점"]
