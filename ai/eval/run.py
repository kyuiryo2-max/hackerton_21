"""AI 의도 분류 고도화 평가 오케스트레이션 및 CLI (run.py).

실행 예시 (server 폴더에서):
    # 기존 동작 완전 유지 (키워드 vs LLM)
    uv run python ../ai/eval/run.py --prompt v1

    # 고도화 실행 (키워드 + 벡터 Top-m + LLM 캐시 + 정책 평가)
    uv run python ../ai/eval/run.py --prompt v1 --split validation \
        --methods keyword,vector,llm \
        --vector-model jhgan/ko-sroberta-multitask \
        --top-m 2 --thresholds ../ai/vector/thresholds.json \
        --llm-cache
"""

from __future__ import annotations

import argparse
import csv
import subprocess
import sys
import time
from datetime import date
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
# server 폴더와 ROOT 모두 import 가능하도록 추가
sys.path.insert(0, str(ROOT / "server"))
sys.path.insert(0, str(ROOT))

from ai.eval.cache import LLMCache
from ai.eval.metrics import (
    compute_classification_metrics,
    compute_latency_stats,
    compute_policy_metrics,
)
from ai.eval.policies import (
    evaluate_policy_p0,
    evaluate_policy_p1,
    evaluate_policy_p2,
    evaluate_policy_p3,
    evaluate_policy_p4,
)
from ai.eval.report import save_cases_csv, save_report_md, save_summary_json
from ai.intents import KEYWORDS, LABELS, extract_slots, validate_slots
from ai.vector.classifier import VectorIntentClassifier

TESTCASES_DIR = ROOT / "ai" / "testcases"
RESULTS_DIR = ROOT / "ai" / "results"


def get_git_sha() -> str:
    """현재 git commit SHA를 가져옵니다."""
    try:
        out = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=str(ROOT), stderr=subprocess.DEVNULL
        )
        return out.decode("utf-8").strip()
    except Exception:
        return "unknown"


def keyword_intents(text: str) -> list[str]:
    """비교 기준선: 키워드 규칙 기반 의도 분류."""
    found = [intent for intent, words in KEYWORDS.items() if any(w in text for w in words)]
    # "안 사도 돼"는 빼기. "사도"만으로 들르기가 잡혔으면 제거
    if "change_todo" in found and "stopover_check" in found:
        if not any(w in text for w in ["들러", "들렀", "들를", "사야"]):
            found.remove("stopover_check")
    # "몇 분 늦어"는 늦어짐 우선
    if "running_late" in found and "time_left" in found:
        found.remove("time_left")
    return found or ["unsupported"]


def keyword_classify_full(text: str) -> dict[str, Any]:
    """키워드 의도 및 슬롯 추출 전체 결과."""
    names = keyword_intents(text)
    intents = []
    for n in names:
        slots = extract_slots(n, text)
        intents.append({"intent": n, **slots})
    needs_confirm = any(
        i["intent"] in ("stopover_check", "place_info") and not i.get("place_types")
        for i in intents
    )
    return {
        "intents": intents,
        "needs_confirm": needs_confirm,
    }


def load_testcases(split_name: str) -> list[dict[str, Any]]:
    """지정된 split의 테스트 케이스 CSV를 로드합니다."""
    # .csv 확장자가 붙어있거나 없는 경우 모두 지원
    filename = split_name if split_name.endswith(".csv") else f"{split_name}.csv"
    path = TESTCASES_DIR / filename
    if not path.exists():
        raise FileNotFoundError(f"테스트 케이스 파일을 찾을 수 없습니다: {path}")

    cases = []
    with open(path, encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            intents_str = row.get("expected_intents") or row.get("expected") or ""
            expected = [it.strip() for it in intents_str.split("|") if it.strip()]
            cases.append(
                {
                    "id": row.get("id", f"case_{len(cases)}"),
                    "text": row["text"],
                    "expected": expected,
                    "expected_args": row.get("expected_args", ""),
                    "group": row.get("group", ""),
                }
            )
    return cases


def run_evaluation(args: argparse.Namespace) -> None:
    split_name = args.split
    methods = [m.strip().lower() for m in args.methods.split(",") if m.strip()]
    cases = load_testcases(split_name)

    # 1. LLM 모듈 및 캐시 준비
    llm_module = None
    prompt_text = ""
    llm_cache = LLMCache(enabled=args.llm_cache)
    if "llm" in methods and not args.no_llm:
        try:
            from app.services import llm

            llm.PROMPT_VERSION = args.prompt
            prompt_text = llm.load_prompt("question_intent", version=args.prompt)
            llm_module = llm
        except Exception as e:
            print(f"[경고] LLM 모듈 로드 실패 ({e}). LLM 평가는 캐시 또는 건너뜁니다.")

    # 2. 벡터 분류기 준비
    vector_classifier = None
    if "vector" in methods:
        vector_classifier = VectorIntentClassifier(
            thresholds_path=args.thresholds,
            model_name=args.vector_model,
            top_m=args.top_m,
        )

    # 3. 케이스별 순회 평가
    rows: list[dict[str, Any]] = []
    latencies: list[float] = []

    for case in cases:
        t0 = time.perf_counter()
        c_id = case["id"]
        text = case["text"]
        expected = case["expected"]
        group = case["group"]
        expected_args = case["expected_args"]

        # [Method 1] Keyword
        kw_full = keyword_classify_full(text)
        kw_intents = [i["intent"] for i in kw_full["intents"]]
        kw_pass = sorted(kw_intents) == sorted(expected)

        # [Method 2] Vector
        vec_res: dict[str, Any] = {}
        vec_intents: list[str] = []
        vec_status = ""
        vec_abstain_reason = None
        vec_scores: dict[str, float] = {}
        vec_evidence: list[dict[str, Any]] = []

        if vector_classifier is not None:
            vec_res = vector_classifier.classify(text)
            vec_status = vec_res.get("status", "")
            vec_intents = [i["intent"] for i in vec_res.get("intents", [])]
            vec_abstain_reason = vec_res.get("abstain_reason")
            vec_scores = vec_res.get("scores", {})
            vec_evidence = vec_res.get("evidence", [])

        vec_pass = sorted(vec_intents) == sorted(expected) if vec_intents else False

        # [Method 3] LLM (with cache)
        llm_intents: list[str] = []
        llm_called_for_case = False

        def call_llm() -> dict[str, Any]:
            nonlocal llm_called_for_case
            llm_called_for_case = True
            # 캐시 조회
            if not args.refresh_llm:
                cached = llm_cache.get(prompt_text, text, context={})
                if cached is not None:
                    return cached
            if llm_module is not None:
                try:
                    out = llm_module.classify_question(text, context={})
                    llm_cache.set(prompt_text, text, context={}, response=out)
                    return out
                except Exception as err:
                    return {"intents": [{"intent": f"error: {err}"}], "needs_confirm": True}
            return {"intents": [{"intent": "unsupported"}], "needs_confirm": True}

        # LLM 직접 단독 평가가 필요한 경우
        if "llm" in methods:
            if not args.no_llm:
                llm_out = call_llm()
                llm_intents = [i["intent"] for i in llm_out.get("intents", [])]
            else:
                llm_intents = ["skipped_no_llm"]

        llm_pass = sorted(llm_intents) == sorted(expected)

        # [Policy 평가] P0 ~ P4 라우팅
        policy_name = args.policy.upper()
        if policy_name == "P0":
            pol_res = evaluate_policy_p0(kw_full)
        elif policy_name == "P1":
            pol_res = evaluate_policy_p1(text, {}, call_llm)
        elif policy_name == "P3":
            pol_res = evaluate_policy_p3(text, {}, kw_full, vec_res, call_llm)
        elif policy_name == "P4":
            pol_res = evaluate_policy_p4(text, {}, kw_full, vec_res, call_llm)
        else:  # P2 기본값
            pol_res = evaluate_policy_p2(text, {}, kw_full, vec_res, call_llm)

        pol_intents = pol_res["policy"]
        pol_pass = sorted(pol_intents) == sorted(expected)
        elapsed_ms = round((time.perf_counter() - t0) * 1000, 2)
        latencies.append(elapsed_ms)

        rows.append(
            {
                "id": c_id,
                "split": split_name,
                "group": group,
                "text": text,
                "expected": expected,
                "expected_args": expected_args,
                "keyword": kw_intents,
                "keyword_pass": kw_pass,
                "vector_status": vec_status,
                "vector": vec_intents,
                "vector_pass": vec_pass,
                "abstain_reason": vec_abstain_reason,
                "vector_scores": vec_scores,
                "vector_evidence": vec_evidence,
                "llm": llm_intents,
                "llm_pass": llm_pass,
                "policy": pol_intents,
                "policy_pass": pol_pass,
                "policy_path": pol_res.get("policy_path", ""),
                "llm_called": pol_res.get("llm_called", False),
                "is_auto_accepted": pol_res.get("is_auto_accepted", False),
                "args_pass": pol_res.get("args_pass", True),
                "latency_ms": elapsed_ms,
            }
        )

    # 4. 종합 지표 산출
    y_true = [r["expected"] for r in rows]
    method_metrics: dict[str, Any] = {}

    if "keyword" in methods:
        y_kw = [r["keyword"] for r in rows]
        method_metrics["keyword"] = compute_classification_metrics(y_true, y_kw)

    if "vector" in methods:
        y_vec = [r["vector"] for r in rows]
        method_metrics["vector"] = compute_classification_metrics(y_true, y_vec)

    if "llm" in methods and not args.no_llm:
        y_llm = [r["llm"] for r in rows]
        method_metrics["llm"] = compute_classification_metrics(y_true, y_llm)

    policy_metrics = compute_policy_metrics(rows)
    latency_stats = compute_latency_stats(latencies)

    # 5. 결과 파일 저장
    today_str = date.today().isoformat()
    if args.out:
        out_dir = Path(args.out)
    else:
        out_dir = RESULTS_DIR / f"{split_name}_{args.prompt}_{today_str}"
    out_dir.mkdir(parents=True, exist_ok=True)

    summary = {
        "metadata": {
            "date": today_str,
            "split": split_name,
            "total_cases": len(cases),
            "prompt_version": args.prompt,
            "methods": methods,
            "policy_name": args.policy.upper(),
            "vector_model": args.vector_model,
            "top_m": args.top_m,
            "git_sha": get_git_sha(),
        },
        "methods": method_metrics,
        "policy": policy_metrics,
        "latency_ms": latency_stats,
    }

    cases_csv_path = out_dir / "cases.csv"
    summary_json_path = out_dir / "summary.json"
    report_md_path = out_dir / "report.md"

    save_cases_csv(rows, cases_csv_path)
    save_summary_json(summary, summary_json_path)
    save_report_md(summary, rows, report_md_path)

    # 기존 하위 호환성 파일 생성 (ai/results/<prompt>_<날짜>.csv)
    legacy_csv_path = RESULTS_DIR / f"questions_{args.prompt}_{today_str}.csv"
    save_cases_csv(rows, legacy_csv_path)

    # 6. 터미널 요약 출력
    n = len(rows)
    kw_acc = sum(r["keyword_pass"] for r in rows)
    llm_acc = sum(r["llm_pass"] for r in rows)
    pol_acc = sum(r["policy_pass"] for r in rows)

    print(
        f"\n==================== [평가 결과 요약: {split_name}] ===================="
    )
    print(f"- 케이스 수: {n}건 | Git SHA: {summary['metadata']['git_sha'][:7]}")
    if "keyword" in methods:
        print(
            f"- 키워드 (Keyword) : {kw_acc}/{n} ({kw_acc/n*100:.1f}%) [Macro F1: {method_metrics.get('keyword', {}).get('macro_f1', 0):.3f}]"
        )
    if "vector" in methods:
        vec_acc = sum(r["vector_pass"] for r in rows)
        vec_abstained = sum(1 for r in rows if r["vector_status"].startswith("abstained"))
        print(
            f"- 벡터 (Vector Top-{args.top_m}) : {vec_acc}/{n} ({vec_acc/n*100:.1f}%) | 보류(Abstain): {vec_abstained}/{n} [Macro F1: {method_metrics.get('vector', {}).get('macro_f1', 0):.3f}]"
        )
    if "llm" in methods and not args.no_llm:
        print(
            f"- LLM ({args.prompt})      : {llm_acc}/{n} ({llm_acc/n*100:.1f}%) [Macro F1: {method_metrics.get('llm', {}).get('macro_f1', 0):.3f}]"
        )
    print(
        f"- 최종 정책 ({args.policy})  : {pol_acc}/{n} ({pol_acc/n*100:.1f}%) | Coverage: {policy_metrics['coverage']*100:.1f}% | Selective Risk: {policy_metrics['selective_risk']*100:.1f}%"
    )
    print(f"- 결과 저장 위치     : {out_dir.relative_to(ROOT)}")
    print("====================================================================\n")


def main() -> None:
    parser = argparse.ArgumentParser(description="의도 분류 고도화 평가 러너")
    parser.add_argument(
        "--prompt", default="v1", help="LLM 프롬프트 버전 (기본값: v1)"
    )
    parser.add_argument(
        "--split",
        default="questions",
        help="평가할 데이터셋 (questions, questions_v2, validation)",
    )
    parser.add_argument(
        "--methods",
        default="keyword,vector,llm",
        help="평가할 방식들 (쉼표 구분: keyword,vector,llm)",
    )
    parser.add_argument(
        "--policy",
        default="P2",
        choices=["P0", "P1", "P2", "P3", "P4"],
        help="라우팅 정책 (기본값: P2)",
    )
    parser.add_argument(
        "--vector-model",
        default="jhgan/ko-sroberta-multitask",
        help="벡터 임베딩 모델",
    )
    parser.add_argument(
        "--top-m", type=int, default=2, help="의도별 Top-m 개수 (기본값: 2)"
    )
    parser.add_argument(
        "--thresholds",
        default=str(ROOT / "ai" / "vector" / "thresholds.json"),
        help="임계값 설정 파일 경로",
    )
    parser.add_argument(
        "--llm-cache",
        action="store_true",
        default=True,
        help="LLM 캐시 사용 여부 (기본값: True)",
    )
    parser.add_argument(
        "--no-llm", action="store_true", default=False, help="LLM 호출 없이 평가"
    )
    parser.add_argument(
        "--refresh-llm",
        action="store_true",
        default=False,
        help="LLM 캐시 무시하고 강제 재호출",
    )
    parser.add_argument("--out", default=None, help="결과 출력 디렉터리")

    args = parser.parse_args()
    run_evaluation(args)


if __name__ == "__main__":
    main()
