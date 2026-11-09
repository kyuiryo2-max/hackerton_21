"""경로 계획 API (할 일 33번). 예시는 docs/design/api-examples/plan.json"""
from fastapi import APIRouter
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from app.services import planner

router = APIRouter(prefix="/api", tags=["경로 계획"])


class PlanIn(BaseModel):
    user_id: str = Field(min_length=1, examples=["demo"])
    schedule_id: int | None = Field(default=None, description="시연 모드에서는 시나리오 일정을 써서 쓰지 않아요")
    todo_ids: list[int] | None = Field(default=None, description="없으면 완료하지 않은 할 일 전부")
    demo: bool = False


def _error(status: int, code: str, message: str) -> JSONResponse:
    return JSONResponse(status_code=status, content={"error": {"code": code, "message": message}})


@router.post("/plan")
def plan(body: PlanIn):
    """출발 시각, 경로 카드, 할 일 포함·제외를 계산해요."""
    if not body.demo:
        # 실시간 경로는 출발 위치가 필요해요. 위치를 받지 않는 규칙이라 팀 결정 후 연결해요
        return _error(501, "not_ready", "실시간 경로 계획은 아직 연결되지 않았어요. demo=true로 시연 모드를 써 주세요")
    try:
        return planner.plan_demo(body.user_id, body.todo_ids)
    except planner.PlanError as e:
        return _error(e.status, e.code, e.message)
