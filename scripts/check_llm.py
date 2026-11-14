"""LLM 첫 호출 확인 (할 일 3번).

서버가 쓰는 함수(server/app/services/llm.py)를 그대로 불러서, 키·모델이 동작하는지 봐요.
할 일 문장 1개, 질문 문장 1개 = 호출 2번. 결과는 화면에 나오고 ai/results/llm_first_call.json 에도 남아요.

실행 (루트 .env 에 OPENAI_API_KEY, LLM_MODEL 필요. OPENAI_BASE_URL 은 비우면 Meta Model API):
  cd server
  uv run python ../scripts/check_llm.py
"""
import json
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "server"))

from app import config  # noqa: E402
from app.services import llm  # noqa: E402

KST = timezone(timedelta(hours=9))
SAMPLES = [
    ("할 일 → 장소 종류", llm.parse_todo, "엄마 생신 선물 사야 해"),
    ("질문 → 질문 종류", llm.classify_question, "늦을 것 같은데 약국은 들를 수 있어?"),
]


def main() -> None:
    missing = [n for n in ("OPENAI_API_KEY", "LLM_MODEL") if not getattr(config, n)]
    if missing:
        sys.exit(f"루트 .env 에 {', '.join(missing)} 가 없어요")

    print(f"주소 {config.OPENAI_BASE_URL}\n모델 {config.LLM_MODEL}")
    print(f"프롬프트 {llm.PROMPT_VERSION} · 대기 {llm.LLM_TIMEOUT_SECONDS:g}초"
          + (f" · 사고량 {config.LLM_REASONING_EFFORT}" if config.LLM_REASONING_EFFORT else "") + "\n")
    record = {"at": datetime.now(KST).isoformat(timespec="seconds"),
              "base_url": config.OPENAI_BASE_URL, "model": config.LLM_MODEL,
              "prompt_version": llm.PROMPT_VERSION, "timeout_seconds": llm.LLM_TIMEOUT_SECONDS,
              "reasoning_effort": config.LLM_REASONING_EFFORT, "calls": []}
    ok = True
    for label, fn, text in SAMPLES:
        started = time.perf_counter()
        try:
            result = fn(text)
            error = None
        except Exception as e:  # 키나 요청 내용은 출력하지 않아요
            result, error = None, f"{type(e).__name__}: {str(e)[:200]}"
            ok = False
        seconds = round(time.perf_counter() - started, 2)
        print(f"[{label}] {text}  ({seconds}초)")
        print(f"  → {error or json.dumps(result, ensure_ascii=False)}\n")
        record["calls"].append({"label": label, "input": text, "seconds": seconds, "output": result, "error": error})

    out = ROOT / "ai" / "results" / "llm_first_call.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(("성공" if ok else "실패가 있어요") + f" → {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
