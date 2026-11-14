"""② 이해의 대체 경로: AI 키가 없거나 AI 호출이 실패할 때 쓰는 키워드 규칙.

부스 시연 중 AI가 멈춰도 답할 수 있게 해요. 정확도는 AI보다 낮고, 응답에 engine="rule"로 표시해요.
질문 키워드는 ai/eval/run.py 의 비교 기준선과 같아요. 출력 모양은 docs/design/json-format.md 를 따라요.
"""
import re

from app.services.llm import DEFAULT_CONFIRM_QUESTION, place_types

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

# v3 폴백: 일정/할 일 추가 (AI가 없을 때도 버튼이 뜨게)
_FUTURE_PREFIX = re.compile(r"^(?:나중에|이따|이따가|저녁에|내일|모레|다음에|집\s*가서|집에\s*가서)\s*")
_FUTURE_WORDS = ("나중에", "이따", "저녁에", "내일", "모레", "다음에", "집 가서", "집에 가서")
_TODO_WORDS = ("사야", "해야", "찾아야", "사기", "하기", "챙겨")
_SCHEDULE_WORDS = ("일정", "약속", "스케줄", "예약", "스케쥴")
_SCHEDULE_REQ = ("추가", "등록", "잡아", "넣어", "만들어", "저장", "기억해")
_SCHEDULE_NOISE = re.compile(
    r"(오늘|내일|모레|글피|이번\s*주|다음\s*주|[월화수목금토일]요일|오전|오후|아침|점심|저녁|밤|"
    r"\d{1,2}\s*월|\d{1,2}\s*일|\d{1,2}\s*시(?:\s*\d{1,2}\s*분|\s*반)?|"
    r"일정|약속|스케줄|스케쥴|예약|추가|등록|잡아|넣어|만들어|저장|기억해|해\s*줘|해줘|줘|좀|에서|으로|에)")
_SCHEDULE_LOCATION = re.compile(r"([가-힣A-Za-z0-9]{2,}?(?:역|공항|터미널|병원|학교|회사))")


def _clean_draft_text(text: str) -> str:
    base = re.sub(r"^[가-힣A-Za-z0-9]+에서\s+", "", text.strip())
    return base.strip()


def _schedule_item(text: str) -> dict | None:
    """키워드 폴백: '… 일정 추가해 줘' → add_schedule 초안 (이름·목적지만)."""
    if not any(w in text for w in _SCHEDULE_WORDS) or not any(w in text for w in _SCHEDULE_REQ):
        return None
    found = _SCHEDULE_LOCATION.search(text)
    location = found.group(1) if found else ""
    title = _SCHEDULE_NOISE.sub(" ", text)
    if location:
        title = title.replace(location, " ")
    title = " ".join(title.split()).strip(" .!?~,")
    return {"intent": "add_schedule", "title": title, "location": location, "place_types": []}


def _is_future_todo(text: str) -> bool:
    """키워드 폴백: '나중에/이따/저녁에 … 사야 해' → add_todo."""
    return any(w in text for w in _FUTURE_WORDS) and any(w in text for w in _TODO_WORDS)


def _todo_item(text: str) -> dict:
    return {"intent": "add_todo", "text": todo_text(text), "place_types": place_types_in(text),
            "importance": "필수" if any(w in text for w in REQUIRED_WORDS) else None}


def place_types_in(text: str) -> list[str]:
    allowed = set(place_types())
    found = [p for p, words in PLACE_WORDS.items() if any(w in text for w in words)]
    return [p for p in found if p in allowed]


def todo_text(text: str) -> str:
    """'아 이어폰 사야 돼' → '이어폰 사기'. '나중에 약국에서 약 사기' → '약 사기'."""
    t = _FUTURE_PREFIX.sub("", text.strip())
    m = _BUY.search(t)
    if m and m[1].strip():
        return f"{m[1].strip()} 사기"
    m = re.search(r"(.+?)\s*사기", t)
    if m:
        return f"{_clean_draft_text(m[1])} 사기"
    m = re.search(r"(.+?)\s*찾아야", t)
    if m:
        return f"{_clean_draft_text(m[1])} 찾기"
    m = re.search(r"(.+?)\s*해야", t)
    if m:
        return f"{_clean_draft_text(m[1])} 하기"
    return t


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
    # v3: 일정 추가·나중에 할 일은 다른 키워드보다 먼저 봐요
    intents: list[dict] = []
    schedule = _schedule_item(text)
    if schedule is not None:
        intents = [schedule]
    elif _is_future_todo(text):
        intents = [_todo_item(text)]
    names = [] if intents else [n for n, words in INTENT_WORDS.items() if any(w in text for w in words)]
    # "안 사도 돼"는 빼기예요. "사도"만으로 들르기가 잡혔으면 들르기를 지워요
    if "change_todo" in names and "stopover_check" in names and not any(w in text for w in STOPOVER_ONLY):
        names.remove("stopover_check")
    # "몇 분 늦어"는 늦어짐이에요
    if "running_late" in names and "time_left" in names:
        names.remove("time_left")
    intents = intents or [_intent(n, text) for n in names] or [_intent("unsupported", text)]
    missing_place = any(i["intent"] in ("stopover_check", "place_info") and not i["place_types"] for i in intents)
    missing_delay = _delay_unknown(intents, text)
    missing_title = any(i["intent"] == "add_schedule" and not i.get("title") for i in intents)
    needs_confirm = missing_place or missing_delay or missing_title
    question = None
    if missing_place:
        question = "어디를 들르고 싶은지 알려 줄래요?"
    elif missing_delay:
        question = "몇 분 늦을 것 같아요?"
    elif missing_title:
        question = "무슨 일정인지 알려 줄래요?"
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
