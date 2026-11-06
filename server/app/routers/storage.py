"""저장·조회 API (작업 표 16번). 실제 저장은 app/db/repository.py 가 해요.

http://127.0.0.1:8000/docs 에서 직접 눌러 볼 수 있어요.
위치(현재 위치, 좌표)는 받지도 저장하지도 않아요.
"""
from datetime import datetime, timedelta, timezone
from typing import Literal

from fastapi import APIRouter, Query
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, field_validator

from app.db import repository as repo
from app.services.llm import place_types as allowed_place_types

router = APIRouter(prefix="/api", tags=["저장·조회"])

KST = timezone(timedelta(hours=9))
Importance = Literal["필수", "선택"]  # docs/design/json-format.md 기준


def _not_found(what: str, id_) -> JSONResponse:
    return JSONResponse(status_code=404, content={"error": {"code": "not_found", "message": f"{what} {id_} 없음"}})


def _normalize_time(value: str) -> str:
    """'2026-11-21T09:00' 형태로 맞춰요. 시간대가 붙어 오면 한국 시간으로 바꿔요."""
    dt = datetime.fromisoformat(value)
    if dt.tzinfo is not None:
        dt = dt.astimezone(KST).replace(tzinfo=None)
    return dt.isoformat(timespec="minutes")


def _check_place_types(values: list[str] | None) -> list[str] | None:
    if values is None:
        return values
    unknown = [v for v in values if v not in set(allowed_place_types())]
    if unknown:
        raise ValueError(f"장소 종류 목록에 없는 값: {unknown} (data/demo/place_types.csv)")
    return values


# ---------- 일정 ----------
class ScheduleIn(BaseModel):
    user_id: str = Field(min_length=1, examples=["demo"])
    destination: str = Field(min_length=1, examples=["공학관"])
    arrive_by: str = Field(examples=["2026-11-21T09:00"])
    prep_minutes: int = Field(default=30, ge=0)

    _time = field_validator("arrive_by")(lambda cls, v: _normalize_time(v))


class ScheduleUpdate(BaseModel):
    destination: str | None = None
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
    arrive_by: str
    prep_minutes: int


@router.post("/schedules", response_model=Schedule, status_code=201)
def create_schedule(body: ScheduleIn):
    return repo.add_schedule(**body.model_dump())


@router.get("/schedules", response_model=list[Schedule])
def list_schedules(user_id: str = Query(min_length=1)):
    return repo.list_schedules(user_id)


@router.get("/schedules/{schedule_id}", response_model=Schedule)
def get_schedule(schedule_id: int):
    return repo.get_schedule(schedule_id) or _not_found("일정", schedule_id)


@router.patch("/schedules/{schedule_id}", response_model=Schedule)
def update_schedule(schedule_id: int, body: ScheduleUpdate):
    return repo.update_schedule(schedule_id, **body.model_dump()) or _not_found("일정", schedule_id)


@router.delete("/schedules/{schedule_id}")
def delete_schedule(schedule_id: int):
    return {"ok": True} if repo.delete_schedule(schedule_id) else _not_found("일정", schedule_id)


# ---------- 할 일 ----------
class TodoIn(BaseModel):
    user_id: str = Field(min_length=1, examples=["demo"])
    text: str = Field(min_length=1, examples=["약 사기"])
    place_types: list[str] = Field(default=[], examples=[["약국"]])
    importance: Importance = "선택"

    _places = field_validator("place_types")(lambda cls, v: _check_place_types(v))


class TodoUpdate(BaseModel):
    text: str | None = None
    place_types: list[str] | None = None
    importance: Importance | None = None
    done: bool | None = None

    _places = field_validator("place_types")(lambda cls, v: _check_place_types(v))


class Todo(BaseModel):
    id: int
    user_id: str
    text: str
    place_types: list[str]
    importance: Importance
    done: bool


@router.post("/todos", response_model=Todo, status_code=201)
def create_todo(body: TodoIn):
    return repo.add_todo(**body.model_dump())


@router.get("/todos", response_model=list[Todo])
def list_todos(user_id: str = Query(min_length=1), done: bool | None = None):
    """필수 먼저. done=false 로 남은 할 일만 볼 수 있어요."""
    return repo.list_todos(user_id, done)


@router.patch("/todos/{todo_id}", response_model=Todo)
def update_todo(todo_id: int, body: TodoUpdate):
    return repo.update_todo(todo_id, **body.model_dump()) or _not_found("할 일", todo_id)


@router.delete("/todos/{todo_id}")
def delete_todo(todo_id: int):
    return {"ok": True} if repo.delete_todo(todo_id) else _not_found("할 일", todo_id)


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
    return repo.add_route_choice(**body.model_dump())


@router.get("/choices", response_model=list[Choice])
def list_choices(user_id: str = Query(min_length=1)):
    return repo.list_route_choices(user_id)
