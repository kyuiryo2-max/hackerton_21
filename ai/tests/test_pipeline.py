"""새로 구축된 의도 분류 파이프라인(Phase 0~2) 유닛 테스트.
"""

from __future__ import annotations

import pytest

from ai.eval.metrics import (
    compute_classification_metrics,
    compute_policy_metrics,
    wilson_score_interval,
)
from ai.eval.policies import evaluate_policy_p2
from ai.intents import extract_slots, validate_slots
from ai.normalize import is_short_reference, normalize_v1
from ai.vector.classifier import VectorIntentClassifier


def test_normalize_v1():
    # 1. 공백 축소 및 소문자화
    assert normalize_v1("  다음   버스  언제   와?  ") == "다음 버스 언제 와?"
    assert normalize_v1("ATM 어디?") == "atm 어디?"


def test_is_short_reference():
    # 2. 문맥 필요 단문/지시어 판별
    assert is_short_reference("거기 가") is True
    assert is_short_reference("취소") is True
    assert is_short_reference("다음 버스 언제 도착해?") is False


def test_slot_extraction_and_validation():
    # 3. 슬롯 추출 및 유효성 검증
    slots_stopover = extract_slots("stopover_check", "편의점 들렀다 가도 돼?")
    assert "편의점" in slots_stopover.get("place_types", [])
    assert validate_slots("stopover_check", slots_stopover) is True

    slots_late = extract_slots("running_late", "10분 늦을 것 같아")
    assert slots_late.get("delay_minutes") == 10
    assert validate_slots("running_late", slots_late) is True


def test_vector_classifier_basic():
    # 4. 벡터 분류기 동작 테스트
    clf = VectorIntentClassifier()

    # 명확한 의도 -> accepted
    res_bus = clf.classify("다음 버스 언제 와?")
    assert res_bus["status"] == "accepted"
    intents = [i["intent"] for i in res_bus["intents"]]
    assert "next_vehicle" in intents
    assert res_bus["top_similarity"] > 0.5

    # 비지원 질문 -> abstained (저점수 보류)
    res_weather = clf.classify("오늘 날씨 어때?")
    assert res_weather["status"].startswith("abstained")
    assert len(res_weather["intents"]) == 0

    # 지시어 단문 -> abstained:needs_context
    res_context = clf.classify("거기 가")
    assert res_context["status"] == "abstained:needs_context"


def test_metrics_computation():
    # 5. Wilson Score 및 분류 지표 테스트
    low, high = wilson_score_interval(10, 10)
    assert low > 0.65 and high == 1.0

    y_true = [["next_vehicle"], ["stopover_check"]]
    y_pred = [["next_vehicle"], ["stopover_check"]]
    m = compute_classification_metrics(y_true, y_pred)
    assert m["exact_match"] == 1.0
    assert m["macro_f1"] == 1.0


def test_policy_p2_routing():
    # 6. P2 정책 라우팅 테스트 (키워드/벡터 -> LLM)
    kw_res = {
        "intents": [{"intent": "next_vehicle"}],
        "needs_confirm": False,
    }
    vec_res = {
        "status": "accepted",
        "intents": [{"intent": "next_vehicle", "score": 0.85}],
    }

    # 키워드 확정
    pol = evaluate_policy_p2(
        "다음 버스 언제 와?", {}, kw_res, vec_res, lambda: {"intents": []}
    )
    assert pol["is_auto_accepted"] is True
    assert pol["policy"] == ["next_vehicle"]
    assert pol["llm_called"] is False
