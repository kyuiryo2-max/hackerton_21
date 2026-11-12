"""장소 검색 API (할 일 61번). 일정의 목적지를 이름으로 찾을 때 써요.

앱의 목적지 검색 화면(place_search_service.dart)이 이 주소를 불러요.
응답은 목록 하나이고, 각 장소는 name, address, lat, lng 를 가져요.
"""
from fastapi import APIRouter, Query
from fastapi.responses import JSONResponse

from app import config
from app.services import kakao

router = APIRouter(prefix="/api", tags=["장소 검색"])

# 위치를 안 주면 서울시청을 중심으로 서울 전체(카카오 최대 반경 20km)에서 찾아요.
SEOUL_CITY_HALL = (126.9780, 37.5665)  # (경도, 위도)
MAX_RADIUS_M = 20000
RESULT_SIZE = 10


def _error(status: int, code: str, message: str) -> JSONResponse:
    return JSONResponse(status_code=status, content={"error": {"code": code, "message": message}})


@router.get("/places/search")
def search_places(
    query: str = Query(min_length=1, max_length=50, examples=["청량리역"]),
    lat: float | None = Query(default=None, ge=33, le=39, description="현재 위치(선택). 주면 그 근처를 먼저 찾아요"),
    lng: float | None = Query(default=None, ge=124, le=132),
):
    """장소 이름으로 검색해요. 검색어와 잘 맞는 순서로 최대 10곳을 돌려줘요.

    현재 위치는 검색 중심으로만 쓰고 저장하거나 기록하지 않아요.
    """
    keyword = query.strip()
    if not keyword:
        return _error(422, "invalid_request", "query: 검색어를 입력해 주세요")
    if not config.KAKAO_REST_API_KEY:
        return _error(503, "not_configured", "서버에 장소 검색 API 키가 설정되지 않았어요")
    center = (lng, lat) if lat is not None and lng is not None else SEOUL_CITY_HALL
    try:
        found = kakao.search_places(center, keyword=keyword, radius_m=MAX_RADIUS_M,
                                    size=RESULT_SIZE, sort="accuracy")
    except kakao.KakaoError as e:
        return _error(502, "upstream_error", str(e))
    return [{k: p[k] for k in ("name", "address", "lat", "lng")} for p in found]
