"""모든 테스트에 공통으로 쓰는 준비."""
import pytest

from app.services import live


@pytest.fixture(autouse=True)
def _forget_live_plans():
    """실제 모드 질문(#59)이 기억하는 마지막 계획은 메모리에 있어서, 테스트끼리 섞이지 않게 비워요."""
    live.forget_all()
    yield
    live.forget_all()
