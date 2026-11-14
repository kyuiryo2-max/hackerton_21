"""환경 변수(.env) 읽기. 키 값은 코드에 직접 쓰지 않아요."""
import os
from pathlib import Path

from dotenv import load_dotenv

# 저장소 루트의 .env 를 읽어요 (server/ 에서 실행해도 동작)
load_dotenv(Path(__file__).resolve().parents[2] / ".env")


def env(name: str, default: str = "") -> str:
    return os.getenv(name, default)


OPENAI_KEY = OPENAI_API_KEY = env("OPENAI_API_KEY")
OPENAI_BASE_URL = env("OPENAI_BASE_URL", "https://openrouter.ai/api/v1")
LLM_MODEL = env("LLM_MODEL")
EXPLAIN_WITH_AI = env("EXPLAIN_WITH_AI", "false").lower() == "true"

DATA_GO_KR_SERVICE_KEY = env("DATA_GO_KR_SERVICE_KEY")
SEOUL_OPEN_API_KEY = env("SEOUL_OPEN_API_KEY")
KAKAO_REST_API_KEY = env("KAKAO_REST_API_KEY")

DATABASE_PATH = env("DATABASE_PATH", "teumgil.db")
SEED_DEMO_DATA = env("SEED_DEMO_DATA", "true").lower() == "true"
