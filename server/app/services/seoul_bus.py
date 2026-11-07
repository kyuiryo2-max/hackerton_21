"""③ 조회: 서울시 버스 도착 정보 정리 (할 일 22번).

카카오 경로의 버스 구간(승차 좌표, 정류장 이름, 노선 번호, 다음 정류장)으로
서울시 버스 API의 정류소 번호(arsId)를 찾고, 그 노선의 실시간 도착을 초 단위로 돌려줘요.

    leg = kakao.transit_routes(start, end)[0]["legs"][0]
    found = seoul_bus.match_leg(leg)
    found["stop"]["ars_id"]               # "08301"
    found["arrival"]["first_seconds"]     # 39  (곧 도착)

정리 규칙 (외부 API 첫 호출 결과 #6~#9 노션 페이지 기준)
- 서울은 TAGO가 아니라 서울시 버스 API를 써요. 키는 DATA_GO_KR_SERVICE_KEY.
- 도착 시간은 문장(arrmsg1)이 아니라 traTime1(초)을 써요.
- 같은 이름 정류소가 길 양쪽에 있으면, 그 노선의 다음 정류장(nxtStn)이
  카카오 경로의 이후 정류장 중 하나와 같은 쪽을 골라요. 그래도 못 고르면 가까운 쪽이에요.
  (노션 메모는 adirection 이었지만, 종점 이름은 카카오 경로에 없어서 비교할 수 없어요)
- 개발계정 하루 1,000건이라 같은 요청은 잠시 저장해 다시 써요.
"""
import time
from typing import Any

import httpx

from app import config

BASE_URL = "http://ws.bus.go.kr/api/rest"
TIMEOUT_SECONDS = 10
NEAR_STOPS_TTL_SECONDS = 24 * 60 * 60  # 정류소 위치는 하루
ARRIVALS_TTL_SECONDS = 20              # 실시간 도착은 20초
MAX_CANDIDATES = 3                     # 정류소 후보마다 도착 조회 1건씩 쓰므로 최대 3곳까지만
COORD_DIGITS = 4
NO_SERVICE_WORDS = ("운행종료", "출발대기")

Coord = tuple[float, float]  # (경도 x, 위도 y)

_cache: dict[tuple, tuple[float, Any]] = {}


class SeoulBusError(Exception):
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
    _cache[key] = (time.monotonic() + ttl_seconds, value)


def _client() -> httpx.Client:
    return httpx.Client(timeout=TIMEOUT_SECONDS)


def _get(path: str, params: dict) -> dict:
    params = {"serviceKey": config.DATA_GO_KR_SERVICE_KEY, "resultType": "json", **params}
    try:
        with _client() as client:
            res = client.get(f"{BASE_URL}{path}", params=params)
    except httpx.HTTPError as e:
        raise SeoulBusError(f"서울시 버스 API 연결 실패: {type(e).__name__}") from None
    if res.status_code != 200:
        raise SeoulBusError(f"서울시 버스 API 오류: HTTP {res.status_code}")
    try:
        return res.json()
    except ValueError:
        # 키가 틀리면 JSON 대신 XML 오류가 와요
        raise SeoulBusError("서울시 버스 API 응답이 JSON이 아니에요 (키 확인)") from None


def _items(data: dict) -> list[dict]:
    """itemList를 항상 목록으로. headerCd 0은 정상, 4는 결과 없음, 나머지는 오류예요."""
    header = data.get("msgHeader") or {}
    code = str(header.get("headerCd", "0"))
    if code == "4":
        return []
    if code != "0":
        raise SeoulBusError(f"서울시 버스 API 오류: {code} {header.get('headerMsg', '')}".strip())
    items = (data.get("msgBody") or {}).get("itemList") or []
    return [items] if isinstance(items, dict) else list(items)


_IGNORED = set(" \t.·ㆍ‧,()-")


def _norm(name: str) -> str:
    """정류장 이름 비교용. 띄어쓰기와 '.', '·' 같은 구분 기호를 무시해요."""
    return "".join(ch for ch in (name or "") if ch not in _IGNORED)


def _int_or_none(value) -> int | None:
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return None


# ---------- 응답 정리 (외부 호출 없음, 테스트 대상) ----------
def parse_near_stops(data: dict) -> list[dict]:
    stops = [
        {
            "ars_id": s.get("arsId", ""),
            "station_id": s.get("stationId", ""),
            "name": s.get("stationNm", ""),
            "lng": float(s["gpsX"]),
            "lat": float(s["gpsY"]),
            "distance_m": _int_or_none(s.get("dist")),
        }
        for s in _items(data)
        if s.get("gpsX") and s.get("gpsY")
    ]
    return sorted(stops, key=lambda s: (s["distance_m"] is None, s["distance_m"] or 0))


def _arrival_seconds(tra_time, message: str) -> int | None:
    """도착까지 남은 초. 운행 종료·출발 대기처럼 올 차가 없으면 None."""
    message = message or ""
    if any(word in message for word in NO_SERVICE_WORDS):
        return None
    seconds = _int_or_none(tra_time)
    if seconds and seconds > 0:
        return seconds
    return 0 if "곧 도착" in message else None


def parse_arrivals(data: dict) -> list[dict]:
    """정류소 하나의 노선별 도착 정보. 시간은 초, 올 차가 없으면 None."""
    return [
        {
            "route": i.get("rtNm", ""),
            "route_id": i.get("busRouteId", ""),
            "ars_id": i.get("arsId", ""),
            "stop_name": i.get("stNm", ""),
            "direction": i.get("adirection", ""),   # 종점 방향, 예: 중랑공영차고지
            "next_stop": i.get("nxtStn", ""),       # 이 정류소 다음 정류장
            "first_seconds": _arrival_seconds(i.get("traTime1"), i.get("arrmsg1")),
            "second_seconds": _arrival_seconds(i.get("traTime2"), i.get("arrmsg2")),
            "first_message": i.get("arrmsg1", ""),
            "second_message": i.get("arrmsg2", ""),
            "first_is_last": str(i.get("isLast1", "0")) == "1",  # 막차
            "interval_minutes": _int_or_none(i.get("term")),     # 배차 간격
        }
        for i in _items(data)
    ]


def choose_stop(
    candidates: list[tuple[dict, list[dict]]],
    routes: list[str],
    next_stops: list[str] | str | None = None,
) -> dict | None:
    """정류소 후보(가까운 순)와 각 도착 목록에서 탈 정류소와 노선을 골라요.

    1. 노선 번호가 맞는 것만 남겨요.
    2. 둘 이상이면 서울시 API의 다음 정류장(nxtStn)이 카카오 경로의 이후 정류장 중 하나와
       같은 쪽을 골라요 (길 건너편 같은 이름 정류소 구분).
       종점 이름(adirection)은 카카오 경로에 없어서 비교에 못 쓰고, 화면 표시용으로만 담아요.
    3. 그래도 여럿이면 가장 가까운 쪽
    """
    if isinstance(next_stops, str):
        next_stops = [next_stops]
    wanted = {_norm(r) for r in routes if r}
    matches = [
        (stop, arrival)
        for stop, arrivals in candidates
        for arrival in arrivals
        if _norm(arrival["route"]) in wanted
    ]
    if not matches:
        return None
    ahead = {_norm(n) for n in next_stops or [] if n}
    if ahead and len(matches) > 1:
        same_way = [m for m in matches if _norm(m[1]["next_stop"]) in ahead]
        if same_way:
            matches = same_way
    stop, arrival = matches[0]  # candidates가 가까운 순이라 첫 번째가 가장 가까움
    return {"stop": stop, "arrival": arrival}


# ---------- 외부 호출 ----------
def near_stops(center: Coord, radius_m: int = 300) -> list[dict]:
    """좌표 근처 정류소, 가까운 순."""
    key = ("near", round(center[0], COORD_DIGITS), round(center[1], COORD_DIGITS), radius_m)
    cached = _cache_get(key)
    if cached is not None:
        return cached
    data = _get("/stationinfo/getStationByPos", {"tmX": center[0], "tmY": center[1], "radius": radius_m})
    stops = parse_near_stops(data)
    _cache_set(key, stops, NEAR_STOPS_TTL_SECONDS)
    return stops


def arrivals(ars_id: str) -> list[dict]:
    """정류소 번호(arsId)의 노선별 실시간 도착."""
    key = ("arrivals", ars_id)
    cached = _cache_get(key)
    if cached is not None:
        return cached
    result = parse_arrivals(_get("/stationinfo/getStationByUid", {"arsId": ars_id}))
    _cache_set(key, result, ARRIVALS_TTL_SECONDS)
    return result


def match_stop(
    board_at: Coord,
    stop_name: str,
    routes: list[str],
    next_stops: list[str] | str | None = None,
    radius_m: int = 300,
) -> dict | None:
    """승차 좌표·정류장 이름·노선 번호로 정류소를 찾고 그 노선의 도착 정보를 붙여요.

    같은 이름 정류소를 먼저 보고, 없으면 가까운 정류소에서 노선 번호로 찾아요.
    못 찾으면 None (경로 카드에서 실시간 대기를 빼고 계산하면 돼요).
    """
    stops = near_stops(board_at, radius_m)
    same_name = [s for s in stops if _norm(s["name"]) == _norm(stop_name)]
    candidates = (same_name or stops)[:MAX_CANDIDATES]
    return choose_stop([(s, arrivals(s["ars_id"])) for s in candidates], routes, next_stops)


def match_leg(leg: dict, radius_m: int = 300) -> dict | None:
    """kakao.parse_transit 의 버스 구간 하나로 match_stop 을 불러요."""
    if leg.get("type") != "BUS" or not leg.get("start") or not leg.get("stops"):
        return None
    stops = leg["stops"]
    return match_stop(
        board_at=tuple(leg["start"]),
        stop_name=stops[0],
        routes=leg.get("vehicles", []),
        next_stops=stops[1:],  # 승차 정류장 이후 정류장 전부
        radius_m=radius_m,
    )
