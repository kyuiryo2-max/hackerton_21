"""② 이해의 대체 경로: AI 키가 없거나 AI 호출이 실패할 때 쓰는 키워드 규칙.

부스 시연 중 AI가 멈춰도 답할 수 있게 해요. 정확도는 AI보다 낮고, 응답에 engine="rule"로 표시해요.
질문 키워드는 ai/eval/run.py 의 비교 기준선과 같아요. 출력 모양은 docs/design/json-format.md 를 따라요.
"""
import re

from app.services.llm import DEFAULT_CONFIRM_QUESTION, place_types

# 질문 종류 (ai/eval/run.py KEYWORDS 와 같게 유지)
INTENT_WORDS = {
    "running_late": ["늦"],
    "next_vehicle": ["다음 버스", "다음 지하철", "언제 와"],
    "time_left": ["몇 분", "언제 나가"],
    "stopover_check": ["들러", "들렀", "들를", "사야"],
    "place_info": ["어디"],
    "change_route": ["환승", "빠른 걸로", "싼 걸로"],
    "change_todo": ["안 사도", "안 해도"],
}

# 장소 종류 (data/demo/place_types.csv 의 예시 할 일 기준)
PLACE_WORDS = {
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
REQUIRED_WORDS = ["꼭", "급해", "반드시"]
_DELAY = re.compile(r"(\d+)\s*분")
_BUY = re.compile(r"^(?:아\s*맞다|아)?\s*(.+?)\s*(?:사야|사러|살\s*거)")
_SKIP = re.compile(r"^(.+?)\s*(?:은|는)?\s*안\s*(?:사도|해도)")


def place_types_in(text: str) -> list[str]:
    allowed = set(place_types())
    found = [p for p, words in PLACE_WORDS.items() if any(w in text for w in words)]
    return [p for p in found if p in allowed]


def todo_text(text: str) -> str:
    """'아 이어폰 사야 돼' → '이어폰 사기'. 모양을 모르면 원문 그대로예요."""
    m = _BUY.search(text.strip())
    return f"{m[1].strip()} 사기" if m and m[1].strip() else text.strip()


def parse_todo(text: str) -> dict:
    """할 일 문장 → 장소 종류 (json-format.md 1번 모양)."""
    places = place_types_in(text)
    return {
        "type": "todo",
        "text": text.strip(),
        "place_types": places,
        "importance": "필수" if any(w in text for w in REQUIRED_WORDS) else None,
        "needs_confirm": not places,
    }


def _intent(name: str, text: str) -> dict:
    item = {"intent": name, "place_types": [], "delay_minutes": None}
    if name in ("stopover_check", "place_info"):
        item["place_types"] = place_types_in(text)
    if name == "stopover_check":
        item["todo_text"] = todo_text(text)
    if name == "running_late":
        m = _DELAY.search(text)
        item["delay_minutes"] = int(m[1]) if m else None
    if name == "change_todo":
        item["action"] = "delete"
        m = _SKIP.search(text.strip())
        item["todo_text"] = m[1].strip() if m else ""
    if name == "change_route":
        item["preference"] = "transfer" if "환승" in text else "fare" if "싼" in text else "time"
    return item


def classify_question(text: str) -> dict:
    """질문 → 질문 종류 (json-format.md 2번 모양). 장소나 지연 시간이 빠지면 되물어요."""
    names = [n for n, words in INTENT_WORDS.items() if any(w in text for w in words)]
    # "몇 분 늦어"는 늦어짐이에요
    if "running_late" in names and "time_left" in names:
        names.remove("time_left")
    intents = [_intent(n, text) for n in names] or [_intent("unsupported", text)]
    missing_place = any(i["intent"] in ("stopover_check", "place_info") and not i["place_types"] for i in intents)
    missing_delay = any(i["intent"] == "running_late" and i["delay_minutes"] is None for i in intents)
    needs_confirm = missing_place or missing_delay
    question = None
    if missing_place:
        question = "어디를 들르고 싶은지 알려 줄래요?"
    elif missing_delay:
        question = "몇 분 늦을 것 같아요?"
    return {
        "type": "question",
        "intents": intents,
        "needs_confirm": needs_confirm,
        "question": question or (DEFAULT_CONFIRM_QUESTION if needs_confirm else None),
    }
