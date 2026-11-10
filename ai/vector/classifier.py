"""벡터 의도 분류기 (VectorIntentClassifier).

의도별 Top-m 평균 점수와 의도별 임계값(tau_accept, tau_multi)을 적용하여
'accepted' 또는 'abstained:reason' 2상태를 결정론적으로 출력합니다.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import numpy as np

from ai.intents import (
    CONFLICT_COMBINATIONS,
    LABELS,
    STATUS_ABSTAINED_CONFLICT,
    STATUS_ABSTAINED_LOW_SCORE,
    STATUS_ABSTAINED_NEEDS_CONTEXT,
    STATUS_ABSTAINED_TOO_MANY,
    STATUS_ACCEPTED,
)
from ai.normalize import PREPROCESS_VERSION, is_short_reference, normalize_v1
from ai.vector.build_index import EmbeddingBackend, build_or_load_index

DEFAULT_THRESHOLDS_PATH = Path(__file__).resolve().parent / "thresholds.json"


class VectorIntentClassifier:
    def __init__(
        self,
        thresholds_path: Path | str | None = None,
        examples_csv: Path | str | None = None,
        model_name: str = "jhgan/ko-sroberta-multitask",
        top_m: int = 2,
    ):
        self.model_name = model_name
        self.model_revision = "main"
        self.top_m = top_m

        # 1. 인덱스 로드
        self.E, self.meta = build_or_load_index(examples_csv=examples_csv, model_name=model_name)
        self.label_indices: dict[str, list[int]] = self.meta["label_indices"]
        self.examples: list[dict[str, Any]] = self.meta["examples"]
        self.index_hash: str = self.meta.get("index_hash", "")

        # 2. 임베딩 백엔드
        self.backend = EmbeddingBackend(model_name=model_name)

        # 3. 임계값 로드
        t_path = Path(thresholds_path) if thresholds_path else DEFAULT_THRESHOLDS_PATH
        if t_path.exists():
            with open(t_path, encoding="utf-8") as f:
                t_data = json.load(f)
                self.tau_accept: dict[str, float] = t_data.get("tau_accept", {})
                self.tau_multi: dict[str, float] = t_data.get("tau_multi", {})
                self.top_m = t_data.get("top_m", self.top_m)
        else:
            self.tau_accept = {c: 0.55 for c in LABELS}
            self.tau_multi = {c: 0.65 for c in LABELS}

        # 기본 누락 의도 방어값
        for c in LABELS:
            self.tau_accept.setdefault(c, 0.55)
            self.tau_multi.setdefault(c, max(self.tau_accept[c] + 0.10, 0.65))

    def _get_top_m_evidence(
        self, sims: np.ndarray, target_labels: list[str], m: int
    ) -> list[dict[str, Any]]:
        evidence: list[dict[str, Any]] = []
        for c in target_labels:
            indices = self.label_indices.get(c, [])
            if not indices:
                continue
            sub_sims = sims[indices]
            # 상위 m개 인덱스
            top_k_rel = np.argsort(sub_sims)[-m:][::-1]
            for rel_idx in top_k_rel:
                abs_idx = indices[rel_idx]
                ex = self.examples[abs_idx]
                evidence.append(
                    {
                        "intent": c,
                        "text": ex["text"],
                        "similarity": round(float(sub_sims[rel_idx]), 4),
                    }
                )
        return evidence

    def _abstain(
        self,
        reason: str,
        scores: dict[str, float],
        sims: np.ndarray,
        candidate_labels: list[str] | None = None,
    ) -> dict[str, Any]:
        top_sim = float(np.max(sims)) if len(sims) > 0 else 0.0
        return {
            "status": f"abstained:{reason}",
            "intents": [],
            "abstain_reason": reason,
            "scores": scores,
            "evidence": self._get_top_m_evidence(sims, candidate_labels or [], self.top_m),
            "top_similarity": round(top_sim, 4),
            "model": self.model_name,
            "model_revision": self.model_revision,
            "preprocess_version": PREPROCESS_VERSION,
            "index_hash": self.index_hash,
        }

    def classify(self, text: str) -> dict[str, Any]:
        """단일 질문에 대한 벡터 분류를 수행합니다."""
        norm_text = normalize_v1(text)
        q = self.backend.embed_texts([norm_text])[0]  # (D,) L2 정규화
        sims = self.E @ q  # (N,)

        m = self.top_m
        scores: dict[str, float] = {}
        for c in LABELS:
            indices = self.label_indices.get(c, [])
            if not indices:
                scores[c] = 0.0
                continue
            sub_sims = sims[indices]
            top_sims = np.sort(sub_sims)[-m:]
            scores[c] = round(float(np.mean(top_sims)), 4)

        passed = [c for c in LABELS if scores[c] >= self.tau_accept[c]]

        # 미달 의도 처리
        if not passed:
            reason = "needs_context" if is_short_reference(text) else "low_score"
            return self._abstain(reason, scores, sims)

        # 3개 이상 의도 통과 -> 애매함으로 보류
        if len(passed) > 2:
            return self._abstain("too_many", scores, sims, passed)

        # 2개 의도 통과 -> 다중 의도 검증
        if len(passed) == 2:
            # 혼동 조합이거나 둘 다 tau_multi 기준 미달이면 conflict 보류
            pair = frozenset(passed)
            both_passed_multi = all(scores[c] >= self.tau_multi[c] for c in passed)
            if not both_passed_multi or pair in CONFLICT_COMBINATIONS:
                return self._abstain("conflict", scores, sims, passed)

        # 통과 확정 (accepted)
        top_sim = float(np.max(sims)) if len(sims) > 0 else 0.0
        return {
            "status": STATUS_ACCEPTED,
            "intents": [
                {
                    "intent": c,
                    "score": scores[c],
                    "threshold": self.tau_accept[c],
                }
                for c in passed
            ],
            "abstain_reason": None,
            "scores": scores,
            "evidence": self._get_top_m_evidence(sims, passed, m),
            "top_similarity": round(top_sim, 4),
            "model": self.model_name,
            "model_revision": self.model_revision,
            "preprocess_version": PREPROCESS_VERSION,
            "index_hash": self.index_hash,
        }

    def batch_classify(self, texts: list[str]) -> list[dict[str, Any]]:
        """Q @ E.T 일괄 계산을 통해 전체 split 을 고속으로 분류합니다."""
        if not texts:
            return []
        norm_texts = [normalize_v1(t) for t in texts]
        Q = self.backend.embed_texts(norm_texts)  # (B, D)
        Sims = Q @ self.E.T  # (B, N)

        results: list[dict[str, Any]] = []
        m = self.top_m
        for i, text in enumerate(texts):
            sims = Sims[i]
            scores: dict[str, float] = {}
            for c in LABELS:
                indices = self.label_indices.get(c, [])
                if not indices:
                    scores[c] = 0.0
                    continue
                sub_sims = sims[indices]
                scores[c] = round(float(np.mean(np.sort(sub_sims)[-m:])), 4)

            passed = [c for c in LABELS if scores[c] >= self.tau_accept[c]]

            if not passed:
                reason = "needs_context" if is_short_reference(text) else "low_score"
                results.append(self._abstain(reason, scores, sims))
                continue
            if len(passed) > 2:
                results.append(self._abstain("too_many", scores, sims, passed))
                continue
            if len(passed) == 2:
                pair = frozenset(passed)
                both_passed_multi = all(scores[c] >= self.tau_multi[c] for c in passed)
                if not both_passed_multi or pair in CONFLICT_COMBINATIONS:
                    results.append(self._abstain("conflict", scores, sims, passed))
                    continue

            top_sim = float(np.max(sims)) if len(sims) > 0 else 0.0
            results.append(
                {
                    "status": STATUS_ACCEPTED,
                    "intents": [
                        {
                            "intent": c,
                            "score": scores[c],
                            "threshold": self.tau_accept[c],
                        }
                        for c in passed
                    ],
                    "abstain_reason": None,
                    "scores": scores,
                    "evidence": self._get_top_m_evidence(sims, passed, m),
                    "top_similarity": round(top_sim, 4),
                    "model": self.model_name,
                    "model_revision": self.model_revision,
                    "preprocess_version": PREPROCESS_VERSION,
                    "index_hash": self.index_hash,
                }
            )

        return results
