"""AI 정답률 평가: 키워드 규칙 vs AI. LLM을 호출하므로 로컬에서만 실행한다.

실행 (server 폴더에서):
    uv run python ../ai/eval/run.py --prompt v1

결과: ai/results/<prompt>_<날짜>.csv (케이스별 기대값, 결과, 통과 여부)
"""

import argparse
import csv
import sys
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "server"))

from app.services import llm  # noqa: E402

TESTCASES = ROOT / "ai" / "testcases"
RESULTS = ROOT / "ai" / "results"

# 비교 기준선: AI 없이 키워드만으로 분류했을 때
# 질문 종류 이름은 docs/design/json-format.md 2번 표와 같아야 해요.
KEYWORDS = {
    "running_late": ["늦", "놓쳤"],
    "next_vehicle": ["다음 버스", "다음 지하철", "언제 와"],
    "time_left": ["몇 분", "언제 나가"],
    "stopover_check": ["들러", "들렀", "들를", "사야", "사도"],
    "place_info": ["어디"],
    "change_route": ["환승", "빠른 걸로", "싼 걸로"],
    "change_todo": ["안 사도", "안 해도"],
}


def keyword_intents(text: str) -> list[str]:
    found = [intent for intent, words in KEYWORDS.items() if any(w in text for w in words)]
    # "안 사도 돼"는 빼기예요. "사도"만으로 들르기가 잡혔으면 지워요 (server/app/services/rules.py 와 같게)
    if "change_todo" in found and "stopover_check" in found and not any(
        w in text for w in ["들러", "들렀", "들를", "사야"]
    ):
        found.remove("stopover_check")
    return found or ["unsupported"]


def eval_questions(prompt_version: str) -> list[dict]:
    llm.PROMPT_VERSION = prompt_version
    rows = []
    with open(TESTCASES / "questions.csv", encoding="utf-8") as f:
        for case in csv.DictReader(f):
            expected = case["expected_intents"].split("|")
            kw = keyword_intents(case["text"])
            try:
                out = llm.classify_question(case["text"], context={})
                ai = [i["intent"] for i in out.get("intents", [])]
            except Exception as e:  # noqa: BLE001
                ai = [f"error: {e}"]
            rows.append(
                {
                    "id": case["id"],
                    "text": case["text"],
                    "expected": "|".join(expected),
                    "keyword": "|".join(kw),
                    "keyword_pass": sorted(kw) == sorted(expected),
                    "ai": "|".join(ai),
                    "ai_pass": sorted(ai) == sorted(expected),
                }
            )
    return rows


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--prompt", default="v1")
    args = parser.parse_args()

    rows = eval_questions(args.prompt)
    RESULTS.mkdir(exist_ok=True)
    out = RESULTS / f"questions_{args.prompt}_{date.today().isoformat()}.csv"
    with open(out, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)

    n = len(rows)
    kw = sum(r["keyword_pass"] for r in rows)
    ai = sum(r["ai_pass"] for r in rows)
    print(f"질문 → 의도  키워드 {kw}/{n}  AI {ai}/{n}  → {out.relative_to(ROOT)}")
    # TODO: tasks.csv(할 일 → 장소) 평가도 같은 방식으로 추가


if __name__ == "__main__":
    main()
