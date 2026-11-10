"""경로 계획 API (할 일 33번). 예시는 docs/design/api-examples/plan.json"""
from fastapi import APIRouter
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from app import config
from app.services import planner

router = APIRouter(prefix="/api", tags=["경로 계획"])


class Origin(BaseModel):
    """앱 사용 중의 현재 위치. 계산에만 쓰고 저장하거나 기록하지 않아요 (11/9 팀 결정)."""
    lat: float = Field(ge=33, le=39, examples=[37.58625])
    lng: float = Field(ge=124, le=132, examples=[127.03045])


class PlanIn(BaseModel):
    user_id: str = Field(min_length=1, examples=["demo"])
    schedule_id: int | None = Field(default=None, description="없으면 가장 가까운 일정. 시연 모드에서는 쓰지 않아요")
    todo_ids: list[int] | None = Field(default=None, description="없으면 완료하지 않은 할 일 전부")
    origin: Origin | None = Field(default=None, description="실시간 계획(demo=false)에 필요한 현재 위치")
    demo: bool = False


def _error(status: int, code: str, message: str) -> JSONResponse:
    return JSONResponse(status_code=status, content={"error": {"code": code, "message": message}})


@router.post("/plan")
def plan(body: PlanIn):
    """출발 시각, 경로 카드, 할 일 포함·제외를 계산해요."""
    try:
        if body.demo:
            return planner.plan_demo(body.user_id, body.todo_ids)
        if body.origin is None:
            return _error(422, "invalid_request", "origin: 실시간 계획에는 현재 위치가 필요해요")
        if not config.KAKAO_REST_API_KEY:
            return _error(503, "not_configured", "서버에 교통 API 키가 설정되지 않았어요")
        origin = (body.origin.lng, body.origin.lat)
        return planner.plan_live(body.user_id, origin, body.schedule_id, body.todo_ids)
    except planner.PlanError as e:
        return _error(e.status, e.code, e.message)
