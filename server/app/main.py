"""틈길 FastAPI 서버 진입점.

실행:  cd server && uv run uvicorn app.main:app --reload
"""
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app import config
from app.db.database import init_db, seed_demo_data
from app.routers import storage


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


@app.get("/health")
def health() -> dict:
    """배포 확인용. 무료 서버를 시연 전에 깨울 때도 이 주소를 열어요."""
    return {"status": "ok"}
