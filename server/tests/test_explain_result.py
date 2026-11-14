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
    assert "2026" not in sent["user"] and "8시 52분" in sent["user"] and "9시 7분" in sent["user"]


@pytest.mark.parametrize(
    "intents, results, ok",
    [
        # 11/12부터 모든 질문 종류에 AI 문장을 써요 (내용은 _ai_content_ok가 검사)
        ([{"intent": "next_vehicle"}], {"intent": "next_vehicle", "minutes": 12}, True),
        ([{"intent": "stopover_check"}], {"intent": "stopover_check", "feasible": True}, True),
        ([{"intent": "time_left"}], {"intent": "time_left", "minutes": 8}, True),
        ([{"intent": "change_todo"}], {"intent": "change_todo", "todo_id": 3}, True),
        ([{"intent": "change_route"}], {"intent": "change_route", "route": "2115"}, True),
        ([{"intent": "place_info"}], {"intent": "place_info", "place": None}, True),
        ([{"intent": "running_late"}], {"intent": "running_late", "on_time": False}, True),
        ([{"intent": "unsupported"}], {"intent": "unsupported"}, True),
        # 질문 두 개도 결과 목록을 함께 줘요
        ([{"intent": "running_late"}, {"intent": "next_vehicle"}],
         [{"intent": "running_late"}, {"intent": "next_vehicle", "minutes": 3}], True),
        # 계산을 못 한 안내는 정해진 문장 그대로
        ([{"intent": "next_vehicle"}], {"intent": "next_vehicle", "available": False}, False),
        ([{"intent": "next_vehicle"}], {"intent": "next_vehicle", "minutes": None}, False),
        ([{"intent": "change_todo"}], {"intent": "change_todo", "todo_id": None}, False),
    ],
)
def test_AI_문장을_쓰는_경우(intents, results, ok):
    assert assistant._ai_sentence_ok(intents, results) is ok


@pytest.mark.parametrize(
    "answer, results, ok",
    [
        ("CU에 들러도 괜찮아요.", [{"intent": "stopover_check", "feasible": True}], True),
        # "부족해요" 경고를 빼먹으면 안 돼요 (11/11 측정에서 발견한 오류)
        ("다이소에 들르실 수 있어요.", [{"intent": "stopover_check", "feasible": False}], False),
        ("지금 들르기엔 시간이 부족해요.", [{"intent": "stopover_check", "feasible": False}], True),
        ("15분 늦으셔도 9시 9분에 도착하실 수 있습니다.", [{"intent": "running_late", "on_time": False}], False),
        ("10분 늦으면 9시 9분에 도착해서 늦어요.", [{"intent": "running_late", "on_time": False}], True),
        ("근처에서 꽃집을 찾지 못했어요.", [{"intent": "place_info", "place": None}], True),
        ("근처에 꽃집이 있어요.", [{"intent": "place_info", "place": None}], False),
        # 하지 않은 일을 말하면 안 돼요 (11/11 "커피 구매 일정을 삭제했습니다")
        ("커피 구매 일정을 삭제했습니다. 다음 버스는 12분 뒤예요.", [{"intent": "next_vehicle", "minutes": 12}], False),
        ("경로를 6호선으로 변경했어요.", [{"intent": "change_route"}], False),
        # 할 일 변경은 실제로 한 일이라 괜찮아요
        ("커피 사기는 이번 이동에서 뺄게요.", [{"intent": "change_todo", "todo_id": 3}], True),
        ("가" * 201, [{"intent": "unsupported"}], False),
    ],
)
def test_AI_문장_내용_검사(answer, results, ok):
    assert assistant._ai_content_ok(answer, results) is ok


def test_내용_검사에_걸리면_기본_답변(monkeypatch):
    monkeypatch.setattr(llm, "_chat_json", lambda s, u: {"answer": "다이소에 들르실 수 있어요."})
    result = {"intent": "stopover_check", "feasible": False, "place": {"name": "다이소"}}
    base = "시간이 부족해요. 도착한 뒤에 들르는 걸 추천해요."
    answer = llm.explain_result("다이소 들러도 돼?", result, base,
                                check=lambda a: assistant._ai_content_ok(a, [result]))
    assert answer == base


def test_AI에게_기본_답변을_초안으로_보냄(monkeypatch):
    sent = {}

    def fake_chat(system, user):
        sent["user"] = user
        return {"answer": "알겠어요, 커피 사기는 이번엔 뺄게요."}
    monkeypatch.setattr(llm, "_chat_json", fake_chat)
    llm.explain_result("커피는 빼 줘", {"intent": "change_todo", "todo_id": 3, "action": "delete"},
                       "커피 사기는 이번엔 뺄게요.")
    assert '"draft": "커피 사기는 이번엔 뺄게요."' in sent["user"]


def _ai_on(tmp_path, monkeypatch, intents):
    from app import config
    from app.db import database

    monkeypatch.setattr(config, "DATABASE_PATH", str(tmp_path / "test.db"))
    database.init_db()
    database.seed_demo_data()
    monkeypatch.setattr(assistant, "_ai_ready", lambda: True)
    monkeypatch.setattr(assistant, "_classify", lambda text, history, context=None: {
        "type": "question", "intents": intents, "needs_confirm": False, "question": None, "engine": "ai"})


def test_할_일_변경도_AI_문장(tmp_path, monkeypatch):
    _ai_on(tmp_path, monkeypatch, [{"intent": "change_todo", "todo_text": "커피", "action": "delete",
                                    "place_types": [], "delay_minutes": None}])
    monkeypatch.setattr(llm, "_chat_json", lambda s, u: {"answer": "알겠어요, 커피 사기는 이번엔 뺄게요."})
    r = assistant.ask("demo", "커피는 안 사도 돼", use_demo=True, explain_with_ai=True)
    assert r["answer"] == "알겠어요, 커피 사기는 이번엔 뺄게요."


def test_범위_밖_질문도_AI_문장(tmp_path, monkeypatch):
    _ai_on(tmp_path, monkeypatch, [{"intent": "unsupported", "place_types": [], "delay_minutes": None}])
    monkeypatch.setattr(llm, "_chat_json", lambda s, u: {
        "answer": "점심 메뉴는 골라 드리기 어려워요. 대신 가는 길에 식당에 들를 시간이 있는지는 알려 드릴 수 있어요."})
    r = assistant.ask("demo", "점심 뭐 먹지?", use_demo=True, explain_with_ai=True)
    assert r["answer"].startswith("점심 메뉴는")


def test_질문_두_개면_결과_목록을_함께_보냄(tmp_path, monkeypatch):
    _ai_on(tmp_path, monkeypatch, [
        {"intent": "running_late", "delay_minutes": 10, "place_types": []},
        {"intent": "next_vehicle", "place_types": [], "delay_minutes": None},
    ])
    sent = {}

    def fake_chat(system, user):
        sent["user"] = user
        return {"answer": "x"}
    monkeypatch.setattr(llm, "_chat_json", fake_chat)
    assistant.ask("demo", "10분 늦을 것 같은데 다음 버스는?", use_demo=True, explain_with_ai=True)
    assert '"result": [' in sent["user"]
