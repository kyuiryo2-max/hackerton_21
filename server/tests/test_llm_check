"""LLM 호출 없이 확인할 수 있는 것만 테스트해요."""
from app.services.llm import load_prompt, numbers_match, place_types


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
