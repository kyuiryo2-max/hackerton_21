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

# 음식점·카페는 "롯데마트점"처럼 매장 이름에 다른 가게 이름이 붙어도
# 물건을 파는 곳이 아니에요. 키워드 검색 결과에서 이런 업종을 걸러요 (11/20).
FOOD_GROUP_CODES = {"FD6", "CE7"}
FOOD_CATEGORY_WORDS = ("음식점", "카페", "분식", "주점", "제과", "베이커리")
FOOD_PLACE_TYPES = {"음식점", "카페", "빵집", "케이크집"}

# 브랜드 이름으로 찾는 종류는 결과 이름에도 브랜드가 있어야 해요.
BRAND_KEYWORDS = {
    "다이소": ("다이소",),
    "올리브영": ("올리브영",),
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



def _is_food_or_cafe(place: dict) -> bool:
    """카카오 결과가 음식점·카페인지. 업종 코드가 비어 있어도 업종명으로 판단해요."""
    code = str(place.get("category") or "")
    category_name = str(place.get("category_name") or "")
    return code in FOOD_GROUP_CODES or any(word in category_name for word in FOOD_CATEGORY_WORDS)


def is_valid_place(place_type: str, place: dict) -> bool:
    """검색한 장소 종류에 맞는 결과인지 확인해요.

    특히 "마트" 키워드 검색에 "죠스 떡볶이 롯데마트점"(음식점)이 섞이는 문제를 막아요.
    카카오가 업종 코드를 주지 않는 예전 응답은 이름 규칙만 적용해 호환성을 지켜요.
    """
    if place_type == "기타":
        # AI가 종류를 고르지 못해도, 물건을 사러 가는 추천에 음식점·카페는 넣지 않아요.
        return not _is_food_or_cafe(place)
    if place_type not in FOOD_PLACE_TYPES and _is_food_or_cafe(place):
        return False
    brands = BRAND_KEYWORDS.get(place_type)
    if brands:
        name = str(place.get("name") or "").casefold()
        return any(brand in name for brand in brands)
    return True


def search_by_place_type(place_type: str, center: kakao.Coord, radius_m: int = 500, size: int = 5,
                         text: str = "") -> list[dict]:
    """장소 종류 하나로 주변 장소를 가까운 순으로 찾아요. 목록에 없는 종류면 ValueError."""
    s = place_searches().get(place_type)
    if s is None:
        raise ValueError(f"장소 종류 목록에 없어요: {place_type}")
    if place_type == "병원" and (spec := specialty_of(text)):
        found = kakao.search_places(center, keyword=spec, radius_m=radius_m, size=size)
        return [p for p in found if is_valid_place(place_type, p)]
    if s.search_type == "category":
        found = kakao.search_places(center, category=s.search_value, radius_m=radius_m, size=size)
        # 카카오가 업종 코드를 줬는데 다른 업종이면 잘못 섞인 결과예요.
        return [
            p for p in found
            if (not p.get("category") or p["category"] == s.search_value) and is_valid_place(place_type, p)
        ]
    found = kakao.search_places(center, keyword=s.search_value, radius_m=radius_m, size=size)
    return [p for p in found if is_valid_place(place_type, p)]
