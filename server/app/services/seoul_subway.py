"""③ 조회: 서울 지하철 실시간 도착 정리 (할 일 23번).

카카오 경로의 지하철 구간(역 이름, 호선, 다음 역)으로 탈 방향의 열차를 찾아 초 단위로 돌려줘요.

    leg = kakao.transit_routes(start, end)[0]["legs"][0]
    found = seoul_subway.match_leg(leg)
    found["trains"][0]["seconds"]     # 180
    found["trains"][0]["estimated"]   # False

정리 규칙 (실제 응답 12개 역, 134건 확인)
- barvlDt가 0이어도 곧 도착이 아니에요. 1호선 일부, 경의중앙선 등은 항상 0이에요.
  도착 코드(arvlCd)와 "[23]번째 전역" 문장으로 대략 계산하고 estimated로 표시해요.
- 코레일 구간은 응답이 몇 분 전 값일 수 있어서 recptnDt로 지난 시간을 빼요.
- 방향은 trainLineNm의 "X방면"이 카카오 경로의 이후 역과 같은 쪽이에요.
  확인이 안 되면 추측하지 않고 None이에요.
- 역명은 역마다 달라요. "안암(고대병원앞)"은 괄호까지, "고려대(종암)"은 "고려대"로 찾아져요.
- 급행 구간은 카카오에 정차역만 있어서 방향 확인이 안 될 수 있어요. 이때도 None이에요.
"""
import re
import time
from datetime import datetime, timedelta, timezone
from typing import Any
from urllib.parse import quote

import httpx

from app import config

BASE_URL = "http://swopenAPI.seoul.go.kr/api/subway"
TIMEOUT_SECONDS = 10
ARRIVALS_TTL_SECONDS = 20
MAX_ROWS = 30
SECONDS_PER_STATION = 120      # 몇 번째 전역만 알 때 역 하나당 추정 시간
GONE_AFTER_SECONDS = 30        # 도착 예정 시각이 이만큼 지났으면 이미 떠난 차로 봐요

KST = timezone(timedelta(hours=9))

ARRIVAL_ENTERING = "0"         # 진입
ARRIVAL_AT_STATION = "1"       # 도착
ARRIVAL_DEPARTED = "2"         # 출발: 이미 탈 수 없어요
ESTIMATE_BY_CODE = {
    ARRIVAL_ENTERING: 30,
    ARRIVAL_AT_STATION: 0,
    "3": 120,                  # 전역 출발
    "4": 150,                  # 전역 진입
    "5": 120,                  # 전역 도착
}

LINE_NAMES = {
    "1001": "1호선", "1002": "2호선", "1003": "3호선", "1004": "4호선", "1005": "5호선",
    "1006": "6호선", "1007": "7호선", "1008": "8호선", "1009": "9호선", "1032": "GTX-A",
    "1063": "경의중앙선", "1065": "공항철도", "1067": "경춘선", "1075": "수인분당선",
    "1077": "신분당선", "1081": "경강선", "1092": "우이신설선", "1093": "서해선", "1094": "신림선",
}

_STATIONS_AWAY = re.compile(r"\[(\d+)\]번째 전역")
_PARENTHESES = re.compile(r"\([^)]*\)")
_DIRECTION = re.compile(r"-\s*(.+?)방면")

_cache: dict[tuple, tuple[float, Any]] = {}


class SeoulSubwayError(Exception):
    """호출 실패. 오류 문장에 키나 요청 주소를 넣지 않아요."""


def clear_cache() -> None:
    _cache.clear()


def _client() -> httpx.Client:
    return httpx.Client(timeout=TIMEOUT_SECONDS)


def _station_key(name: str) -> str:
    """역 이름 비교용. 괄호와 공백, 끝의 '역'을 무시해요. 서울역은 서울과 같아요."""
    name = _PARENTHESES.sub("", name or "").replace(" ", "")
    return name[:-1] if name.endswith("역") and len(name) > 1 else name


def station_names(name: str) -> list[str]:
    """API에 넣어 볼 역명 순서. 카카오 표기 → 괄호 제거 → '역' 제거."""
    names = [name, _PARENTHESES.sub("", name).strip(), _station_key(name)]
    return list(dict.fromkeys(n for n in names if n))


def _int_or_none(value) -> int | None:
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return None


def _base_seconds(item: dict) -> tuple[int | None, bool]:
    """(남은 초, 추정 여부). 탈 수 없는 차나 계산할 수 없으면 초가 None이에요."""
    code = str(item.get("arvlCd", ""))
    if code == ARRIVAL_DEPARTED:
        return None, False
    seconds = _int_or_none(item.get("barvlDt"))
    if seconds:
        return seconds, False
    if code in ESTIMATE_BY_CODE:
        return ESTIMATE_BY_CODE[code], code != ARRIVAL_AT_STATION
    away = _STATIONS_AWAY.search(item.get("arvlMsg2") or "")
    if away:
        return int(away[1]) * SECONDS_PER_STATION, True
    return None, False


def _elapsed_seconds(received_at: str | None, now: datetime) -> int:
    """응답이 만들어진 뒤 지난 초. 시계가 앞서 있어 음수면 0이에요."""
    try:
        received = datetime.strptime(received_at or "", "%Y-%m-%d %H:%M:%S").replace(tzinfo=KST)
    except ValueError:
        return 0
    return max(int((now - received).total_seconds()), 0)


def parse_arrivals(data: dict, now: datetime | None = None) -> list[dict]:
    """역 하나의 열차 목록. 이미 떠난 차를 빼고 빨리 오는 순으로 정리해요."""
    now = now or datetime.now(KST)
    trains: dict[str, dict] = {}
    for item in data.get("realtimeArrivalList") or []:
        seconds, estimated = _base_seconds(item)
        if seconds is None:
            continue
        seconds -= _elapsed_seconds(item.get("recptnDt"), now)
        if seconds < -GONE_AFTER_SECONDS:
            continue
        line_name = item.get("trainLineNm") or ""
        direction = _DIRECTION.search(line_name)
        train = {
            "line": LINE_NAMES.get(str(item.get("subwayId")), ""),
            "up_down": item.get("updnLine", ""),
            "direction": direction[1].strip() if direction else "",  # 다음 역, 예: 고려대
            "destination": item.get("bstatnNm", ""),
            "seconds": max(seconds, 0),
            "estimated": estimated,
            "message": item.get("arvlMsg2", ""),
            "is_express": item.get("btrainSttus") == "급행",
            "is_last": str(item.get("lstcarAt", "0")) == "1",
            "train_no": str(item.get("btrainNo", "")),
        }
        # 같은 열차가 호선별로 두 번 올 때가 있어서 더 정확한 값을 남겨요
        key = train["train_no"] or str(id(item))
        if key not in trains or trains[key]["estimated"]:
            trains[key] = train
    return sorted(trains.values(), key=lambda t: (t["estimated"], t["seconds"]))


def choose_trains(trains: list[dict], lines: list[str], next_stops: list[str]) -> list[dict]:
    """호선이 맞고 진행 방향이 카카오 경로의 이후 역과 같은 열차만 남겨요."""
    ahead = {_station_key(s) for s in next_stops if s}
    wanted = set(lines)
    return [
        t for t in trains
        if t["line"] in wanted and _station_key(t["direction"]) in ahead
    ]


def _fetch(name: str) -> dict:
    # 주소에 키가 들어가므로 오류 문장에 주소를 쓰지 않아요
    url = f"{BASE_URL}/{config.SEOUL_OPEN_API_KEY}/json/realtimeStationArrival/0/{MAX_ROWS}/{quote(name)}"
    try:
        with _client() as client:
            res = client.get(url)
    except httpx.HTTPError as e:
        raise SeoulSubwayError(f"서울 지하철 API 연결 실패: {type(e).__name__}") from None
    if res.status_code != 200:
        raise SeoulSubwayError(f"서울 지하철 API 오류: HTTP {res.status_code}")
    try:
        return res.json()
    except ValueError:
        raise SeoulSubwayError("서울 지하철 API 응답이 JSON이 아니에요") from None


def _status_code(data: dict) -> str:
    return str((data.get("errorMessage") or data).get("code") or "")


def _trains_at(name: str, now: datetime | None) -> list[dict]:
    """API 역명 그대로 조회해요. 없는 역이면 빈 목록이에요."""
    cached = _cache.get(name)
    if cached and time.monotonic() < cached[0]:
        return parse_arrivals(cached[1], now)
    data = _fetch(name)
    code = _status_code(data)
    if code.startswith(("INFO-1", "ERROR")):
        raise SeoulSubwayError(f"서울 지하철 API 오류: {code}")
    if code == "INFO-200":
        return []
    _cache[name] = (time.monotonic() + ARRIVALS_TTL_SECONDS, data)
    return parse_arrivals(data, now)


def arrivals(station: str, now: datetime | None = None) -> list[dict]:
    """역 이름으로 실시간 열차 목록을 받아요. 없으면 표기를 바꿔 다시 시도해요."""
    for name in station_names(station):
        trains = _trains_at(name, now)
        if trains:
            return trains
    return []


def match_leg(leg: dict, now: datetime | None = None) -> dict | None:
    """kakao.parse_transit 의 지하철 구간으로 탈 방향의 열차를 찾아요.

    못 찾으면 None이에요. (경로 카드에서 실시간 대기를 빼고 계산하면 돼요)
    """
    if leg.get("type") != "SUBWAY" or not leg.get("stops"):
        return None
    station = leg["stops"][0]
    # "서울역"은 GTX-A만, "서울"은 나머지 호선이 나와서 표기마다 찾아봐요
    for name in station_names(station):
        trains = choose_trains(_trains_at(name, now), leg.get("vehicles", []), leg["stops"][1:])
        if trains:
            return {"station": station, "trains": trains}
    return None
