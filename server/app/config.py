"""환경 변수(.env) 읽기. 키 값은 코드에 직접 쓰지 않아요."""
import os
from pathlib import Path

from dotenv import load_dotenv

# 저장소 루트의 .env 를 읽어요 (server/ 에서 실행해도 동작)
load_dotenv(Path(__file__).resolve().parents[2] / ".env")


def env(name: str, default: str = "") -> str:
    return os.getenv(name, default)


def env_float(name: str, default: float) -> float:
    """숫자 환경 변수. 비었거나 숫자가 아니면 기본값을 써요 (서버가 안 뜨는 것보다 낫다)."""
    try:
        return float(env(name) or default)
    except ValueError:
        return default


OPENAI_KEY = OPENAI_API_KEY = env("OPENAI_API_KEY")
# OpenAI 호환이면 어디든 붙어요. 이 프로젝트는 Meta Model API(https://api.meta.ai/v1)를 씁니다.
OPENAI_BASE_URL = env("OPENAI_BASE_URL", "https://api.meta.ai/v1")
LLM_MODEL = env("LLM_MODEL")
EXPLAIN_WITH_AI = env("EXPLAIN_WITH_AI", "false").lower() == "true"

# AI 응답을 기다리는 시간(초). 기본 5초를 넘기지 않고, reasoning 모델처럼 느릴 때만 .env에서 늘려요.
LLM_TIMEOUT_SECONDS = env_float("LLM_TIMEOUT_SECONDS", 5)
# reasoning 모델의 사고량 (minimal | low | medium | high). 비우면 요청에 넣지 않아요.
LLM_REASONING_EFFORT = env("LLM_REASONING_EFFORT").strip()
# 샘플링 온도. 비우면 요청에 넣지 않아요 (Muse Spark는 기본 1.0에서 가장 잘 동작해요).
LLM_TEMPERATURE = env("LLM_TEMPERATURE").strip()
# 프롬프트 버전 폴더 (server/app/prompts/v1, v2, v3 …). 평가는 --prompt 로 따로 바꿔요.
LLM_PROMPT_VERSION = env("LLM_PROMPT_VERSION", "v3").strip() or "v3"

DATA_GO_KR_SERVICE_KEY = env("DATA_GO_KR_SERVICE_KEY")
SEOUL_OPEN_API_KEY = env("SEOUL_OPEN_API_KEY")
KAKAO_REST_API_KEY = env("KAKAO_REST_API_KEY")

DATABASE_PATH = env("DATABASE_PATH", "teumgil.db")
SEED_DEMO_DATA = env("SEED_DEMO_DATA", "true").lower() == "true"
