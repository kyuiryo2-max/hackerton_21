"""AI 이해·대화 API (할 일 33·38번). 예시는 docs/design/api-examples/tasks_parse.json, ask.json"""
from fastapi import APIRouter
from pydantic import BaseModel, Field

from app.services import assistant
from app.services.trip import TripIn

router = APIRouter(prefix="/api", tags=["AI 이해·대화"])

MAX_TEXT = 200  # AI 비용과 남용을 막는 길이 제한


class ParseIn(BaseModel):
    user_id: str = Field(min_length=1, examples=["u1"])
    text: str = Field(min_length=1, max_length=MAX_TEXT, examples=["엄마 생신 선물 사야 해"])


class AskIn(BaseModel):
    user_id: str = Field(min_length=1, examples=["demo"])
    text: str = Field(min_length=1, max_length=MAX_TEXT, examples=["다음 버스 언제야?"])
    demo: bool = False
    # 이동 중이면 지금 단계와 시각 (11/13). 없으면 예전처럼 답해요
    trip: TripIn | None = None


@router.post("/tasks/parse")
def parse_task(body: ParseIn):
    """할 일 문장 → 장소 종류. 저장하지 않아요. 앱이 사용자 확인 뒤 POST /api/todos 로 저장해요."""
    return assistant.understand_todo(body.text.strip())


@router.post("/ask")
def ask(body: AskIn):
    """이동 중 질문 → 분류 → 계산 → 답변. 질문과 답변은 질문 기록에 저장해요."""
    return assistant.ask(body.user_id, body.text.strip(), body.demo, trip_context=body.trip)
