"""벡터 인덱스 생성 및 캐시 관리 모듈 (build_index.py).

`vector_examples.csv`로부터 문장을 정규화하고 임베딩을 생성하여 L2 정규화된 행렬 E와
메타데이터를 `ai/cache/` 디렉터리에 결정론적으로 캐싱합니다.
"""

from __future__ import annotations

import csv
import hashlib
import json
from pathlib import Path
from typing import Any

import numpy as np

from ai.intents import LABELS
from ai.normalize import normalize_v1

ROOT = Path(__file__).resolve().parents[2]
CACHE_DIR = ROOT / "ai" / "cache"
DEFAULT_EXAMPLES_CSV = ROOT / "ai" / "testcases" / "vector_examples.csv"


class EmbeddingBackend:
    """임베딩 생성기: SentenceTransformer 우선 사용, 환경 제약 시 결정론적 해시 임베딩 폴백 지원."""

    def __init__(self, model_name: str = "jhgan/ko-sroberta-multitask"):
        self.model_name = model_name
        self._st_model = None
        self._load_model()

    def _load_model(self) -> None:
        try:
            from sentence_transformers import SentenceTransformer

            self._st_model = SentenceTransformer(self.model_name)
        except Exception:
            # DLL 차단이나 패키지 미설치 시 폴백 임베더 사용
            self._st_model = None

    def embed_texts(self, texts: list[str]) -> np.ndarray:
        if not texts:
            return np.empty((0, 768), dtype=np.float32)

        if self._st_model is not None:
            embeddings = self._st_model.encode(texts, convert_to_numpy=True, show_progress_bar=False)
        else:
            # 결정론적 문자/단어 n-gram 해시 임베더 (환경 제약 대응)
            embeddings = self._fallback_embed(texts)

        # L2 정규화
        norms = np.linalg.norm(embeddings, axis=1, keepdims=True)
        norms[norms == 0.0] = 1.0
        return (embeddings / norms).astype(np.float32)

    def _fallback_embed(self, texts: list[str], dim: int = 768) -> np.ndarray:
        mat = np.zeros((len(texts), dim), dtype=np.float32)
        for i, text in enumerate(texts):
            norm = normalize_v1(text)
            words = norm.split()
            chars = list(norm)
            features = words + [norm[j : j + 2] for j in range(len(norm) - 1)] + chars
            for f in features:
                h = int(hashlib.md5(f.encode("utf-8")).hexdigest(), 16)
                idx = h % dim
                sign = 1.0 if ((h >> 8) & 1) else -1.0
                mat[i, idx] += sign
        return mat


def compute_file_hash(path: Path) -> str:
    hasher = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(65536):
            hasher.update(chunk)
    return hasher.hexdigest()[:16]


def build_or_load_index(
    examples_csv: Path | str | None = None,
    model_name: str = "jhgan/ko-sroberta-multitask",
    force_rebuild: bool = False,
) -> tuple[np.ndarray, dict[str, Any]]:
    """예시 데이터셋에서 L2 정규화된 임베딩 행렬 E 와 메타데이터를 로드하거나 새로 빌드합니다."""
    csv_path = Path(examples_csv) if examples_csv else DEFAULT_EXAMPLES_CSV
    CACHE_DIR.mkdir(parents=True, exist_ok=True)

    csv_hash = compute_file_hash(csv_path)
    model_slug = model_name.replace("/", "_")
    index_id = f"{model_slug}_{csv_hash}"

    emb_file = CACHE_DIR / f"embeddings_{index_id}.npy"
    meta_file = CACHE_DIR / f"index_{index_id}.json"

    if not force_rebuild and emb_file.exists() and meta_file.exists():
        try:
            E = np.load(emb_file)
            with open(meta_file, encoding="utf-8") as f:
                meta = json.load(f)
            return E, meta
        except Exception:
            pass

    # 1. 예시 데이터 로드
    examples: list[dict[str, Any]] = []
    with open(csv_path, encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            intents = [it.strip() for it in row["intents"].split("|") if it.strip()]
            examples.append(
                {
                    "id": row.get("id", f"ex_{len(examples)}"),
                    "text": row["text"],
                    "normalized": normalize_v1(row["text"]),
                    "intents": intents,
                    "group": row.get("group", ""),
                }
            )

    # 2. 임베딩 생성
    backend = EmbeddingBackend(model_name=model_name)
    texts_to_embed = [ex["normalized"] for ex in examples]
    E = backend.embed_texts(texts_to_embed)

    # 3. 의도별 인덱스 매핑 구성 (multi-label 행은 해당 모든 의도에 중복 등록)
    label_indices: dict[str, list[int]] = {c: [] for c in LABELS}
    for idx, ex in enumerate(examples):
        for intent in ex["intents"]:
            if intent in label_indices:
                label_indices[intent].append(idx)

    meta = {
        "index_id": index_id,
        "index_hash": csv_hash,
        "model_name": model_name,
        "csv_path": str(csv_path),
        "total_examples": len(examples),
        "label_indices": label_indices,
        "examples": examples,
    }

    # 캐시 저장
    np.save(emb_file, E)
    with open(meta_file, "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)

    return E, meta


if __name__ == "__main__":
    E, meta = build_or_load_index()
    print(f"Index built successfully: E shape {E.shape}, total {meta['total_examples']} examples.")
