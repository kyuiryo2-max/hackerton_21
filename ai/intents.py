"""의도(Intent), 슬롯(Slot), 키워드, 위험도 단일 정의 소스.

서버, 평가, 프롬프트 간의 드리프트를 방지하기 위한 단일 진실 공급원(Single Source of Truth).
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any

# 벡터 분류기가 예측하는 7개 핵심 의도
# (unsupported 는 벡터 라벨로 쓰지 않고, 시스템/정책 레벨에서 처리)
LABELS: list[str] = [
    "next_vehicle",
    "stopover_check",
    "running_late",
    "time_left",
    "change_todo",
    "place_info",
    "change_route",
]

# 시스템 전체에서 인정하는 의도 (unsupported 포함)
SYSTEM_INTENTS: list[str] = LABELS + ["unsupported"]

# 벡터 상태 정의
STATUS_ACCEPTED = "accepted"
STATUS_ABSTAINED_LOW_SCORE = "abstained:low_score"
STATUS_ABSTAINED_CONFLICT = "abstained:conflict"
STATUS_ABSTAINED_TOO_MANY = "abstained:too_many"
STATUS_ABSTAINED_NEEDS_CONTEXT = "abstained:needs_context"

# 혼동 조합 (두 의도가 동시에 애매하게 잡히면 conflict 로 분류하여 LLM/정책으로 위임)
CONFLICT_COMBINATIONS: list[frozenset[str]] = [
    frozenset({"next_vehicle", "time_left"}),
    frozenset({"stopover_check", "place_info"}),
]

# 의도별 위험도 수준
# high: 일정/경로/할 일 변경 등 실행 시 부작용이 크므로 보수적인 임계값 및 추가 확인 절차 필요
RISK_LEVELS: dict[str, str] = {
    "next_vehicle": "normal",
    "stopover_check": "normal",
    "running_late": "normal",
    "time_left": "normal",
    "place_info": "normal",
    "change_todo": "high",
    "change_route": "high",
}

# 키워드/규칙 분류 사전 (server/app/services/rules.py 와 ai/eval/run.py 공통 기준)
KEYWORDS: dict[str, list[str]] = {
    "running_late": ["늦", "놓쳤", "밀릴"],
    "next_vehicle": ["다음 버스", "다음 지하철", "언제 와", "언제야", "몇 분 남았", "아직 멀었"],
    "time_left": ["몇 분까지", "언제 나가", "지금 바로 나가", "얼마나 더 해도"],
    "stopover_check": ["들러", "들렀", "들를", "사야", "사도", "잠깐 가도"],
    "place_info": ["어디", "몇 시에 닫", "가까운", "제일 가까운"],
    "change_route": ["환승", "빠른 걸로", "싼 걸로", "덜 드는"],
    "change_todo": ["안 사도", "안 해도", "더 급해", "가서 할게"],
}

# 슬롯 정규식 및 추출 패턴
_DELAY_REGEX = re.compile(r"(\d+)\s*분")
_BUY_REGEX = re.compile(r"^(?:아\s*맞다|아)?\s*(.+?)\s*(?:사야|사러|살\s*거)")
_SKIP_REGEX = re.compile(r"^(.+?)\s*(?:은|는)?\s*안\s*(?:사도|해도)")

# 장소 종류 사전 (data/demo/place_types.csv 기준)
PLACE_WORDS: dict[str, list[str]] = {
    "편의점": ["편의점", "간식", "우유", "이어폰", "음료", "생수", "삼각김밥"],
    "약국": ["약국", "약 사", "감기약", "두통약", "밴드"],
    "카페": ["카페", "커피", "아메리카노", "라떼"],
    "다이소": ["다이소", "생활용품"],
    "올리브영": ["올리브영", "화장품"],
    "프린트": ["출력", "인쇄", "복사", "프린트"],
    "은행·ATM": ["은행", "ATM", "현금"],
    "마트": ["마트", "장보기", "장 보"],
    "꽃집": ["꽃집", "꽃다발", "꽃 사"],
    "케이크집": ["케이크"],
    "우체국": ["우체국", "등기"],
    "병원": ["병원", "진료"],
    "안경점": ["안경"],
    "음식점": ["밥 먹", "점심", "저녁 먹"],
    "빵집": ["빵집", "빵 사"],
}


def find_place_types(text: str) -> list[str]:
    """텍스트에서 언급된 장소 종류를 추출합니다."""
    found = [p for p, words in PLACE_WORDS.items() if any(w in text for w in words)]
    return found


@dataclass
class IntentDefinition:
    name: str
    description: str
    risk: str
    required_slots: list[str] = field(default_factory=list)
    optional_slots: list[str] = field(default_factory=list)


INTENT_REGISTRY: dict[str, IntentDefinition] = {
    "next_vehicle": IntentDefinition(
        name="next_vehicle",
        description="탈것(버스·지하철)의 도착·출발 시각 및 대기 시간 조회",
        risk="normal",
    ),
    "stopover_check": IntentDefinition(
        name="stopover_check",
        description="가는 길에 특정 장소(편의점, 약국 등)를 경유할 수 있는지 가능성 확인",
        risk="normal",
        required_slots=["place_types"],
        optional_slots=["todo_text"],
    ),
    "running_late": IntentDefinition(
        name="running_late",
        description="약속이나 일정에 늦을 것 같다는 명시적 지연 표현 및 지연 시간",
        risk="normal",
        optional_slots=["delay_minutes"],
    ),
    "time_left": IntentDefinition(
        name="time_left",
        description="사용자가 지금 나가야 할 시각이나 남은 여유 시간",
        risk="normal",
    ),
    "change_todo": IntentDefinition(
        name="change_todo",
        description="할 일의 삭제, 중요도 변경(우선순위 상향/하향)",
        risk="high",
        required_slots=["action"],
        optional_slots=["todo_text"],
    ),
    "place_info": IntentDefinition(
        name="place_info",
        description="장소 자체의 위치, 영업시간, 연락처 등 상세 정보 조회",
        risk="normal",
        required_slots=["place_types"],
    ),
    "change_route": IntentDefinition(
        name="change_route",
        description="경로 탐색 조건(환승 최소, 최단 시간, 최소 요금 등) 변경",
        risk="high",
        required_slots=["preference"],
    ),
    "unsupported": IntentDefinition(
        name="unsupported",
        description="지원 범위 밖의 일반 질문 (날씨, 맛집 추천 등)",
        risk="normal",
    ),
}


def extract_slots(intent: str, text: str, place_types_found: list[str] | None = None) -> dict[str, Any]:
    """규칙 기반으로 의도에 필요한 기본 슬롯 값을 추출합니다."""
    slots: dict[str, Any] = {}
    places = place_types_found if place_types_found is not None else find_place_types(text)

    if intent in ("stopover_check", "place_info"):
        slots["place_types"] = places
    if intent == "stopover_check":
        m = _BUY_REGEX.search(text.strip())
        slots["todo_text"] = f"{m[1].strip()} 사기" if m and m[1].strip() else text.strip()
    elif intent == "running_late":
        m = _DELAY_REGEX.search(text)
        slots["delay_minutes"] = int(m[1]) if m else None
    elif intent == "change_todo":
        slots["action"] = "delete" if ("안 사도" in text or "안 해도" in text or "가서 할게" in text) else "raise"
        m = _SKIP_REGEX.search(text.strip())
        slots["todo_text"] = m[1].strip() if m else ""
    elif intent == "change_route":
        if "환승" in text:
            slots["preference"] = "transfer"
        elif "싼" in text or "덜 드는" in text:
            slots["preference"] = "fare"
        else:
            slots["preference"] = "time"

    return slots


def validate_slots(intent: str, slots: dict[str, Any]) -> bool:
    """해당 의도에 필요한 필수 슬롯이 모두 채워졌는지 검증합니다."""
    defn = INTENT_REGISTRY.get(intent)
    if not defn:
        return False
    for req in defn.required_slots:
        val = slots.get(req)
        if val is None:
            return False
        if isinstance(val, (list, str)) and len(val) == 0:
            return False
    return True
