"""틈길 FastAPI 서버 진입점.

실행:  cd server && uv run uvicorn app.main:app --reload
"""
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from app import config
from app.db.database import init_db, seed_demo_data
from app.routers import plan, storage, transit


@asynccontextmanager
async def lifespan(_: FastAPI):
    init_db()
    if config.SEED_DEMO_DATA:
        seed_demo_data()
    yield


app = FastAPI(title="틈길 API", version="0.1.0", lifespan=lifespan)

# Flutter 웹에서 호출할 수 있게 허용 (배포 후 실제 주소로 좁히기)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(storage.router)
app.include_router(transit.router)
app.include_router(plan.router)


# 오류 응답을 기준 문서 형식 {"error": {"code", "message"}} 하나로 맞춰요.
@app.exception_handler(RequestValidationError)
async def invalid_request(_, exc: RequestValidationError):
    first = exc.errors()[0]
    field = ".".join(str(p) for p in first["loc"] if p not in ("body", "query", "path"))
    message = f"{field}: {first['msg']}" if field else first["msg"]
    return JSONResponse(status_code=422, content={"error": {"code": "invalid_request", "message": message}})


@app.exception_handler(StarletteHTTPException)
async def http_error(_, exc: StarletteHTTPException):
    code = {404: "not_found", 405: "method_not_allowed"}.get(exc.status_code, "http_error")
    return JSONResponse(
        status_code=exc.status_code,
        content={"error": {"code": code, "message": str(exc.detail)}},
        headers=getattr(exc, "headers", None),
    )


@app.get("/health")
def health() -> dict:
    """배포 확인용. 무료 서버를 시연 전에 깨울 때도 이 주소를 열어요."""
    return {"status": "ok"}