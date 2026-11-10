"""텍스트 정규화 및 단문/문맥 참조 판별 모듈 (preprocess_v1).
"""

from __future__ import annotations

import re
import unicodedata

PREPROCESS_VERSION = "v1"

# 지시어·단문 참조 표현 패턴 (문맥이 반드시 필요한 발화)
_DEICTIC_WORDS = [
    "거기",
    "그거",
    "저기",
    "이거",
    "방금",
    "아까",
    "취소",
    "됐어",
    "안 갈래",
    "빼줘",
]

_WHITESPACE_RE = re.compile(r"\s+")


def normalize_v1(text: str) -> str:
    """preprocess_v1:

    1. Unicode NFC 정규화
    2. 소문자화 (영문/특수문자 대응)
    3. 연속 공백 축소 및 양끝 공백 제거
    """
    if not text:
        return ""
    # 1. NFC 정규화
    text = unicodedata.normalize("NFC", text)
    # 2. 소문자화
    text = text.lower()
    # 3. 공백 축소
    text = _WHITESPACE_RE.sub(" ", text).strip()
    return text


def is_short_reference(text: str) -> bool:
    """단문이거나 지시어가 포함되어 문맥(context) 없이는 독립 의도 판정이 어려운지 검사합니다.

    - 5자 이하이거나 명시적 지시어가 포함된 경우
    - 예: '거기 가', '취소할래', '아까 그거'
    """
    norm = normalize_v1(text)
    if not norm:
        return True

    # 명시적 지시 대명사 / 축약 표현
    if any(dw in norm for dw in _DEICTIC_WORDS):
        # 단, "약국 어디" 처럼 명시적 장소가 있는 경우는 제외
        if len(norm) <= 7 or not any(kw in norm for kw in ["편의점", "약국", "카페", "정류장", "버스", "지하철"]):
            return True

    # 4글자 이하의 극단적 단문이면서 구체적 명사가 부족한 경우
    if len(norm) <= 4:
        return True

    return False
