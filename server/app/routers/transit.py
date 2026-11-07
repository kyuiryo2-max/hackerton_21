"""교통 정보 API. demo=true면 시연 모드 고정값을 돌려줘요. (할 일 30번)"""
from fastapi import APIRouter, Query
from fastapi.responses import JSONResponse

from app.services import demo as demo_mode
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


@router.get("/arrivals")
def arrivals(
    stop_id: str = Query(min_length=1),
    demo: bool = False,
    elapsed_seconds: int = Query(default=0, ge=0, description="시연에서 시간이 지난 장면"),
):
    """정류소 도착 정보. 앱에는 분으로 내림해서 보내요."""
    if not demo:
        # 실시간 조회는 서울 버스 모듈(PR #10)이 머지되면 연결해요
        return JSONResponse(
            status_code=501,
            content={"error": {"code": "not_ready", "message": "실시간 도착은 아직 연결되지 않았어요"}},
        )
    return {
        "arrivals": [
            {
                "route": a["route"],
                "minutes": _minutes(a["first_seconds"]),
                "next_minutes": _minutes(a["second_seconds"]),
                "direction": a["direction"],
            }
            for a in demo_mode.arrivals(stop_id, elapsed_seconds)
        ]
    }
