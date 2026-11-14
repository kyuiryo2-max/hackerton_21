"""③ 조회: 카카오맵 REST API 하나로 주소, 장소, 대중교통, 도보를 처리해요. (작업 표 20번)

대중교통·도보 경로는 하루 각 1,000건 한도라서 같은 구간 결과를 잠시 저장해 다시 써요.
위치는 DB에 저장하지 않는 규칙이라 서버 메모리에만 두고, 재시작하면 사라져요.
"""
import logging
import math
import threading
import time
from datetime import datetime, timedelta, timezone
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

# 현재 위치가 들어간 호출은 아주 잠깐만 기억해요 (11/13 호출 줄이기).
# 같은 자리(약 10m 안)에서 새로고침하면 카카오에 다시 묻지 않아요. 서버 메모리에만 두고 5분 뒤 지워요.
ORIGIN_TTL_SECONDS = 5 * 60
# 만료된 값은 1분마다 지워요. 같은 위치로 다시 조회하지 않아도 5분 + 최대 1분 안에 사라져요 (PR #46 리뷰)
SWEEP_INTERVAL_SECONDS = 60

# 도보 한도를 다 쓰면 직선거리로 어림해요 (11/13). 실제 길은 직선보다 돌아가서 1.3배로 쳐요.
WALK_SPEED_MPS = 1.1                # 시속 약 4km
WALK_DETOUR_RATIO = 1.3
KST = timezone(timedelta(hours=9))

log = logging.getLogger(__name__)

_cache: dict[tuple, tuple[float, Any]] = {}
_quota_blocked_until: dict[str, float] = {}   # API 경로 → 한도가 다시 풀리는 시각 (다음 자정)


class KakaoError(Exception):
    """호출 실패. 오류 문장에 키나 요청 주소를 넣지 않아요.
    status: HTTP 상태 코드 (연결 실패면 None)
    code: 카카오 오류 코드 (예: -10 은 호출 한도 초과)"""

    def __init__(self, message: str, status: int | None = None, code: int | None = None):
        super().__init__(message)
        self.status = status
        self.code = code

    @property
    def quota_exceeded(self) -> bool:
        """하루 호출 한도를 다 썼어요. 카카오는 이때도 HTTP 400 으로 답하고 code -10 을 보내요.
        429(초당 너무 많이 부름)는 잠깐 뒤 풀리는 거라 여기에 넣지 않아요."""
        return self.status == 400 and self.code == QUOTA_EXCEEDED_CODE


QUOTA_EXCEEDED_CODE = -10


def _no_route(e: KakaoError) -> bool:
    """카카오가 400으로 답하면 대개 "이 조건으로는 경로가 없음"이에요 (너무 멀거나 가깝거나, 경유지가 길 위에 없음).
    계획 전체를 멈출 일은 아니라서 "경로 없음"으로 다뤄요 (11/13).
    단, 한도 초과(code -10)도 400으로 오는데 이건 경로 없음으로 숨기면 안 돼서 그대로 올려요."""
    return e.status == 400 and not e.quota_exceeded


def clear_cache() -> None:
    _cache.clear()
    _quota_blocked_until.clear()


def _next_midnight_kst() -> float:
    now = datetime.now(KST)
    midnight = (now + timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
    return time.time() + (midnight - now).total_seconds()


def walk_quota_used_up() -> bool:
    """오늘 도보 한도를 다 써서 직선거리로 어림하고 있는지"""
    return _quota_blocked_until.get("/v2/routing/walk", 0) > time.time()


def _cache_get(key: tuple) -> Any | None:
    item = _cache.get(key)
    if item is None:
        return None
    expires_at, value = item
    if time.monotonic() >= expires_at:
        _cache.pop(key, None)
        return None
    return value


def sweep_expired() -> int:
    """만료된 값을 모두 지우고 지운 개수를 돌려줘요.
    예전에는 같은 키로 다시 꺼낼 때만 지워서, 현재 위치가 1시간 넘게 남을 수 있었어요 (PR #46 리뷰)."""
    now = time.monotonic()
    expired = [key for key, (expires_at, _) in list(_cache.items()) if now >= expires_at]
    for key in expired:
        _cache.pop(key, None)
    return len(expired)


_sweeper: threading.Thread | None = None


def _sweep_forever() -> None:
    while True:
        time.sleep(SWEEP_INTERVAL_SECONDS)
        try:
            sweep_expired()
        except Exception:  # 지우기가 한 번 실패해도 다음 차례에 다시 해요
            log.exception("카카오 저장값 정리 실패")


def _ensure_sweeper() -> None:
    """정리 담당을 처음 저장할 때 한 번만 띄워요. 서버가 꺼지면 같이 꺼져요 (daemon)."""
    global _sweeper
    if _sweeper is None or not _sweeper.is_alive():
        _sweeper = threading.Thread(target=_sweep_forever, name="kakao-cache-sweeper", daemon=True)
        _sweeper.start()


def _cache_set(key: tuple, value: Any, ttl_seconds: int) -> None:
    _ensure_sweeper()
    sweep_expired()  # 새로 넣을 때도 만료된 것부터 치워요 (최대 1,000개라 금방 끝나요)
    if key not in _cache and len(_cache) >= MAX_CACHE_SIZE:
        try:
            _cache.pop(next(iter(_cache)), None)  # 가장 먼저 넣은 항목부터 지워요
        except StopIteration:
            pass
    _cache[key] = (time.monotonic() + ttl_seconds, value)


def _rounded(coord: Coord) -> Coord:
    return round(coord[0], COORD_DIGITS), round(coord[1], COORD_DIGITS)


def _client() -> httpx.Client:
    return httpx.Client(timeout=TIMEOUT_SECONDS)


def _get(path: str, params: dict) -> dict:
    # 한도를 다 쓴 API는 자정까지 다시 부르지 않아요 (어차피 실패하고 기다리는 시간만 늘어요)
    if _quota_blocked_until.get(path, 0) > time.time():
        raise KakaoError("카카오 API 오류: 오늘 호출 한도 초과", status=400, code=QUOTA_EXCEEDED_CODE)
    headers = {"Authorization": f"KakaoAK {config.KAKAO_REST_API_KEY}"}
    try:
        with _client() as client:
            res = client.get(f"{BASE_URL}{path}", headers=headers, params=params)
    except httpx.HTTPError as e:
        raise KakaoError(f"카카오 API 연결 실패: {type(e).__name__}") from None
    if res.status_code != 200:
        detail, code = "", None
        try:
            body = res.json()
            detail = str(body.get("msg") or body.get("message") or body.get("code") or "")[:80]
            code = body.get("code") if isinstance(body.get("code"), int) else None
        except (ValueError, AttributeError):
            pass
        error = KakaoError(f"카카오 API 오류: HTTP {res.status_code}" + (f" ({detail})" if detail else ""),
                           status=res.status_code, code=code)
        if error.quota_exceeded:
            _quota_blocked_until[path] = _next_midnight_kst()
            log.warning("카카오 %s 오늘 한도 초과. 자정까지 다시 부르지 않아요", path)
        raise error
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
            "category": d.get("category_group_code", ""),  # SW8 지하철역 등 (검색 순서 정리용, 11/14)
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


def transit_routes(start: Coord, end: Coord, use_cache: bool = True,
                   ttl_seconds: int = TRANSIT_TTL_SECONDS) -> list[dict]:
    """대중교통 경로 목록. 경로가 없으면 빈 목록이고, 빈 결과는 저장하지 않아요.

    use_cache=False면 저장하지도 꺼내지도 않아요.
    현재 위치가 들어간 호출은 ttl_seconds=ORIGIN_TTL_SECONDS 로 잠깐만 기억해요.
    """
    start, end = _rounded(start), _rounded(end)
    key = ("transit", start, end)
    cached = _cache_get(key) if use_cache else None
    if cached is not None:
        return cached
    try:
        data = _get("/v2/routing/publictraffic", {
            "start_x": start[0], "start_y": start[1],
            "end_x": end[0], "end_y": end[1],
        })
    except KakaoError as e:
        if _no_route(e):
            return []
        raise
    if data.get("status") != "OK":
        return []
    routes = parse_transit(data)
    if routes and use_cache:
        _cache_set(key, routes, ttl_seconds)
    return routes


def walk_seconds(start: Coord, end: Coord, via: list[Coord] | None = None, use_cache: bool = True,
                 ttl_seconds: int = WALK_TTL_SECONDS) -> int | None:
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
    try:
        data = _get("/v2/routing/walk", params)
        if data.get("status") != "OK" and start == end:
            params["end_x"] = round(end[0] + SAME_POINT_SHIFT, COORD_DIGITS)
            data = _get("/v2/routing/walk", params)
    except KakaoError as e:
        if e.quota_exceeded:
            return _estimate(start, end, via)["seconds"]   # 어림값은 기억하지 않아요
        if _no_route(e):
            return None
        raise
    if data.get("status") != "OK":
        return None
    seconds = data["route"]["properties"]["totalTime"]
    if use_cache:
        _cache_set(key, seconds, ttl_seconds)
    return seconds


def _leg_points(leg: dict) -> list[list[float]]:
    """도보 구간 하나의 길 모양 좌표 [[경도, 위도], ...] (단계마다 끝점이 다음 시작점과 겹치면 한 번만)."""
    points: list[list[float]] = []
    for step in leg.get("steps") or []:
        for pt in (step.get("path") or {}).get("points") or []:
            if not points or points[-1] != pt:
                points.append(pt)
    return points


def _straight_m(a: Coord, b: Coord) -> float:
    """두 좌표(경도, 위도) 사이 직선거리(m, 가까운 거리용 근사)"""
    dx = (a[0] - b[0]) * 111_320 * math.cos(math.radians((a[1] + b[1]) / 2))
    dy = (a[1] - b[1]) * 110_540
    return math.hypot(dx, dy)


def _estimate(start: Coord, end: Coord, via: list[Coord]) -> dict:
    """도보 한도를 다 썼을 때 쓰는 어림값. walk_route 와 같은 모양이고 "estimated": True 가 붙어요.
    길 모양은 모르니 지도에는 직선으로 그려져요."""
    stops = [start, *via, end]
    legs = []
    for a, b in zip(stops, stops[1:]):
        seconds = round(_straight_m(a, b) * WALK_DETOUR_RATIO / WALK_SPEED_MPS)
        legs.append({"seconds": seconds, "points": [list(a), list(b)]})
    return {"seconds": sum(leg["seconds"] for leg in legs), "legs": legs, "estimated": True}


def walk_route(start: Coord, end: Coord, via: list[Coord] | None = None, use_cache: bool = True,
               ttl_seconds: int = WALK_TTL_SECONDS) -> dict | None:
    """도보 시간과 실제 길 모양 (11/13: 지도에 도보가 직선으로 그려지던 문제).

    {"seconds": 전체 초, "legs": [{"seconds": 구간 초, "points": [[경도, 위도], ...]}, ...]}
    경유지가 있으면 구간이 경유지 수 + 1개예요 (출발 → 경유지 → 도착). 경로를 못 찾으면 None.
    walk_seconds 와 같은 API를 한 번 불러요.
    """
    via = [_rounded(c) for c in via or []]
    if len(via) > 5:
        raise ValueError("경유지는 최대 5개예요")
    start, end = _rounded(start), _rounded(end)
    if start == end and not via:
        return {"seconds": 0, "legs": [{"seconds": 0, "points": []}]}
    key = ("walk_route", start, end, tuple(via))
    cached = _cache_get(key) if use_cache else None
    if cached is not None:
        return cached
    params: dict = {"start_x": start[0], "start_y": start[1], "end_x": end[0], "end_y": end[1]}
    if via:
        params["via_x"] = ",".join(str(c[0]) for c in via)
        params["via_y"] = ",".join(str(c[1]) for c in via)
    try:
        data = _get("/v2/routing/walk", params)
    except KakaoError as e:
        if e.quota_exceeded:
            return _estimate(start, end, via)              # 어림값은 기억하지 않아요
        if _no_route(e):
            return None
        raise
    if data.get("status") != "OK":
        return None
    route = data["route"]
    legs = [{"seconds": int((leg.get("properties") or {}).get("time") or 0), "points": _leg_points(leg)}
            for leg in route.get("legs") or []]
    out = {"seconds": int(route["properties"]["totalTime"]), "legs": legs}
    if use_cache:
        _cache_set(key, out, ttl_seconds)
    return out
