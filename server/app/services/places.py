"""장소 종류 → 카카오 장소 검색 연결 (할 일 14번).

AI는 할 일을 data/demo/place_types.csv 의 장소 종류로만 바꾸고,
이 모듈이 그 종류를 카카오 검색 방식(카테고리 코드 또는 키워드)으로 바꿔서 찾아요.

    from app.services import places
    places.search_by_place_type("약국", center=(127.0293, 37.5863))
"""
import csv
from dataclasses import dataclass
from functools import lru_cache

from app.services import kakao
from app.services.llm import PLACE_TYPES_CSV

# 카카오 로컬 API category_group_code 전체 목록
KAKAO_CATEGORY_CODES = {
    "MT1": "대형마트", "CS2": "편의점", "PS3": "어린이집·유치원", "SC4": "학교",
    "AC5": "학원", "PK6": "주차장", "OL7": "주유소·충전소", "SW8": "지하철역",
    "BK9": "은행", "CT1": "문화시설", "AG2": "중개업소", "PO3": "공공기관",
    "AT4": "관광명소", "AD5": "숙박", "FD6": "음식점", "CE7": "카페",
    "HP8": "병원", "PM9": "약국",
}


@dataclass(frozen=True)
class PlaceSearch:
    place_type: str
    search_type: str   # "category" 또는 "keyword"
    search_value: str  # 카테고리 코드(PM9 등) 또는 검색어


@lru_cache
def place_searches() -> dict[str, PlaceSearch]:
    with open(PLACE_TYPES_CSV, encoding="utf-8") as f:
        return {
            row["place_type"]: PlaceSearch(row["place_type"], row["search_type"], row["search_value"])
            for row in csv.DictReader(f)
        }


# 할 일 문장에 진료과가 있으면 그 진료과만 찾아요 (11/13: "피부과 가기"인데 내과·치과까지 추천하던 문제)
# 왼쪽은 문장에서 찾을 말, 오른쪽은 카카오에서 검색할 말
SPECIALTIES: list[tuple[str, str]] = [
    ("정신건강의학과", "정신건강의학과"), ("정신과", "정신건강의학과"),
    ("소아청소년과", "소아청소년과"), ("소아과", "소아청소년과"),
    ("이비인후과", "이비인후과"), ("피부과", "피부과"), ("치과", "치과"), ("안과", "안과"),
    ("정형외과", "정형외과"), ("산부인과", "산부인과"), ("비뇨의학과", "비뇨의학과"), ("비뇨기과", "비뇨의학과"),
    ("가정의학과", "가정의학과"), ("신경외과", "신경외과"), ("신경과", "신경과"), ("성형외과", "성형외과"),
    ("한의원", "한의원"), ("내과", "내과"), ("외과", "외과"),
]


def specialty_of(text: str) -> str | None:
    """할 일 문장 속 진료과 → 카카오 검색어. 없으면 None (그때는 병원 전체)."""
    for word, query in SPECIALTIES:
        if word in text:
            return query
    return None


def search_by_place_type(place_type: str, center: kakao.Coord, radius_m: int = 500, size: int = 5,
                         text: str = "") -> list[dict]:
    """장소 종류 하나로 주변 장소를 가까운 순으로 찾아요. 목록에 없는 종류면 ValueError."""
    s = place_searches().get(place_type)
    if s is None:
        raise ValueError(f"장소 종류 목록에 없어요: {place_type}")
    if place_type == "병원" and (spec := specialty_of(text)):
        return kakao.search_places(center, keyword=spec, radius_m=radius_m, size=size)
    if s.search_type == "category":
        return kakao.search_places(center, category=s.search_value, radius_m=radius_m, size=size)
    return kakao.search_places(center, keyword=s.search_value, radius_m=radius_m, size=size)
