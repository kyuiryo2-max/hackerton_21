"""라우팅 정책 모듈 (policies.py).

[1] 키워드/규칙 -> [2] 벡터 (Top-m) -> [3] LLM 라우팅 체계 (P0 ~ P4).
자동 확정 시 슬롯 충족 여부(args_pass)를 검사하여 서버 응답 스키마 결손을 방지합니다.
"""

from __future__ import annotations

from typing import Any, Callable

from ai.intents import RISK_LEVELS, STATUS_ACCEPTED, validate_slots


def evaluate_policy_p0(keyword_res: dict[str, Any]) -> dict[str, Any]:
    """P0: Keyword only (키워드/규칙 단독)."""
    intents = [i["intent"] for i in keyword_res.get("intents", [])]
    return {
        "policy": intents,
        "policy_path": "keyword",
        "llm_called": False,
        "is_auto_accepted": True,
        "args_pass": not keyword_res.get("needs_confirm", False),
    }


def evaluate_policy_p1(
    text: str, context: dict[str, Any], llm_caller: Callable[[], dict[str, Any]]
) -> dict[str, Any]:
    """P1: LLM only (기존 베이스라인: 무조건 LLM 호출)."""
    out = llm_caller()
    intents = [i["intent"] for i in out.get("intents", [])]
    return {
        "policy": intents,
        "policy_path": "llm",
        "llm_called": True,
        "is_auto_accepted": False,
        "args_pass": not out.get("needs_confirm", False),
    }


def evaluate_policy_p2(
    text: str,
    context: dict[str, Any],
    keyword_res: dict[str, Any],
    vector_res: dict[str, Any],
    llm_caller: Callable[[], dict[str, Any]],
) -> dict[str, Any]:
    """P2: 키워드(고정밀) -> 벡터(Top-m) -> LLM.

    1. 키워드가 명확하고 슬롯이 충족되면 즉시 확정.
    2. 아니면 벡터가 accepted 이고 슬롯 규칙이 통과하면 확정.
    3. 벡터가 보류(abstained)되거나 슬롯 미충족이면 LLM 호출.
    """
    kw_intents = [
        i["intent"] for i in keyword_res.get("intents", []) if i["intent"] != "unsupported"
    ]
    kw_slots_ok = not keyword_res.get("needs_confirm", False)

    # 1. 키워드 우선 확정 (고정밀 단일 의도)
    if kw_intents and kw_slots_ok and len(kw_intents) == 1:
        return {
            "policy": kw_intents,
            "policy_path": "keyword",
            "llm_called": False,
            "is_auto_accepted": True,
            "args_pass": True,
        }

    # 2. 벡터 Top-m 확정 시도
    if vector_res.get("status") == STATUS_ACCEPTED:
        vec_intents = [i["intent"] for i in vector_res.get("intents", [])]
        # 슬롯 규칙 충족 여부 검사
        slots_all_ok = True
        for intent in vec_intents:
            # 키워드 결과에서 슬롯을 가져오거나, 텍스트에서 직접 추출
            slots = {}
            for ki in keyword_res.get("intents", []):
                if ki.get("intent") == intent:
                    slots = ki
                    break
            if not slots:
                from ai.intents import extract_slots

                slots = extract_slots(intent, text)

            if not validate_slots(intent, slots):
                slots_all_ok = False
                break

        if slots_all_ok:
            return {
                "policy": vec_intents,
                "policy_path": "vector",
                "llm_called": False,
                "is_auto_accepted": True,
                "args_pass": True,
            }

    # 3. LLM 폴백
    out = llm_caller()
    intents = [i["intent"] for i in out.get("intents", [])]
    return {
        "policy": intents,
        "policy_path": "llm",
        "llm_called": True,
        "is_auto_accepted": False,
        "args_pass": not out.get("needs_confirm", False),
    }


def evaluate_policy_p3(
    text: str,
    context: dict[str, Any],
    keyword_res: dict[str, Any],
    vector_res: dict[str, Any],
    llm_caller: Callable[[], dict[str, Any]],
) -> dict[str, Any]:
    """P3: 키워드·벡터 일치 시 확정, 충돌 또는 보류 시 LLM."""
    kw_intents = sorted(
        [i["intent"] for i in keyword_res.get("intents", []) if i["intent"] != "unsupported"]
    )
    vec_intents = sorted([i["intent"] for i in vector_res.get("intents", [])])

    if vector_res.get("status") == STATUS_ACCEPTED and kw_intents == vec_intents and kw_intents:
        return {
            "policy": vec_intents,
            "policy_path": "consensus",
            "llm_called": False,
            "is_auto_accepted": True,
            "args_pass": not keyword_res.get("needs_confirm", False),
        }

    out = llm_caller()
    intents = [i["intent"] for i in out.get("intents", [])]
    return {
        "policy": intents,
        "policy_path": "llm",
        "llm_called": True,
        "is_auto_accepted": False,
        "args_pass": not out.get("needs_confirm", False),
    }


def evaluate_policy_p4(
    text: str,
    context: dict[str, Any],
    keyword_res: dict[str, Any],
    vector_res: dict[str, Any],
    llm_caller: Callable[[], dict[str, Any]],
) -> dict[str, Any]:
    """P4: P2 기반 + 고위험 의도(change_todo, change_route)는 반드시 LLM 검증."""
    res = evaluate_policy_p2(text, context, keyword_res, vector_res, llm_caller)
    # 고위험 의도가 포함되어 있고 자동 확정된 경우 LLM 검증 강제
    if res["is_auto_accepted"]:
        has_high_risk = any(RISK_LEVELS.get(it) == "high" for it in res["policy"])
        if has_high_risk:
            out = llm_caller()
            intents = [i["intent"] for i in out.get("intents", [])]
            return {
                "policy": intents,
                "policy_path": "high_risk_llm",
                "llm_called": True,
                "is_auto_accepted": False,
                "args_pass": not out.get("needs_confirm", False),
            }
    return res
