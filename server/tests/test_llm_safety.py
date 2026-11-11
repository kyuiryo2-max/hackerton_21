"""AI 호출 안전장치: 대기 시간 제한, 대체 규칙은 키워드만."""


def test_AI_대기_시간은_10초를_넘지_않음(monkeypatch):
    """AI가 응답하지 않아도 화면이 오래 멈추지 않고 키워드 규칙으로 넘어가요."""
    from app.services import llm

    monkeypatch.setattr(llm.config, "OPENAI_API_KEY", "test-key")
    llm._client.cache_clear()
    try:
        client = llm._client()
        assert llm.LLM_TIMEOUT_SECONDS <= 10
        assert client.timeout <= 10
        assert client.max_retries == 0
    finally:
        llm._client.cache_clear()


def test_대체_규칙은_벡터_없이_키워드만_씀():
    """벡터 분류는 비교 실험(ai/vector)에만 쓰고 서버 대체 규칙에는 넣지 않아요."""
    import inspect

    from app.services import rules

    assert "vector" not in inspect.getsource(rules).lower()
