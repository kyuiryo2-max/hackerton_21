"""장소 종류 목록 검사 (할 일 14번). 카카오 실제 호출 없음."""
import csv
from pathlib import Path

import pytest

from app.services import llm, places

ROOT = Path(__file__).resolve().parents[2]


def test_장소_종류는_10개에서_15개():
    assert 10 <= len(places.place_searches()) <= 15


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
