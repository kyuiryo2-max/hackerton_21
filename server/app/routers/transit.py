"""교통 정보 API. demo=true면 시연 모드 고정값, 아니면 서울시 실시간 정보를 돌려줘요. (할 일 30번)"""
from datetime import datetime

from fastapi import APIRouter, Query
from fastapi.responses import JSONResponse

from app import config
from app.services import demo as demo_mode
from app.services import seoul_bus, seoul_subway
from app.services.timecalc import wait_minutes_from_seconds

router = APIRouter(prefix="/api", tags=["교통 정보"])


def _minutes(seconds: int | None) -> int | None:
    return None if seconds is None else wait_minutes_from_seconds(seconds)


@router.get("/demo/context")
def demo_context():
    """시연 모드의 고정 시각·위치·일정. 앱은 이 값을 현재 상태로 보여 주면 돼요."""
    data = demo_mode.scenario()
    return {
        "now": data["now"],
        "location": data["location"],
        "schedule": data["schedule"],
        "stop": data["stop"],
        "route": data["route"],
    }


def _error(status: int, code: str, message: str) -> JSONResponse:
    return JSONResponse(status_code=status, content={"error": {"code": code, "message": message}})


def _bus_arrivals(stop_id: str) -> list[dict]:
    return [
        {
            "route": a["route"],
            "minutes": _minutes(a["first_seconds"]),
            "next_minutes": _minutes(a["second_seconds"]),
            "direction": a["direction"],
        }
        for a in seoul_bus.arrivals(stop_id)
    ]


def _subway_arrivals(station: str, line: str | None) -> list[dict]:
    """같은 호선·방향끼리 묶어 첫 차와 다음 차를 보여 줘요. 방향은 다음 역 이름이에요."""
    groups: dict[tuple[str, str], list[dict]] = {}
    for train in seoul_subway.arrivals(station):
        if line and train["line"] != line:
            continue
        groups.setdefault((train["line"], train["direction"]), []).append(train)
    result = []
    for (line_name, direction), trains in groups.items():
        trains.sort(key=lambda t: t["seconds"])
        result.append({
            "route": line_name,
            "minutes": _minutes(trains[0]["seconds"]),
            "next_minutes": _minutes(trains[1]["seconds"]) if len(trains) > 1 else None,
            "direction": f"{direction}방면" if direction else "",
            "estimated": trains[0]["estimated"],  # 실시간 초가 없어 남은 역 수로 계산한 값
        })
    return sorted(result, key=lambda a: (a["route"], a["minutes"]))


@router.get("/arrivals")
def arrivals(
    stop_id: str | None = Query(default=None, min_length=1, description="버스 정류소 번호(arsId)"),
    station: str | None = Query(default=None, min_length=1, description="지하철역 이름, 예: 안암(고대병원앞)"),
    line: str | None = Query(default=None, description="지하철 호선, 예: 6호선"),
    demo: bool = False,
    elapsed_seconds: int = Query(default=0, ge=0, description="시연에서 시간이 지난 장면"),
):
    """도착 정보. 버스는 stop_id, 지하철은 station으로 조회해요. 앱에는 분으로 내림해서 보내요."""
    if bool(stop_id) == bool(station):
        return _error(422, "invalid_request", "stop_id와 station 중 하나만 보내 주세요")
    if demo:
        return {
            "arrivals": [
                {
                    "route": a["route"],
                    "minutes": _minutes(a["first_seconds"]),
                    "next_minutes": _minutes(a["second_seconds"]),
                    "direction": a["direction"],
                }
                for a in demo_mode.arrivals(stop_id or "", elapsed_seconds)
            ]
        }
    key = config.DATA_GO_KR_SERVICE_KEY if stop_id else config.SEOUL_OPEN_API_KEY
    if not key:
        return _error(503, "not_configured", "서버에 교통 API 키가 설정되지 않았어요")
    try:
        found = _bus_arrivals(stop_id) if stop_id else _subway_arrivals(station, line)
    except (seoul_bus.SeoulBusError, seoul_subway.SeoulSubwayError) as e:
        return _error(502, "upstream_error", str(e))
    return {"arrivals": found, "fetched_at": datetime.now(seoul_subway.KST).isoformat(timespec="seconds")}
