"""평가 보고서 생성 모듈 (report.py).

- cases.csv: 케이스별 정밀 평가 로그
- summary.json: 지표, 신뢰구간(CI), 설정 해시, 혼동행렬 요약
- report.md: 사람이 읽기 편한 Markdown 리포트
"""

from __future__ import annotations

import csv
import json
from pathlib import Path
from typing import Any


def save_cases_csv(rows: list[dict[str, Any]], out_path: Path | str) -> None:
    """케이스별 평가 결과 CSV를 저장합니다."""
    path = Path(out_path)
    path.parent.mkdir(parents=True, exist_ok=True)

    fieldnames = [
        "id",
        "split",
        "group",
        "text",
        "expected",
        "expected_args",
        "keyword",
        "keyword_pass",
        "vector_status",
        "vector",
        "vector_pass",
        "abstain_reason",
        "vector_scores",
        "vector_evidence",
        "llm",
        "llm_pass",
        "policy",
        "policy_pass",
        "policy_path",
        "llm_called",
        "args_pass",
        "latency_ms",
    ]

    with open(path, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        for r in rows:
            # 리스트나 딕셔너리 필드는 문자열/JSON으로 포맷팅
            row_copy = dict(r)
            for k in ["expected", "keyword", "vector", "llm", "policy"]:
                if isinstance(row_copy.get(k), list):
                    row_copy[k] = "|".join(row_copy[k])
            for k in ["vector_scores", "vector_evidence"]:
                if isinstance(row_copy.get(k), (dict, list)):
                    row_copy[k] = json.dumps(row_copy[k], ensure_ascii=False)
            writer.writerow(row_copy)


def save_summary_json(summary: dict[str, Any], out_path: Path | str) -> None:
    """종합 평가 결과 JSON을 저장합니다."""
    path = Path(out_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=2)


def generate_markdown_report(summary: dict[str, Any], rows: list[dict[str, Any]]) -> str:
    """Markdown 종합 보고서를 생성합니다."""
    meta = summary.get("metadata", {})
    methods = summary.get("methods", {})
    policy = summary.get("policy", {})

    lines: list[str] = [
        "# 의도 분류 고도화 평가 보고서",
        "",
        f"- **평가 일시**: {meta.get('date', '')}",
        f"- **데이터셋 Split**: `{meta.get('split', '')}` ({meta.get('total_cases', 0)}건)",
        f"- **Git SHA**: `{meta.get('git_sha', '')[:7]}`",
        f"- **벡터 모델**: `{meta.get('vector_model', '')}` (m={meta.get('top_m', 2)})",
        f"- **채택 정책**: `{meta.get('policy_name', 'P2')}`",
        "",
        "## 1. 컴포넌트별 분류 성능 비교 (Exact Match & Macro F1)",
        "",
        "| 방식 (Method) | Exact Match | 95% Wilson CI | Macro Precision | Macro Recall | Macro F1 |",
        "|---|---|---|---|---|---|",
    ]

    for m_name, m_stats in methods.items():
        em = m_stats.get("exact_match", 0.0)
        ci = m_stats.get("exact_match_ci", (0.0, 0.0))
        mp = m_stats.get("macro_precision", 0.0)
        mr = m_stats.get("macro_recall", 0.0)
        mf1 = m_stats.get("macro_f1", 0.0)
        lines.append(
            f"| **{m_name}** | {em * 100:.1f}% | [{ci[0]*100:.1f}%, {ci[1]*100:.1f}%] | {mp:.3f} | {mr:.3f} | {mf1:.3f} |"
        )

    lines.extend(
        [
            "",
            "## 2. 정책 라우팅 및 LLM 절감 지표",
            "",
            "| 지표 (Metric) | 수치 | 95% Wilson CI | 설명 |",
            "|---|---|---|---|",
            f"| **Coverage (자동 확정률)** | {policy.get('coverage', 0.0)*100:.1f}% | [{policy.get('coverage_ci', (0,0))[0]*100:.1f}%, {policy.get('coverage_ci', (0,0))[1]*100:.1f}%] | LLM 호출 없이 규칙/벡터로 즉시 처리한 비율 |",
            f"| **Selective Risk (확정 오답률)** | {policy.get('selective_risk', 0.0)*100:.1f}% | [{policy.get('selective_risk_ci', (0,0))[0]*100:.1f}%, {policy.get('selective_risk_ci', (0,0))[1]*100:.1f}%] | 자동 확정한 것 중 오답 비율 (품질 위험도) |",
            f"| **Fallback Rate (LLM 호출률)** | {policy.get('fallback_rate', 0.0)*100:.1f}% | - | 보류되어 LLM으로 위임된 비율 (1 - Coverage) |",
            f"| **Unsupported Recall** | {policy.get('unsupported_recall', 0.0)*100:.1f}% | [{policy.get('unsupported_recall_ci', (0,0))[0]*100:.1f}%, {policy.get('unsupported_recall_ci', (0,0))[1]*100:.1f}%] | 비지원 질문을 성공적으로 거절한 비율 |",
            f"| **Overall Accuracy** | {policy.get('overall_accuracy', 0.0)*100:.1f}% | [{policy.get('overall_accuracy_ci', (0,0))[0]*100:.1f}%, {policy.get('overall_accuracy_ci', (0,0))[1]*100:.1f}%] | 시스템 전체 최종 의도 일치율 |",
            "",
            "## 3. 주요 오분류 및 불일치 사례 분석 (Top Errors)",
            "",
            "| ID | 질문 텍스트 | 기대 의도 | 키워드 | 벡터 (상태) | LLM | 최종 정책 | 통과 여부 |",
            "|---|---|---|---|---|---|---|---|",
        ]
    )

    errors = [r for r in rows if not r.get("policy_pass", False)]
    for r in errors[:10]:
        v_str = f"{'|'.join(r.get('vector', []))} ({r.get('vector_status', '')})"
        lines.append(
            f"| `{r.get('id')}` | {r.get('text')} | `{r.get('expected')}` | `{r.get('keyword')}` | {v_str} | `{r.get('llm')}` | `{r.get('policy')}` | ❌ |"
        )

    if not errors:
        lines.append("| - | 없음 (모든 케이스 통과) | - | - | - | - | - | ✅ |")

    lines.append("")
    return "\n".join(lines)


def save_report_md(summary: dict[str, Any], rows: list[dict[str, Any]], out_path: Path | str) -> None:
    """Markdown 보고서를 파일로 저장합니다."""
    path = Path(out_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    content = generate_markdown_report(summary, rows)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
