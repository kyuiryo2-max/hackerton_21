"""② 이해의 대체 경로: AI 키가 없거나 AI 호출이 실패할 때 쓰는 키워드 규칙.

부스 시연 중 AI가 멈춰도 답할 수 있게 해요. 정확도는 AI보다 낮고, 응답에 engine="rule"로 표시해요.
질문 키워드는 ai/eval/run.py 의 비교 기준선과 같아요. 출력 모양은 docs/design/json-format.md 를 따라요.
"""
from functools import lru_cache
import re

from app.services.llm import DEFAULT_CONFIRM_QUESTION, place_types


@lru_cache
def _vector_classifier():
    """벡터 분류기 인스턴스를 캐싱하여 가져옵니다."""
    try:
        import sys
        from pathlib import Path

        repo_root = str(Path(__file__).resolve().parents[3])
        if repo_root not in sys.path:
            sys.path.insert(0, repo_root)

        from ai.vector.classifier import VectorIntentClassifier

        return VectorIntentClassifier()
    except Exception:
        return None

# 질문 종류 (ai/eval/run.py KEYWORDS 와 같게 유지)
INTENT_WORDS = {
    "running_late": ["늦", "놓쳤"],
    "next_vehicle": ["다음 버스", "다음 지하철", "언제 와"],
    "time_left": ["몇 분", "언제 나가"],
    "stopover_check": ["들러", "들렀", "들를", "사야", "사도"],
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
MISSED_WORDS = ["놓쳤", "놓칠", "지나갔"]
STOPOVER_ONLY = ["들러", "들렀", "들를", "사야"]
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
    # "안 사도 돼"는 빼기예요. "사도"만으로 들르기가 잡혔으면 들르기를 지워요
    if "change_todo" in names and "stopover_check" in names and not any(w in text for w in STOPOVER_ONLY):
        names.remove("stopover_check")
    # "몇 분 늦어"는 늦어짐이에요
    if "running_late" in names and "time_left" in names:
        names.remove("time_left")

    # 키워드 매칭이 없으면 벡터 분류기(Top-m)로 의미 기반 판정
    if not names:
        clf = _vector_classifier()
        if clf:
            try:
                vec_res = clf.classify(text)
                if vec_res.get("status") == "accepted":
                    names = [i["intent"] for i in vec_res.get("intents", [])]
                elif vec_res.get("status") == "abstained:needs_context":
                    return {
                        "type": "question",
                        "intents": [_intent("unsupported", text)],
                        "needs_confirm": True,
                        "question": DEFAULT_CONFIRM_QUESTION,
                    }
            except Exception:
                pass

    intents = [_intent(n, text) for n in names] or [_intent("unsupported", text)]
    missing_place = any(i["intent"] in ("stopover_check", "place_info") and not i["place_types"] for i in intents)
    missing_delay = _delay_unknown(intents, text)
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


def _delay_unknown(intents: list[dict], text: str) -> bool:
    """늦는다는데 분이 없고, 차를 놓친 말도 아니면 몇 분인지 물어봐야 해요."""
    late = any(i["intent"] == "running_late" and i.get("delay_minutes") is None for i in intents)
    return late and not any(w in text for w in MISSED_WORDS)


def ask_delay_if_unknown(classified: dict, text: str) -> dict:
    """AI 결과에도 같은 규칙을 적용해요. "늦을 것 같아" → "몇 분 늦을 것 같아요?" (PR #26 리뷰)"""
    if classified["needs_confirm"] or not _delay_unknown(classified["intents"], text):
        return classified
    return {**classified, "needs_confirm": True, "question": "몇 분 늦을 것 같아요?"}
