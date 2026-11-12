"""저장·조회 API (작업 표 16번). 실제 저장은 app/db/repository.py 가 해요.

http://127.0.0.1:8000/docs 에서 직접 눌러 볼 수 있어요.
목적지 좌표는 저장하지만, 사용자의 현재 위치는 받지도 저장하지도 않아요.
id로 조회·수정·삭제할 때는 ?user_id= 가 꼭 필요하고, 다른 사용자의 항목은 404로 답해요.
시연용 demo 데이터는 이 API로 바꿀 수 없어요 (403). 서버가 켜질 때마다 처음 상태로 돌아가요.
요청·응답 예시: docs/design/api.md, docs/design/api-examples/
"""
from datetime import datetime, timedelta, timezone
from typing import Literal

from fastapi import APIRouter, Query
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, field_validator

from app.db import repository as repo
from app.db.database import DEMO_USER_ID
from app.services.llm import place_types as allowed_place_types
from app.services import planner

router = APIRouter(prefix="/api", tags=["저장·조회"])

KST = timezone(timedelta(hours=9))
Importance = Literal["필수", "선택"]  # docs/design/json-format.md 기준
Status = Literal["대기", "포함", "제외", "완료"]  # #12 회의 3번
Source = Literal["입력", "질문"]
UserId = Query(min_length=1, description="기기마다 만든 임의 ID")


def _error(status: int, code: str, message: str) -> JSONResponse:
    return JSONResponse(status_code=status, content={"error": {"code": code, "message": message}})


def _not_found(what: str, id_) -> JSONResponse:
    return _error(404, "not_found", f"{what} {id_} 없음")


def _demo_readonly() -> JSONResponse:
    return _error(403, "demo_readonly", "시연용 demo 데이터는 바꿀 수 없어요")


def _normalize_time(value: str) -> str:
    """'2026-11-21T09:00:00+09:00' 형태로 맞춰요.
    시간대가 없으면 한국 시간으로 보고, 다른 시간대면 한국 시간으로 바꿔요."""
    dt = datetime.fromisoformat(value)
    dt = dt.replace(tzinfo=KST) if dt.tzinfo is None else dt.astimezone(KST)
    return dt.isoformat(timespec="seconds")


def _check_place_types(values: list[str] | None) -> list[str] | None:
    if values is None:
        return values
    unknown = [v for v in values if v not in set(allowed_place_types())]
    if unknown:
        raise ValueError(f"장소 종류 목록에 없는 값: {unknown} (data/demo/place_types.csv)")
    return values


# ---------- 일정 ----------
class ScheduleIn(BaseModel):
    user_id: str = Field(min_length=1, examples=["u1"])
    destination: str = Field(min_length=1, examples=["공학관"])
    destination_lat: float = Field(ge=-90, le=90, examples=[37.5833])
    destination_lng: float = Field(ge=-180, le=180, examples=[127.0263])
    arrive_by: str = Field(examples=["2026-11-21T09:00:00+09:00"])
    prep_minutes: int = Field(default=30, ge=0)

    _time = field_validator("arrive_by")(lambda cls, v: _normalize_time(v))


class ScheduleUpdate(BaseModel):
    destination: str | None = None
    destination_lat: float | None = Field(default=None, ge=-90, le=90)
    destination_lng: float | None = Field(default=None, ge=-180, le=180)
    arrive_by: str | None = None
    prep_minutes: int | None = Field(default=None, ge=0)

    @field_validator("arrive_by")
    @classmethod
    def _time(cls, v):
        return _normalize_time(v) if v else v


class Schedule(BaseModel):
    id: int
    user_id: str
    destination: str
    destination_lat: float
    destination_lng: float
    arrive_by: str
    prep_minutes: int


@router.post("/schedules", response_model=Schedule, status_code=201)
def create_schedule(body: ScheduleIn):
    if body.user_id == DEMO_USER_ID:
        return _demo_readonly()
    return repo.add_schedule(**body.model_dump())


@router.get("/schedules", response_model=list[Schedule])
def list_schedules(user_id: str = UserId):
    return repo.list_schedules(user_id)


@router.get("/schedules/{schedule_id}", response_model=Schedule)
def get_schedule(schedule_id: int, user_id: str = UserId):
    return repo.get_schedule(schedule_id, user_id) or _not_found("일정", schedule_id)


@router.patch("/schedules/{schedule_id}", response_model=Schedule)
def update_schedule(schedule_id: int, body: ScheduleUpdate, user_id: str = UserId):
    if user_id == DEMO_USER_ID:
        return _demo_readonly()
    return repo.update_schedule(schedule_id, user_id, **body.model_dump()) or _not_found("일정", schedule_id)


@router.delete("/schedules/{schedule_id}")
def delete_schedule(schedule_id: int, user_id: str = UserId):
    if user_id == DEMO_USER_ID:
        return _demo_readonly()
    return {"ok": True} if repo.delete_schedule(schedule_id, user_id) else _not_found("일정", schedule_id)


# ---------- 할 일 ----------
class TodoIn(BaseModel):
    user_id: str = Field(min_length=1, examples=["u1"])
    text: str = Field(min_length=1, examples=["약 사기"])
    place_types: list[str] = Field(default=[], examples=[["약국"]])
    importance: Importance = "선택"
    status: Status = "대기"
    source: Source = Field(default="입력", description="질문이면 중요도는 필수로 저장돼요")
    stay_minutes: int | None = Field(default=None, ge=1, le=120, examples=[10],
                                     description="그곳에 머무를 시간(분). 없으면 4분으로 계산해요")

    _places = field_validator("place_types")(lambda cls, v: _check_place_types(v))


class TodoUpdate(BaseModel):
    text: str | None = None
    place_types: list[str] | None = None
    stay_minutes: int | None = Field(default=None, ge=1, le=120)
    importance: Importance | None = None
    status: Status | None = None
    done: bool | None = Field(default=None, description="예전 방식. true 면 status 완료")

    _places = field_validator("place_types")(lambda cls, v: _check_place_types(v))


class Todo(BaseModel):
    id: int
    user_id: str
    text: str
    place_types: list[str]
    importance: Importance
    status: Status
    source: Source
    stay_minutes: int | None = None
    done: bool


@router.post("/todos", response_model=Todo, status_code=201)
def create_todo(body: TodoIn):
    if body.user_id == DEMO_USER_ID:
        return _demo_readonly()
    fields = body.model_dump()
    if fields.get("stay_minutes") is None:
        # 머무는 시간을 안 넣으면 장소 종류로 정해요 (편의점 4분, 은행 10분 …). 화면에서 바꿀 수 있어요
        fields["stay_minutes"] = planner.default_stay_minutes(fields.get("place_types"))
    return repo.add_todo(**fields)


@router.get("/todos", response_model=list[Todo])
def list_todos(user_id: str = UserId, done: bool | None = None, status: Status | None = None):
    """필수 먼저. done=false 는 완료가 아닌 할 일, status=포함 은 경로에 넣은 할 일만."""
    return repo.list_todos(user_id, done, status)


@router.patch("/todos/{todo_id}", response_model=Todo)
def update_todo(todo_id: int, body: TodoUpdate, user_id: str = UserId):
    if user_id == DEMO_USER_ID:
        return _demo_readonly()
    return repo.update_todo(todo_id, user_id, **body.model_dump()) or _not_found("할 일", todo_id)


@router.delete("/todos/{todo_id}")
def delete_todo(todo_id: int, user_id: str = UserId):
    if user_id == DEMO_USER_ID:
        return _demo_readonly()
    return {"ok": True} if repo.delete_todo(todo_id, user_id) else _not_found("할 일", todo_id)


# ---------- 설정 (경로 선호 가중치) ----------
class SettingsIn(BaseModel):
    w_time: float | None = Field(default=None, ge=0, le=1)
    w_transfer: float | None = Field(default=None, ge=0, le=1)
    w_fare: float | None = Field(default=None, ge=0, le=1)


class Settings(BaseModel):
    user_id: str
    w_time: float
    w_transfer: float
    w_fare: float


@router.get("/settings/{user_id}", response_model=Settings)
def get_settings(user_id: str):
    return repo.get_settings(user_id)


@router.put("/settings/{user_id}", response_model=Settings)
def save_settings(user_id: str, body: SettingsIn):
    if user_id == DEMO_USER_ID:
        return _demo_readonly()
    return repo.save_settings(user_id, **body.model_dump())


# ---------- 경로 선택 기록 ----------
class ChoiceIn(BaseModel):
    user_id: str = Field(min_length=1, examples=["demo"])
    chosen_route: dict = Field(examples=[{"total_min": 42, "transfers": 1, "fare": 1500}])
    other_routes: list[dict] = Field(default=[], examples=[[{"total_min": 48, "transfers": 0, "fare": 1500}]])


class Choice(BaseModel):
    id: int
    user_id: str
    chosen_route: dict
    other_routes: list[dict]
    created_at: str


@router.post("/choices", response_model=Choice, status_code=201)
def create_choice(body: ChoiceIn):
    """선택 기록은 쌓이기만 하고 시연 결과를 바꾸지 않아서 demo 도 저장해요 (시연 대본 3번)."""
    return repo.add_route_choice(**body.model_dump())


@router.get("/choices", response_model=list[Choice])
def list_choices(user_id: str = UserId):
    return repo.list_route_choices(user_id)


# ---------- 질문 기록 (#12 회의 4번) ----------
class Message(BaseModel):
    id: int
    user_id: str
    role: Literal["user", "assistant"]
    text: str
    intents: list[dict] | None
    created_at: str


@router.get("/messages", response_model=list[Message])
def list_messages(user_id: str = UserId, limit: int | None = Query(default=None, ge=1, le=100)):
    """대화창 다시 그리기용 (새로고침해도 대화 유지). 오래된 것부터.
    저장은 /api/ask 가 해요 (질문 1개 + 답변 1개)."""
    return repo.list_messages(user_id, limit)
