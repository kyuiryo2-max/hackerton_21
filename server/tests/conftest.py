"""모든 테스트에 공통으로 쓰는 준비."""
import pytest

from app import config
from app.services import live


@pytest.fixture(autouse=True)
def _forget_live_plans():
    """실제 모드 질문(#59)이 기억하는 마지막 계획은 메모리에 있어서, 테스트끼리 섞이지 않게 비워요."""
    live.forget_all()
    yield
    live.forget_all()


@pytest.fixture(autouse=True)
def _no_ai_sentence_from_env(monkeypatch):
    """.env의 EXPLAIN_WITH_AI=true 때문에 테스트가 진짜 AI를 불러 답이 달라지지 않게 꺼요 (11/13 발견).

    AI 문장을 시험하는 테스트는 explain_with_ai=True를 직접 넘겨요.
    """
    monkeypatch.setattr(config, "EXPLAIN_WITH_AI", False)
