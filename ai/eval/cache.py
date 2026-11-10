"""LLM 응답 캐시 모듈 (cache.py).

(prompt_hash, normalized_text, context) 기반으로 캐시 키를 생성하여,
동일 질문에 대한 반복 평가 시 LLM 호출 비용 0원과 100% 재현성을 보장합니다.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

from ai.normalize import normalize_v1


class LLMCache:
    def __init__(self, cache_dir: Path | str | None = None, enabled: bool = True):
        self.enabled = enabled
        if cache_dir is None:
            self.cache_dir = Path(__file__).resolve().parents[1] / "cache" / "llm"
        else:
            self.cache_dir = Path(cache_dir)
        if self.enabled:
            self.cache_dir.mkdir(parents=True, exist_ok=True)

    def _get_key(self, prompt_text: str, text: str, context: dict[str, Any] | None = None) -> str:
        norm_text = normalize_v1(text)
        ctx_str = json.dumps(context or {}, sort_keys=True, ensure_ascii=False)
        content = f"{prompt_text}\n---\n{norm_text}\n---\n{ctx_str}"
        return hashlib.sha256(content.encode("utf-8")).hexdigest()

    def get(self, prompt_text: str, text: str, context: dict[str, Any] | None = None) -> dict[str, Any] | None:
        if not self.enabled:
            return None
        key = self._get_key(prompt_text, text, context)
        path = self.cache_dir / f"{key}.json"
        if path.exists():
            try:
                with open(path, encoding="utf-8") as f:
                    return json.load(f)
            except Exception:
                return None
        return None

    def set(
        self, prompt_text: str, text: str, context: dict[str, Any] | None, response: dict[str, Any]
    ) -> None:
        if not self.enabled:
            return
        key = self._get_key(prompt_text, text, context)
        path = self.cache_dir / f"{key}.json"
        try:
            with open(path, "w", encoding="utf-8") as f:
                json.dump(response, f, ensure_ascii=False, indent=2)
        except Exception:
            pass
