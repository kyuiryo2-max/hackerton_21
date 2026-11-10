"""LLM 모델 비교: 테스트 문장 40개로 정답률·응답 속도·사용량을 모델별로 재요.

서버가 쓰는 함수(server/app/services/llm.py)와 프롬프트(prompts/v1)를 그대로 써서,
고른 모델을 서버에 넣었을 때와 같은 결과가 나와요. 모델 하나에 40번 호출해요.

채점
- 질문 25개: 질문 종류(intents)가 정답과 같으면 통과. "값까지"는 장소 종류·늦는 분까지 맞아야 통과
- 할 일 15개: places는 장소 종류가 정답과 같고 되묻지 않음, confirm은 되묻기(needs_confirm),
  empty는 장소 없음 + 되묻지 않음

실행 (루트 .env 에 OPENAI_API_KEY 필요, server 폴더에서):
  uv run python ../scripts/compare_models.py 모델ID1 모델ID2 모델ID3
결과: 화면 표 + ai/results/model_compare_<날짜>.csv (케이스별)
"""
import csv
import statistics
import sys
import time
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "server"))

from app import config  # noqa: E402
from app.services import llm  # noqa: E402

TESTCASES = ROOT / "ai" / "testcases"
RETRIES = 2          # 429(붐빔)이면 잠깐 쉬고 다시
RETRY_WAIT_SECONDS = 5

_last = {"seconds": 0.0, "tokens": 0}
_original_chat_json = llm._chat_json


def _timed_chat_json(system: str, user: str) -> dict:
    """llm._chat_json 과 같은 호출에 걸린 시간과 토큰 수를 기록해요."""
    import json

    for attempt in range(RETRIES + 1):
        started = time.perf_counter()
        try:
            resp = llm._client().chat.completions.create(
                model=config.LLM_MODEL,
                temperature=0,
                response_format={"type": "json_object"},
                messages=[{"role": "system", "content": system}, {"role": "user", "content": user}],
            )
            break
        except Exception as e:  # noqa: BLE001
            if "429" in str(e) and attempt < RETRIES:
                time.sleep(RETRY_WAIT_SECONDS)
                continue
            raise
    _last["seconds"] = time.perf_counter() - started
    _last["tokens"] = getattr(resp.usage, "total_tokens", 0) if resp.usage else 0
    return json.loads(resp.choices[0].message.content or "{}")


llm._chat_json = _timed_chat_json


def _args(text: str) -> dict:
    """'place_types=편의점|마트;delay_minutes=10' → {'place_types': {...}, 'delay_minutes': '10'}"""
    out = {}
    for token in (text or "").split(";"):
        if "=" in token:
            k, v = token.split("=", 1)
            out[k.strip()] = {p for p in v.split("|") if p} if k.strip() == "place_types" else v.strip()
    return out


def _question_args_ok(intents: list[dict], expected: dict) -> bool:
    if "place_types" in expected:
        got = {p for i in intents for p in (i.get("place_types") or [])}
        if got != expected["place_types"]:
            return False
    if "delay_minutes" in expected:
        got = [i.get("delay_minutes") for i in intents if i.get("delay_minutes") is not None]
        if [str(g) for g in got] != [expected["delay_minutes"]]:
            return False
    return True


def _todo_ok(out: dict, behavior: str, expected: set[str]) -> bool:
    places, confirm = set(out.get("place_types") or []), bool(out.get("needs_confirm"))
    if behavior == "places":
        return places == expected and not confirm
    if behavior == "confirm":
        return confirm
    return not places and not confirm  # empty


def run_model(model: str) -> list[dict]:
    config.LLM_MODEL = model
    rows = []
    with open(TESTCASES / "questions.csv", encoding="utf-8") as f:
        for case in csv.DictReader(f):
            expected = sorted(case["expected_intents"].split("|"))
            try:
                intents = llm.classify_question(case["text"], context={}).get("intents", [])
                got, error = sorted(i.get("intent", "") for i in intents), ""
                ok = got == expected
                args_ok = ok and _question_args_ok(intents, _args(case["expected_args"]))
            except Exception as e:  # noqa: BLE001
                got, error, ok, args_ok = [], f"{type(e).__name__}: {str(e)[:80]}", False, False
            rows.append({"model": model, "kind": "질문", "id": case["id"], "text": case["text"],
                         "expected": "|".join(expected), "got": "|".join(got), "pass": ok, "args_pass": args_ok,
                         "seconds": round(_last["seconds"], 2), "tokens": _last["tokens"], "error": error})
    with open(TESTCASES / "tasks.csv", encoding="utf-8") as f:
        for case in csv.DictReader(f):
            expected = {p for p in case["expected_place_types"].split("|") if p}
            try:
                out = llm.parse_todo(case["text"])
                got = "|".join(out.get("place_types") or []) + (" (되묻기)" if out.get("needs_confirm") else "")
                ok, error = _todo_ok(out, case["expected_behavior"], expected), ""
            except Exception as e:  # noqa: BLE001
                got, ok, error = "", False, f"{type(e).__name__}: {str(e)[:80]}"
            rows.append({"model": model, "kind": "할 일", "id": case["id"], "text": case["text"],
                         "expected": f"{case['expected_behavior']}:{'|'.join(sorted(expected))}", "got": got,
                         "pass": ok, "args_pass": ok, "seconds": round(_last["seconds"], 2),
                         "tokens": _last["tokens"], "error": error})
    return rows


def summary(model: str, rows: list[dict]) -> dict:
    q = [r for r in rows if r["kind"] == "질문"]
    t = [r for r in rows if r["kind"] == "할 일"]
    ok = [r for r in rows if not r["error"]]
    return {
        "model": model,
        "질문 종류": f"{sum(r['pass'] for r in q)}/{len(q)}",
        "값까지": f"{sum(r['args_pass'] for r in q)}/{len(q)}",
        "할 일": f"{sum(r['pass'] for r in t)}/{len(t)}",
        "오류": len(rows) - len(ok),
        "응답(중간값)": f"{statistics.median(r['seconds'] for r in ok):.1f}초" if ok else "-",
        "응답(느린 쪽)": f"{max(r['seconds'] for r in ok):.1f}초" if ok else "-",
        "토큰/회": round(statistics.mean(r["tokens"] for r in ok)) if ok else 0,
    }


def main() -> None:
    models = sys.argv[1:]
    if not models:
        sys.exit("비교할 모델 ID를 넣어 주세요. 예: uv run python ../scripts/compare_models.py 모델ID1 모델ID2")
    if not config.OPENAI_API_KEY:
        sys.exit("루트 .env 에 OPENAI_API_KEY 가 없어요")

    all_rows, table = [], []
    for model in models:
        print(f"{model} 실행 중 (40번 호출)...", flush=True)
        rows = run_model(model)
        all_rows += rows
        table.append(summary(model, rows))

    out = ROOT / "ai" / "results" / f"model_compare_{date.today().isoformat()}.csv"
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8-sig", newline="") as f:  # 엑셀에서도 한글이 안 깨지게
        writer = csv.DictWriter(f, fieldnames=list(all_rows[0].keys()))
        writer.writeheader()
        writer.writerows(all_rows)

    print()
    headers = list(table[0].keys())
    print(" | ".join(headers))
    for row in table:
        print(" | ".join(str(row[h]) for h in headers))
    print(f"\n틀린 문장: {out.relative_to(ROOT)} 에서 pass 가 False 인 줄을 보세요")


if __name__ == "__main__":
    main()
