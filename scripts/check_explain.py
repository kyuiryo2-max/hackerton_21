"""AI 답변 문장 숫자 확인 (할 일 37번).

시연 질문마다 서버가 계산한 결과를 AI에게 주고 답변 문장을 받아, 숫자가 계산값과 맞는지 세요.
- AI 문장 사용: 숫자가 전부 계산 결과에 있어서 화면에 나가는 문장
- 거절: 계산에 없는 숫자를 써서 정해진 문장으로 바꾼 경우 (화면에는 안 나가요)
- 오류: AI 호출 실패, 10초 초과 → 정해진 문장

숫자 대조는 "없는 숫자를 지어냈는지"만 봐요. 숫자 자리가 바뀌었는지(12분 ↔ 20분)는
결과 CSV의 ai_answer 와 base_answer 를 사람이 비교해서 확인해요.

실행 (AI 키가 있는 .env 필요):
  cd server
  uv run python ../scripts/check_explain.py            # 질문 20개 × 3회
  uv run python ../scripts/check_explain.py --runs 1   # 빠르게 1회
"""
import argparse
import csv
import json
import sys
import time
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "server"))

from app.db import database  # noqa: E402
from app.services import assistant, llm  # noqa: E402

QUESTIONS = [
    "다음 버스 언제야?",
    "273번 언제 와?",
    "다음 차 몇 분 뒤야?",
    "커피도 사도 돼?",
    "편의점 들렀다 가도 돼?",
    "다이소 들러도 돼?",
    "10분 늦을 것 같아",
    "15분 늦을 것 같아",
    "버스 하나 놓쳤어",
    "몇 분까지 나가면 돼?",
    "지금 바로 나가야 돼?",
    "근처 약국 어디야?",
    "근처 편의점 어디야?",
    "환승 적은 걸로",
    "돈 덜 드는 쪽으로 가자",
    "커피는 안 사도 돼",
    "다이소가 더 급해",
    "이어폰은 안 사도 돼",
    "늦을 것 같은데 편의점은 들를 수 있어?",
    "5분 늦게 나가는데 다음 버스 언제야?",
    # 11/12: 모든 질문 종류로 AI 문장을 넓히면서 추가
    "다른 경로 없어?",
    "점심 뭐 먹지?",
    "오늘 날씨 어때?",
]


def one(text: str) -> dict:
    """서버 계산(정해진 문장)을 먼저 받고, 같은 결과로 AI 문장을 받아 숫자를 대조해요."""
    base = assistant.ask("demo", text, use_demo=True, explain_with_ai=False)
    intents = base.get("intents", [])
    row = {
        "question": text,
        "intents": "|".join(i["intent"] for i in base.get("intents", [])),
        "engine": base.get("engine", ""),
        "base_answer": base["answer"],
        "ai_answer": "",
        "allowed": "",
        "outcome": "",
        "seconds": "",
    }
    result = base.get("result")
    if base.get("needs_confirm") or not result:
        row["outcome"] = "건너뜀(되묻기·결과 없음)"
        return row
    if not assistant._ai_sentence_ok(intents, result):
        row["outcome"] = "건너뜀(계산 못 한 안내)"
        return row

    # 질문이 두 개면 서버는 결과 목록을 주지만, 응답에는 마지막 결과만 있어서 여기서는 그 하나로 재요
    allowed = llm.extract_allowed_numbers(result, base["answer"])
    row["allowed"] = " ".join(str(n) for n in sorted(allowed))
    payload = json.dumps({"question": text, "result": llm.short_times(result), "draft": base["answer"]},
                         ensure_ascii=False)
    start = time.perf_counter()
    try:
        out = llm._chat_json(llm.load_prompt("explain_result"), payload)
        ai = (out.get("answer") or "").strip()
    except Exception as e:  # 실패·시간 초과(5초)
        row.update(outcome=f"오류: {type(e).__name__}", seconds=f"{time.perf_counter() - start:.2f}")
        return row
    row["seconds"] = f"{time.perf_counter() - start:.2f}"
    row["ai_answer"] = ai
    if not ai:
        row["outcome"] = "오류: 빈 답변"
    elif not llm.numbers_match(ai, allowed):
        row["outcome"] = "거절(계산에 없는 숫자)"
    elif not assistant._ai_content_ok(ai, [result]):
        row["outcome"] = "거절(내용 검사)"
    else:
        row["outcome"] = "AI 문장 사용"
    return row


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--runs", type=int, default=3, help="같은 질문을 몇 번 돌릴지 (기본 3)")
    args = parser.parse_args()

    if not assistant._ai_ready():
        sys.exit(".env에 AI 키(OPENAI_API_KEY)가 없어요. 키가 있어야 AI 문장을 받을 수 있어요.")
    database.init_db()
    database.seed_demo_data()  # 시연 데이터를 처음 상태로 (서버 켤 때와 같게)

    rows = []
    for run in range(1, args.runs + 1):
        for text in QUESTIONS:
            row = {"run": run, **one(text)}
            rows.append(row)
            print(f"[{run}] {row['outcome']:<18} {text} → {row['ai_answer'] or row['base_answer']}")

    out_dir = ROOT / "ai" / "results"
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"explain_{llm.PROMPT_VERSION}_{date.today().isoformat()}.csv"
    with open(out, "w", newline="", encoding="utf-8-sig") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)

    tried = [r for r in rows if not r["outcome"].startswith("건너뜀")]
    used = sum(r["outcome"] == "AI 문장 사용" for r in tried)
    rejected = sum(r["outcome"] == "거절(계산에 없는 숫자)" for r in tried)
    content = sum(r["outcome"] == "거절(내용 검사)" for r in tried)
    errors = sum(r["outcome"].startswith("오류") for r in tried)
    secs = sorted(float(r["seconds"]) for r in tried if r["seconds"])
    print()
    print(f"AI 문장 시도 {len(tried)}번 (질문 {len(QUESTIONS)}개 × {args.runs}회, 되묻기 등 {len(rows) - len(tried)}번 건너뜀)")
    print(f"  AI 문장 사용 {used} / 거절(지어낸 숫자) {rejected} / 거절(경고 빠짐·하지 않은 일) {content} / 오류 {errors}")
    print("  화면에 나간 문장의 숫자 불일치: 0건 (거절된 문장은 정해진 문장으로 바뀌어요)")
    if secs:
        print(f"  AI 문장 응답 시간: 중간값 {secs[len(secs) // 2]:.2f}초, 가장 느린 것 {secs[-1]:.2f}초")
    print(f"저장: {out.relative_to(ROOT)}  ← ai_answer와 base_answer를 비교해 숫자 자리가 바뀐 문장이 없는지 확인해 주세요")


if __name__ == "__main__":
    main()
