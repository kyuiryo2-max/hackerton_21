"""#37: AI 답변 문장 생성 및 숫자 대조(numbers_match) 안전망 테스트.
"""

import pytest

from app.services import assistant, llm


def test_extract_allowed_numbers():
    result = {
        "intent": "next_vehicle",
        "route": "2115",
        "minutes": 12,
        "next_minutes": 20,
    }
    base = "2115번이 12분 뒤에 와요. 그다음 차는 20분 뒤예요."
    allowed = llm.extract_allowed_numbers(result, base)

    assert 2115 in allowed
    assert 12 in allowed
    assert 20 in allowed
    assert 5 not in allowed


def test_numbers_match():
    allowed = {2115, 12, 20}

    # 1. 일치하는 숫자들
    assert llm.numbers_match("2115번 버스가 12분 뒤에 오고, 다음 차는 20분 뒤입니다.", allowed) is True
    # 2. 숫자가 아예 없는 문장도 허용
    assert llm.numbers_match("잠시 후 버스가 도착합니다.", allowed) is True
    # 3. 계산 결과에 없는 숫자를 지어낸 경우 (환각)
    assert llm.numbers_match("2115번 버스가 5분 뒤에 도착합니다.", allowed) is False
    assert llm.numbers_match("약 15분 정도 소요됩니다.", allowed) is False


def test_explain_result_fallback_on_hallucination(monkeypatch):
    """AI가 계산에 없는 숫자를 지어내면(환각), 안전하게 기본 템플릿 문장으로 폴백."""
    result = {
        "intent": "stopover_check",
        "feasible": True,
        "place": {"name": "CU 안암센트럴점"},
        "max_stay_min": 6,
    }
    base = "CU 안암센트럴점에 들를 수 있어요. 최대 6분 있을 수 있어요."

    # 가짜 AI: 6분이 아니라 15분이라고 환각 답변 생성
    def fake_chat(system, user):
        return {"answer": "CU 안암센트럴점에 들르시면 최대 15분 동안 머무를 수 있습니다."}

    monkeypatch.setattr(llm, "_chat_json", fake_chat)
    ans = llm.explain_result("편의점 들렀다 가도 돼?", result, base)

    # 환각이 감지되어 기본 템플릿 문장으로 안전 폴백되어야 함
    assert ans == base


def test_explain_result_accepted_when_numbers_valid(monkeypatch):
    """AI가 허용된 숫자만 사용하여 자연스러운 문장을 만들면 채택."""
    result = {
        "intent": "next_vehicle",
        "route": "2115",
        "minutes": 12,
        "next_minutes": 20,
    }
    base = "2115번이 12분 뒤에 와요. 그다음 차는 20분 뒤예요."

    # 가짜 AI: 허용된 숫자 2115, 12, 20만 사용
    def fake_chat(system, user):
        return {"answer": "2115번 버스가 약 12분 뒤에 도착하고, 다음 차는 20분 뒤에 올 예정이에요."}

    monkeypatch.setattr(llm, "_chat_json", fake_chat)
    ans = llm.explain_result("다음 버스 언제야?", result, base)

    assert ans == "2115번 버스가 약 12분 뒤에 도착하고, 다음 차는 20분 뒤에 올 예정이에요."


def test_live_explain_result_with_llm():
    """실제 OpenRouter LLM(google/gemma-4-31b-it)을 호출하여 숫자 대조 통과 여부 검증."""
    result = {
        "intent": "next_vehicle",
        "route": "2115",
        "minutes": 12,
        "next_minutes": 20,
    }
    base = "2115번이 12분 뒤에 와요. 그다음 차는 20분 뒤예요."

    ai_answer = llm.explain_result("다음 버스 언제 와?", result, base)
    assert isinstance(ai_answer, str)
    assert len(ai_answer) > 0

    allowed = llm.extract_allowed_numbers(result, base)
    # 실제 LLM이 생성한 문장 속 숫자가 모두 allowed 에 있어야 함
    assert llm.numbers_match(ai_answer, allowed) is True


def test_시각은_시와_분만_허용():
    """시각 문자열의 연·월·일·초는 답변에 쓰면 안 돼요 (11분, 17분 같은 지어낸 숫자를 막기 위해)."""
    result = {
        "intent": "running_late",
        "delay_minutes": None,
        "missed": True,
        "board_at": "2026-11-21T08:52:00+09:00",
        "arrive_at": "2026-11-21T09:07:17+09:00",
    }
    base = "지금 차를 놓쳤다면 8시 52분 차를 타고 9시 7분에 도착해요."
    allowed = llm.extract_allowed_numbers(result, base)

    assert {8, 52, 9, 7} <= allowed
    assert not {2026, 11, 21, 17} & allowed
    assert llm.numbers_match("8시 52분 버스를 타면 9시 7분에 도착해요.", allowed) is True
    assert llm.numbers_match("다음 버스는 17분 뒤에 와요.", allowed) is False
    assert llm.numbers_match("11분 늦게 도착해요.", allowed) is False


def test_오후_시각은_12시간제도_허용():
    allowed = llm.extract_allowed_numbers({"arrive_at": "2026-11-21T13:05:00+09:00"})
    assert {13, 1, 5} <= allowed


def test_AI에게는_시와_분만_보냄(monkeypatch):
    """AI가 날짜나 초를 문장에 쓰지 않도록, 보내는 계산 결과에서 시각을 08:52 모양으로 줄여요."""
    sent = {}

    def fake_chat(system, user):
        sent["user"] = user
        return {"answer": "8시 52분 차를 타면 9시 7분에 도착해요."}

    monkeypatch.setattr(llm, "_chat_json", fake_chat)
    result = {"intent": "running_late", "board_at": "2026-11-21T08:52:00+09:00", "arrive_at": "2026-11-21T09:07:17+09:00"}
    answer = llm.explain_result("버스 하나 놓쳤어", result, "지금 차를 놓쳤다면 8시 52분 차를 타고 9시 7분에 도착해요.")

    assert answer == "8시 52분 차를 타면 9시 7분에 도착해요."
    assert "2026" not in sent["user"] and "08:52" in sent["user"] and "09:07" in sent["user"]
