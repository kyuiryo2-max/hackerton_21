"""③ 조회: 카카오맵 REST API 하나로 주소, 장소, 대중교통, 도보를 처리해요. (작업 표 20번)

대중교통·도보 경로는 하루 각 1,000건 한도라서 같은 구간 결과를 잠시 저장해 다시 써요.
위치는 DB에 저장하지 않는 규칙이라 서버 메모리에만 두고, 재시작하면 사라져요.
"""
import time
from typing import Any

import httpx

from app import config

BASE_URL = "https://dapi.kakao.com"
TIMEOUT_SECONDS = 10
TRANSIT_TTL_SECONDS = 60 * 60       # 대중교통 경로: 1시간
WALK_TTL_SECONDS = 24 * 60 * 60     # 도보 경로: 하루
MAX_CACHE_SIZE = 1000
COORD_DIGITS = 4                    # 약 10m 단위로 같은 구간 판단
SAME_POINT_SHIFT = 0.0001           # 왕복 도보 재시도 때 도착 지점을 옮기는 값 (약 10m)

Coord = tuple[float, float]         # (경도 x, 위도 y)

_cache: dict[tuple, tuple[float, Any]] = {}


class KakaoError(Exception):
    """호출 실패. 오류 문장에 키나 요청 주소를 넣지 않아요."""


def clear_cache() -> None:
    _cache.clear()


def _cache_get(key: tuple) -> Any | None:
    item = _cache.get(key)
    if item is None:
        return None
    expires_at, value = item
    if time.monotonic() >= expires_at:
        del _cache[key]
        return None
    return value


def _cache_set(key: tuple, value: Any, ttl_seconds: int) -> None:
    if key not in _cache and len(_cache) >= MAX_CACHE_SIZE:
        del _cache[next(iter(_cache))]  # 가장 먼저 넣은 항목부터 지워요
    _cache[key] = (time.monotonic() + ttl_seconds, value)


def _rounded(coord: Coord) -> Coord:
    return round(coord[0], COORD_DIGITS), round(coord[1], COORD_DIGITS)


def _client() -> httpx.Client:
    return httpx.Client(timeout=TIMEOUT_SECONDS)


def _get(path: str, params: dict) -> dict:
    headers = {"Authorization": f"KakaoAK {config.KAKAO_REST_API_KEY}"}
    try:
        with _client() as client:
            res = client.get(f"{BASE_URL}{path}", headers=headers, params=params)
    except httpx.HTTPError as e:
        raise KakaoError(f"카카오 API 연결 실패: {type(e).__name__}") from None
    if res.status_code != 200:
        raise KakaoError(f"카카오 API 오류: HTTP {res.status_code}")
    try:
        return res.json()
    except ValueError:
        raise KakaoError("카카오 API 응답이 JSON이 아니에요") from None


def geocode(address: str) -> Coord | None:
    """주소를 좌표로 바꿔요. 찾지 못하면 None."""
    documents = _get("/v2/local/search/address.json", {"query": address}).get("documents", [])
    if not documents:
        return None
    return float(documents[0]["x"]), float(documents[0]["y"])


def search_places(
    center: Coord,
    keyword: str | None = None,
    category: str | None = None,
    radius_m: int = 500,
    size: int = 5,
    sort: str = "distance",
) -> list[dict]:
    """주변 장소를 찾아요. keyword나 category 중 하나는 있어야 해요.

    sort: "distance"(가까운 순, 기본) 또는 "accuracy"(검색어와 잘 맞는 순, keyword 검색에서만)
    """
    if bool(keyword) == bool(category):
        raise ValueError("keyword와 category 중 하나만 주세요")
    params: dict = {
        "x": center[0],
        "y": center[1],
        "radius": radius_m,
        "size": size,
        "sort": sort,
    }
    if keyword:
        path = "/v2/local/search/keyword.json"
        params["query"] = keyword
    else:
        path = "/v2/local/search/category.json"
        params["category_group_code"] = category
    return [
        {
            "name": d["place_name"],
            "address": d.get("road_address_name") or d.get("address_name", ""),
            "lng": float(d["x"]),
            "lat": float(d["y"]),
            "distance_m": int(d["distance"]) if d.get("distance") else None,
            "place_url": d.get("place_url", ""),
        }
        for d in _get(path, params).get("documents", [])
    ]


def _parse_fare(fare: dict) -> tuple[int | None, int | None]:
    """요금은 value 하나 또는 min·max 두 값으로 와요."""
    value = fare.get("value")
    return fare.get("min", value), fare.get("max", value)


def _parse_leg(step: dict) -> dict:
    prop = step.get("properties", {})
    points = step.get("path", {}).get("points", [])
    return {
        "type": prop.get("type"),                     # BUS, SUBWAY, WALKING
        "seconds": prop.get("time", 0),
        "guidance": prop.get("guidance", ""),
        "stops": [s.get("name", "") for s in prop.get("stops", [])],
        "vehicles": [v.get("name", "") for v in prop.get("vehicles", [])],
        "start": tuple(points[0]) if points else None,  # 구간 시작 좌표
        "end": tuple(points[-1]) if points else None,   # 구간 끝 좌표
        "points": _thin(points),                        # 지도에 그릴 선 (앱 전송용으로 줄인 좌표)
    }


MAX_LEG_POINTS = 40


def _thin(points: list) -> list[list[float]]:
    """좌표가 너무 많으면 고르게 골라 MAX_LEG_POINTS개로 줄여요. 처음과 끝은 꼭 남겨요."""
    pts = [[float(p[0]), float(p[1])] for p in points if len(p) >= 2]
    if len(pts) <= MAX_LEG_POINTS:
        return pts
    step = (len(pts) - 1) / (MAX_LEG_POINTS - 1)
    return [pts[round(i * step)] for i in range(MAX_LEG_POINTS)]


def parse_transit(data: dict) -> list[dict]:
    """카카오 응답을 서버에서 쓰기 쉬운 경로 목록으로 바꿔요.

    legs에는 환승 도보만 있고 처음·마지막 도보가 없어요.
    집에서 정류장까지는 walk_seconds로 따로 구해야 해요.

    총 시간은 카카오 totalTime을 쓰지 않고 timecalc.route_total_seconds로 계산해요.
    totalTime은 실시간 대기를 반영하지 않아서 비교용으로만 남겨요.
    """
    routes = []
    for route in data.get("routes", []):
        prop = route.get("properties", {})
        fare_min, fare_max = _parse_fare(prop.get("fare") or {})
        legs = [_parse_leg(step) for step in route.get("steps", [])]
        routes.append({
            "type": prop.get("type"),
            "moving_seconds": sum(leg["seconds"] for leg in legs),  # 구간 시간 합
            "kakao_total_seconds": prop.get("totalTime"),
            "transfers": prop.get("transfers"),
            "fare_min": fare_min,
            "fare_max": fare_max,
            "legs": legs,
        })
    return routes


def transit_routes(start: Coord, end: Coord, use_cache: bool = True) -> list[dict]:
    """대중교통 경로 목록. 경로가 없으면 빈 목록이고, 빈 결과는 저장하지 않아요.

    use_cache=False면 저장하지도 꺼내지도 않아요 (사용자 현재 위치가 들어간 호출).
    """
    start, end = _rounded(start), _rounded(end)
    key = ("transit", start, end)
    cached = _cache_get(key) if use_cache else None
    if cached is not None:
        return cached
    data = _get("/v2/routing/publictraffic", {
        "start_x": start[0], "start_y": start[1],
        "end_x": end[0], "end_y": end[1],
    })
    if data.get("status") != "OK":
        return []
    routes = parse_transit(data)
    if routes and use_cache:
        _cache_set(key, routes, TRANSIT_TTL_SECONDS)
    return routes


def walk_seconds(start: Coord, end: Coord, via: list[Coord] | None = None, use_cache: bool = True) -> int | None:
    """도보 시간(초). via는 경유지 최대 5개. 경로를 찾지 못하면 None.

    출발과 도착이 같고 경유지가 없으면 호출 없이 0이에요.
    경유지 왕복이 실패하면 도착 지점을 약 10m 옮겨 한 번 더 시도해요.
    """
    via = [_rounded(c) for c in via or []]
    if len(via) > 5:
        raise ValueError("경유지는 최대 5개예요")
    start, end = _rounded(start), _rounded(end)
    if start == end and not via:
        return 0
    key = ("walk", start, end, tuple(via))
    cached = _cache_get(key) if use_cache else None
    if cached is not None:
        return cached
    params: dict = {
        "start_x": start[0], "start_y": start[1],
        "end_x": end[0], "end_y": end[1],
    }
    if via:
        params["via_x"] = ",".join(str(c[0]) for c in via)
        params["via_y"] = ",".join(str(c[1]) for c in via)
    data = _get("/v2/routing/walk", params)
    if data.get("status") != "OK" and start == end:
        params["end_x"] = round(end[0] + SAME_POINT_SHIFT, COORD_DIGITS)
        data = _get("/v2/routing/walk", params)
    if data.get("status") != "OK":
        return None
    seconds = data["route"]["properties"]["totalTime"]
    if use_cache:
        _cache_set(key, seconds, WALK_TTL_SECONDS)
    return seconds
