"""LLM 호출 없이 확인할 수 있는 것만 테스트해요."""
import json

from app.services import llm
from app.services.llm import load_prompt, normalize_question, numbers_match, place_types


def test_답변_숫자가_계산과_같으면_통과():
    answer = "버스까지 12분 남았어요. 약국에서 최대 4분 있을 수 있고, 8시 23분까지 돌아오면 돼요."
    assert numbers_match(answer, allowed={12, 4, 8, 23})


def test_계산에_없는_숫자는_잡아냄():
    assert not numbers_match("약국에서 최대 6분 있을 수 있어요.", allowed={12, 4, 8, 23})


def test_프롬프트에_장소_목록이_들어감():
    assert "약국" in place_types()
    for name in ("todo_to_place", "question_intent"):
        text = load_prompt(name)
        assert "{{PLACE_TYPES}}" not in text
        assert "약국" in text


# ---------- 질문 되묻기 (#12 회의 5번) ----------
def test_분명한_질문은_되묻지_않음():
    out = normalize_question({"type": "question", "intents": [
        {"intent": "stopover_check", "place_types": ["약국"], "delay_minutes": None}]})
    assert out["needs_confirm"] is False
    assert out["question"] is None
    assert out["intents"][0]["place_types"] == ["약국"]


def test_AI가_되물으면_문장을_그대로():
    out = normalize_question({"intents": [{"intent": "stopover_check", "place_types": []}],
                              "needs_confirm": True, "question": "어디를 들르고 싶어요?"})
    assert (out["needs_confirm"], out["question"]) == (True, "어디를 들르고 싶어요?")


def test_목록에_없는_장소는_버리고_되묻기():
    out = normalize_question({"intents": [{"intent": "place_info", "place_types": ["우주정거장"]}]})
    assert out["intents"][0]["place_types"] == []
    assert out["needs_confirm"] is True
    assert out["question"] == llm.DEFAULT_CONFIRM_QUESTION


def test_없는_질문_종류나_빈_결과는_되묻기():
    assert normalize_question({"intents": [{"intent": "weather"}]})["needs_confirm"] is True
    assert normalize_question({})["needs_confirm"] is True


def test_되묻지_않으면_question은_null():
    out = normalize_question({"intents": [{"intent": "time_left"}], "needs_confirm": False, "question": "?"})
    assert out["question"] is None


def test_최근_대화를_AI에_함께_보냄(monkeypatch):
    sent = {}

    def fake_chat(system, user):
        sent["user"] = json.loads(user)
        return {"intents": [{"intent": "stopover_check", "place_types": ["약국"]}]}

    monkeypatch.setattr(llm, "_chat_json", fake_chat)
    history = [{"role": "user", "text": "근처 약국 어디야?"}, {"role": "assistant", "text": "대학약국이 있어요."}]
    out = llm.classify_question("거기 들러도 돼?", context={}, history=history)
    assert sent["user"]["recent_messages"] == history
    assert out["needs_confirm"] is False


def test_질문_프롬프트에_되묻기_규칙():
    text = load_prompt("question_intent")
    assert "needs_confirm" in text and "recent_messages" in text


def test_응답에_설명이_섞여도_JSON만_꺼냄():
    out = llm._parse_json_safe('분류 결과입니다. {"intents": [{"intent": "time_left"}]} 이상입니다.')
    assert out == {"intents": [{"intent": "time_left"}]}


def test_json_모드가_거부되면_한_번_더_시도(monkeypatch):
    """response_format 을 지원하지 않는 모델·게이트웨이는 두 번째 시도로 답을 받아요."""
    import httpx

    calls = []

    class Resp:
        def __init__(self, ok, payload):
            self.ok, self.payload = ok, payload

        def raise_for_status(self):
            if not self.ok:
                raise httpx.HTTPStatusError("400", request=None, response=None)

        def json(self):
            return self.payload

    def fake_post(url, headers=None, json=None, timeout=None):
        calls.append(json)
        if "response_format" in json:
            return Resp(False, {})
        return Resp(True, {"choices": [{"message": {"content": '결과: {"intents": []}'}}]})

    monkeypatch.setattr(httpx, "post", fake_post)
    assert llm._chat_json("system", "user") == {"intents": []}
    assert len(calls) == 2
    assert "response_format" not in calls[1]


def test_요청에_reasoning_effort를_넣고_온도는_비움(monkeypatch):
    """Meta Model API(Chat Completions)는 reasoning_effort 를 쓰고, 온도는 안 보내는 게 기본이에요."""
    monkeypatch.setattr(llm.config, "LLM_REASONING_EFFORT", "low")
    monkeypatch.setattr(llm.config, "LLM_TEMPERATURE", "")

    payload = llm._payload("system", "user", json_mode=True)
    assert payload["reasoning_effort"] == "low"
    assert "reasoning" not in payload
    assert "temperature" not in payload
    assert payload["response_format"] == {"type": "json_object"}


def test_온도를_정하면_그_값을_보냄(monkeypatch):
    monkeypatch.setattr(llm.config, "LLM_REASONING_EFFORT", "")
    monkeypatch.setattr(llm.config, "LLM_TEMPERATURE", "0.3")

    payload = llm._payload("system", "user", json_mode=False)
    assert payload["temperature"] == 0.3
    assert "reasoning_effort" not in payload
    assert "response_format" not in payload
