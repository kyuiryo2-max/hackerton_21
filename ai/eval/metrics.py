"""평가 지표 계산 모듈 (metrics.py).

- Wilson Score Confidence Interval (95% CI)
- Component 지표: Exact Match, Multi-label Macro/Micro P/R/F1, 의도별 혼동행렬
- Policy 지표: Coverage, Selective Risk, Fallback Rate, Unsupported Recall
- 레이턴시 통계: p50, p90, p95, mean
"""

from __future__ import annotations

import math
from typing import Any

from ai.intents import LABELS


def wilson_score_interval(successes: int, total: int, confidence: float = 0.95) -> tuple[float, float]:
    """Wilson Score 신뢰구간(CI)을 계산합니다.

    표본 수가 적을 때도(예: 10~25건) 정규근사보다 정확하고 안정적인 신뢰구간을 제공합니다.
    """
    if total <= 0:
        return 0.0, 0.0
    # 95% 신뢰수준 z-값 ~ 1.95996
    z = 1.95996 if confidence == 0.95 else 1.64485
    p = successes / total
    denominator = 1.0 + (z**2) / total
    center = (p + (z**2) / (2.0 * total)) / denominator
    spread = z * math.sqrt((p * (1.0 - p) + (z**2) / (4.0 * total)) / total) / denominator

    lower = max(0.0, center - spread)
    upper = min(1.0, center + spread)
    return round(lower, 4), round(upper, 4)


def compute_classification_metrics(
    y_true: list[list[str]],
    y_pred: list[list[str]],
    target_labels: list[str] | None = None,
) -> dict[str, Any]:
    """멀티라벨 분류 성능(Exact Match, Macro/Micro P/R/F1)을 계산합니다."""
    labels = target_labels or LABELS
    total = len(y_true)
    if total == 0:
        return {}

    # 1. Exact Match (완전 일치율)
    exact_matches = sum(1 for yt, yp in zip(y_true, y_pred) if set(yt) == set(yp))
    em_rate = exact_matches / total
    em_ci = wilson_score_interval(exact_matches, total)

    # 2. 의도별 TP, FP, FN, TN
    per_class: dict[str, dict[str, Any]] = {}
    total_tp = 0
    total_fp = 0
    total_fn = 0

    for c in labels:
        tp = sum(1 for yt, yp in zip(y_true, y_pred) if c in yt and c in yp)
        fp = sum(1 for yt, yp in zip(y_true, y_pred) if c not in yt and c in yp)
        fn = sum(1 for yt, yp in zip(y_true, y_pred) if c in yt and c not in yp)
        tn = sum(1 for yt, yp in zip(y_true, y_pred) if c not in yt and c not in yp)

        p = tp / (tp + fp) if (tp + fp) > 0 else 0.0
        r = tp / (tp + fn) if (tp + fn) > 0 else 0.0
        f1 = (2 * p * r) / (p + r) if (p + r) > 0 else 0.0

        p_ci = wilson_score_interval(tp, tp + fp) if (tp + fp) > 0 else (0.0, 0.0)
        r_ci = wilson_score_interval(tp, tp + fn) if (tp + fn) > 0 else (0.0, 0.0)

        per_class[c] = {
            "support": tp + fn,
            "tp": tp,
            "fp": fp,
            "fn": fn,
            "tn": tn,
            "precision": round(p, 4),
            "precision_ci": p_ci,
            "recall": round(r, 4),
            "recall_ci": r_ci,
            "f1": round(f1, 4),
        }

        total_tp += tp
        total_fp += fp
        total_fn += fn

    # 3. Macro 평균
    active_classes = [c for c in labels if per_class[c]["support"] > 0 or per_class[c]["fp"] > 0]
    n_act = len(active_classes) or 1
    macro_p = sum(per_class[c]["precision"] for c in active_classes) / n_act
    macro_r = sum(per_class[c]["recall"] for c in active_classes) / n_act
    macro_f1 = (2 * macro_p * macro_r) / (macro_p + macro_r) if (macro_p + macro_r) > 0 else 0.0

    # 4. Micro 평균
    micro_p = total_tp / (total_tp + total_fp) if (total_tp + total_fp) > 0 else 0.0
    micro_r = total_tp / (total_tp + total_fn) if (total_tp + total_fn) > 0 else 0.0
    micro_f1 = (2 * micro_p * micro_r) / (micro_p + micro_r) if (micro_p + micro_r) > 0 else 0.0

    return {
        "total_cases": total,
        "exact_match": round(em_rate, 4),
        "exact_match_ci": em_ci,
        "macro_precision": round(macro_p, 4),
        "macro_recall": round(macro_r, 4),
        "macro_f1": round(macro_f1, 4),
        "micro_precision": round(micro_p, 4),
        "micro_recall": round(micro_r, 4),
        "micro_f1": round(micro_f1, 4),
        "per_class": per_class,
    }


def compute_policy_metrics(cases: list[dict[str, Any]]) -> dict[str, Any]:
    """라우팅 정책 평가 지표 (Coverage, Selective Risk, Fallback Rate, Unsupported Recall).

    각 case 딕셔너리 예상 키:
    - expected: list[str]
    - policy: list[str]
    - policy_pass: bool
    - llm_called: bool
    - is_auto_accepted: bool
    """
    total = len(cases)
    if total == 0:
        return {}

    auto_accepted = [c for c in cases if c.get("is_auto_accepted", not c.get("llm_called", True))]
    n_auto = len(auto_accepted)

    # Coverage: 자동 확정 건수 / 전체
    coverage = n_auto / total
    coverage_ci = wilson_score_interval(n_auto, total)

    # Selective Risk: 자동 확정 중 오답 건수 / 자동 확정 건수
    errors_in_auto = sum(1 for c in auto_accepted if not c.get("policy_pass", False))
    selective_risk = (errors_in_auto / n_auto) if n_auto > 0 else 0.0
    risk_ci = wilson_score_interval(errors_in_auto, n_auto) if n_auto > 0 else (0.0, 0.0)

    # Fallback Rate: LLM 호출률 (1 - Coverage)
    fallback_rate = 1.0 - coverage

    # Unsupported Recall: 비지원 질문 중 시스템이 실제로 비지원/거절로 종결한 비율
    unsupported_cases = [c for c in cases if "unsupported" in c.get("expected", [])]
    n_unsupp = len(unsupported_cases)
    if n_unsupp > 0:
        correct_rejected = sum(
            1 for c in unsupported_cases if "unsupported" in c.get("policy", []) or c.get("abstain_reason") is not None
        )
        unsupp_recall = correct_rejected / n_unsupp
        unsupp_recall_ci = wilson_score_interval(correct_rejected, n_unsupp)
    else:
        unsupp_recall = 1.0
        unsupp_recall_ci = (1.0, 1.0)

    # Overall Accuracy (전체 정답률)
    total_passed = sum(1 for c in cases if c.get("policy_pass", False))
    overall_acc = total_passed / total
    overall_acc_ci = wilson_score_interval(total_passed, total)

    return {
        "total_cases": total,
        "auto_accepted_count": n_auto,
        "coverage": round(coverage, 4),
        "coverage_ci": coverage_ci,
        "selective_risk": round(selective_risk, 4),
        "selective_risk_ci": risk_ci,
        "fallback_rate": round(fallback_rate, 4),
        "overall_accuracy": round(overall_acc, 4),
        "overall_accuracy_ci": overall_acc_ci,
        "unsupported_cases": n_unsupp,
        "unsupported_recall": round(unsupp_recall, 4),
        "unsupported_recall_ci": unsupp_recall_ci,
    }


def compute_latency_stats(latencies_ms: list[float]) -> dict[str, float]:
    """레이턴시 분포 통계(p50, p90, p95, p99, mean)를 계산합니다."""
    if not latencies_ms:
        return {"p50": 0.0, "p90": 0.0, "p95": 0.0, "p99": 0.0, "mean": 0.0}

    s = sorted(latencies_ms)
    n = len(s)

    def percentile(p: float) -> float:
        idx = int(math.ceil((p / 100.0) * n)) - 1
        return round(s[max(0, min(idx, n - 1))], 2)

    return {
        "p50": percentile(50),
        "p90": percentile(90),
        "p95": percentile(95),
        "p99": percentile(99),
        "mean": round(sum(s) / n, 2),
    }
