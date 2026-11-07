"""40개 테스트 케이스(질문 25 + 할 일 15) 종합 로컬 검증 러너.

실행:
    python ai/test_runner.py
"""

from __future__ import annotations

import csv
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from ai.pipeline import (
    AppConfig,
    Event,
    MockProvider,
    MockRequestParser,
    run_pipeline,
)

KST = timezone(timedelta(hours=9))


def run_all_tests() -> None:
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8")
        except Exception:
            pass

    parser = MockRequestParser()
    provider = MockProvider()
    fixed_now = datetime(2026, 11, 7, 14, 0, 0, tzinfo=KST)
    config = AppConfig(
        schedule=[
            Event(
                title="프로젝트 회의 (강남)",
                start=fixed_now + timedelta(hours=2),  # 16:00
                location="신촌역 인근",
                preparation_minutes=15,
            )
        ]
    )

    print("=" * 85)
    print("🧪 [팀 Sync-ro AI 파이프라인 40개 테스트 케이스 종합 로컬 검증]")
    print(f"기준 시각: {fixed_now.isoformat()} | 다음 일정: {config.schedule[0].title} ({config.schedule[0].start.isoformat()})")
    print("=" * 85)

    # 1. Questions 검증 (25개)
    q_path = ROOT / "ai" / "testcases" / "questions.csv"
    q_results = []
    print("\n📋 [Part 1] 질문 문장 25개 분류 및 파이프라인 동작 검증 (ai/testcases/questions.csv)")
    print("-" * 85)
    print(f"{'ID':<4} | {'그룹':<8} | {'입력 질문':<24} | {'기대 의도':<22} | {'파이프라인 추출 의도'}")
    print("-" * 85)

    with open(q_path, encoding="utf-8") as f:
        for row in csv.DictReader(f):
            qid = row["id"]
            text = row["text"]
            expected = row["expected_intents"]
            group = row.get("group", "")

            out = run_pipeline(text, parser=parser, provider=provider, config=config, now=fixed_now, mode="question")
            actual_intents = [i["intent"] for i in out["parsed"]["intents"]]
            actual_str = "|".join(actual_intents)
            exp_list = expected.split("|")

            passed = sorted(actual_intents) == sorted(exp_list)
            q_results.append({
                "id": qid,
                "text": text,
                "group": group,
                "expected": expected,
                "actual": actual_str,
                "passed": passed,
                "answer": out["answer"],
            })

            mark = "✅" if passed else "❌"
            print(f"{qid:<4} | {group:<8} | {text:<24} | {expected:<22} | {actual_str} {mark}")

    # 2. Tasks 검증 (15개)
    t_path = ROOT / "ai" / "testcases" / "tasks.csv"
    t_results = []
    print("\n📋 [Part 2] 할 일 문장 15개 장소 매핑 검증 (ai/testcases/tasks.csv)")
    print("-" * 85)
    print(f"{'ID':<4} | {'행동':<8} | {'할 일 텍스트':<24} | {'기대 장소':<16} | {'추출 장소 / needs_confirm'}")
    print("-" * 85)

    with open(t_path, encoding="utf-8") as f:
        for row in csv.DictReader(f):
            tid = row["id"]
            text = row["text"]
            behavior = row["expected_behavior"]
            expected_places = row["expected_place_types"]

            out = run_pipeline(text, parser=parser, provider=provider, config=config, now=fixed_now, mode="todo")
            parsed_todo = out["parsed"]
            actual_places = parsed_todo.get("place_types", [])
            needs_confirm = parsed_todo.get("needs_confirm", False)
            places_str = "|".join(actual_places)

            if behavior == "places":
                exp_set = set(p for p in expected_places.split("|") if p)
                passed = (set(actual_places) == exp_set) and not needs_confirm
            elif behavior == "confirm":
                passed = needs_confirm and (len(actual_places) == 0)
            elif behavior == "empty":
                passed = (not needs_confirm) and (len(actual_places) == 0)
            else:
                passed = False

            t_results.append({
                "id": tid,
                "text": text,
                "behavior": behavior,
                "expected": expected_places,
                "actual": places_str,
                "needs_confirm": needs_confirm,
                "passed": passed,
                "answer": out["answer"],
            })

            mark = "✅" if passed else "❌"
            desc = f"{places_str} (confirm={needs_confirm})"
            print(f"{tid:<4} | {behavior:<8} | {text:<24} | {expected_places:<16} | {desc} {mark}")

    # 3. 종합 요약
    q_pass_cnt = sum(1 for r in q_results if r["passed"])
    t_pass_cnt = sum(1 for r in t_results if r["passed"])
    total_cnt = len(q_results) + len(t_results)
    total_pass = q_pass_cnt + t_pass_cnt

    print("\n" + "=" * 85)
    print("📊 [검증 결과 최종 종합 리포트]")
    print(f"• 질문 의도 분류 (Questions) : {q_pass_cnt} / {len(q_results)} 통과 ({q_pass_cnt/len(q_results)*100:.1f}%)")
    print(f"• 할 일 장소 매핑 (Tasks)     : {t_pass_cnt} / {len(t_results)} 통과 ({t_pass_cnt/len(t_results)*100:.1f}%)")
    print(f"• 전체 정합성 달성률          : {total_pass} / {total_cnt} 통과 ({total_pass/total_cnt*100:.1f}%)")
    print("=" * 85)


if __name__ == "__main__":
    run_all_tests()
