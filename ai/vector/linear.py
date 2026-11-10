"""(Phase 3) 로지스틱 회귀(Logistic Regression) 비교 분류기 (linear.py).

VectorIntentClassifier 와 동일한 classify / batch_classify 인터페이스를 제공하여,
Top-m vs LogReg의 Coverage-Selective Risk 성능을 동일 split에서 엄격히 비교할 수 있도록 합니다.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import numpy as np
from sklearn.linear_model import LogisticRegression
from sklearn.multiclass import OneVsRestClassifier

from ai.intents import (
    CONFLICT_COMBINATIONS,
    LABELS,
    STATUS_ACCEPTED,
)
from ai.normalize import PREPROCESS_VERSION, is_short_reference, normalize_v1
from ai.vector.build_index import EmbeddingBackend, build_or_load_index


class LinearIntentClassifier:
    """One-vs-Rest 로지스틱 회귀 기반 의도 분류기."""

    def __init__(
        self,
        examples_csv: Path | str | None = None,
        model_name: str = "jhgan/ko-sroberta-multitask",
        threshold: float = 0.5,
    ):
        self.model_name = f"LogReg({model_name})"
        self.model_revision = "main"
        self.threshold = threshold

        # 1. 인덱스 및 예시 로드
        self.E, self.meta = build_or_load_index(examples_csv=examples_csv, model_name=model_name)
        self.examples = self.meta["examples"]
        self.index_hash = self.meta.get("index_hash", "")

        # 2. 임베딩 백엔드
        self.backend = EmbeddingBackend(model_name=model_name)

        # 3. 이진 라벨 매트릭스 구성 및 학습
        n = len(self.examples)
        Y = np.zeros((n, len(LABELS)), dtype=int)
        for i, ex in enumerate(self.examples):
            for intent in ex["intents"]:
                if intent in LABELS:
                    Y[i, LABELS.index(intent)] = 1

        self.clf = OneVsRestClassifier(
            LogisticRegression(C=1.0, max_iter=500, class_weight="balanced")
        )
        self.clf.fit(self.E, Y)

    def classify(self, text: str) -> dict[str, Any]:
        norm = normalize_v1(text)
        q = self.backend.embed_texts([norm])  # (1, D)
        probs = self.clf.predict_proba(q)[0]  # (n_classes,)

        scores = {c: round(float(probs[i]), 4) for i, c in enumerate(LABELS)}
        passed = [c for c in LABELS if scores[c] >= self.threshold]

        if not passed:
            reason = "needs_context" if is_short_reference(text) else "low_score"
            return {
                "status": f"abstained:{reason}",
                "intents": [],
                "abstain_reason": reason,
                "scores": scores,
                "evidence": [],
                "top_similarity": round(float(np.max(probs)), 4),
                "model": self.model_name,
                "model_revision": self.model_revision,
                "preprocess_version": PREPROCESS_VERSION,
                "index_hash": self.index_hash,
            }

        if len(passed) > 2:
            return {
                "status": "abstained:too_many",
                "intents": [],
                "abstain_reason": "too_many",
                "scores": scores,
                "evidence": [],
                "top_similarity": round(float(np.max(probs)), 4),
                "model": self.model_name,
                "model_revision": self.model_revision,
                "preprocess_version": PREPROCESS_VERSION,
                "index_hash": self.index_hash,
            }

        if len(passed) == 2 and frozenset(passed) in CONFLICT_COMBINATIONS:
            return {
                "status": "abstained:conflict",
                "intents": [],
                "abstain_reason": "conflict",
                "scores": scores,
                "evidence": [],
                "top_similarity": round(float(np.max(probs)), 4),
                "model": self.model_name,
                "model_revision": self.model_revision,
                "preprocess_version": PREPROCESS_VERSION,
                "index_hash": self.index_hash,
            }

        return {
            "status": STATUS_ACCEPTED,
            "intents": [{"intent": c, "score": scores[c], "threshold": self.threshold} for c in passed],
            "abstain_reason": None,
            "scores": scores,
            "evidence": [],
            "top_similarity": round(float(np.max(probs)), 4),
            "model": self.model_name,
            "model_revision": self.model_revision,
            "preprocess_version": PREPROCESS_VERSION,
            "index_hash": self.index_hash,
        }
