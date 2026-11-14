"""틈길 FastAPI 서버 진입점.

실행:  cd server && uv run uvicorn app.main:app --reload
"""
import logging
import sqlite3
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.middleware.base import BaseHTTPMiddleware

from app import config
from app.db.database import init_db, seed_demo_data
from app.routers import assistant, places, plan, storage, transit


@asynccontextmanager
async def lifespan(_: FastAPI):
    init_db()
    if config.SEED_DEMO_DATA:
        seed_demo_data()
    yield


app = FastAPI(title="틈길 API", version="0.1.0", lifespan=lifespan)
log = logging.getLogger("app")


def error_response(status: int, code: str, message: str) -> JSONResponse:
    return JSONResponse(status_code=status, content={"error": {"code": code, "message": message}})


async def catch_unexpected(request, call_next):
    """처리하지 못한 오류도 {"error": ...} 형식으로 답해요. 자세한 내용은 서버 로그에만 남겨요.

    CORS 미들웨어보다 안쪽에 두어서 오류 응답에도 CORS 헤더가 붙어요 (Flutter 웹이 본문을 읽을 수 있게).
    """
    try:
        return await call_next(request)
    except sqlite3.OperationalError:
        log.exception("DB 오류: %s %s", request.method, request.url.path)
        return error_response(503, "db_busy", "잠시 뒤 다시 시도해 주세요")
    except Exception:  # noqa: BLE001 - 어떤 오류든 앱이 읽을 수 있는 형식으로 답해요
        log.exception("처리하지 못한 오류: %s %s", request.method, request.url.path)
        return error_response(500, "server_error", "서버에서 문제가 생겼어요. 잠시 뒤 다시 시도해 주세요")


# 나중에 추가한 미들웨어가 바깥쪽이에요: CORS → 오류 처리 → 라우터 순서
app.add_middleware(BaseHTTPMiddleware, dispatch=catch_unexpected)
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
app.include_router(assistant.router)
app.include_router(places.router)


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


CONSOLE_HTML = Path(__file__).resolve().parent / "static" / "console.html"


@app.get("/", include_in_schema=False)
def index() -> RedirectResponse:
    return RedirectResponse("/console")


@app.get("/console", include_in_schema=False)
def console() -> FileResponse:
    """브라우저에서 바로 눌러 보는 로컬 테스트 콘솔. Flutter 없이 API를 확인할 때 써요."""
    return FileResponse(CONSOLE_HTML, media_type="text/html; charset=utf-8")


# `cd app/Sync_ro_app && flutter build web --base-href /app/` 로 빌드해 두면
# 같은 서버가 실제 앱 화면도 /app 에서 보여 줘요 (CORS·mixed content 없이).
FLUTTER_WEB = Path(__file__).resolve().parents[2] / "app" / "Sync_ro_app" / "build" / "web"
if FLUTTER_WEB.is_dir():
    app.mount("/app", StaticFiles(directory=FLUTTER_WEB, html=True), name="flutter-web")