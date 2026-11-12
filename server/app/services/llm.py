"""② AI 이해와 ⑤ 설명 문장. AI는 판단과 문장만 맡고, 숫자는 만들지 않아요.

- parse_todo: 할 일 문장 → 장소 종류 JSON (docs/design/json-format.md 1번)
- classify_question: 질문 문장 → 질문 종류 JSON (json-format.md 2번). 애매하면 needs_confirm + 되묻는 문장
- numbers_match: 답변 속 숫자가 계산 결과에 있는지 코드로 확인
"""
import csv
import json
import re
from functools import lru_cache
from pathlib import Path

from app import config

PROMPT_DIR = Path(__file__).resolve().parent.parent / "prompts"
PLACE_TYPES_CSV = Path(__file__).resolve().parents[3] / "data" / "demo" / "place_types.csv"
PROMPT_VERSION = "v1"

INTENTS = (
    "next_vehicle", "stopover_check", "running_late", "time_left",
    "change_todo", "place_info", "change_route", "unsupported",
)
DEFAULT_CONFIRM_QUESTION = "조금만 더 자세히 말해 줄래요?"


def load_prompt(name: str, version: str | None = None) -> str:
    text = (PROMPT_DIR / (version or PROMPT_VERSION) / f"{name}.md").read_text(encoding="utf-8")
    return text.replace("{{PLACE_TYPES}}", ", ".join(place_types()))


@lru_cache
def place_types() -> list[str]:
    with open(PLACE_TYPES_CSV, encoding="utf-8") as f:
        return [row["place_type"] for row in csv.DictReader(f)]


# AI가 응답하지 않을 때 기다리는 최대 시간(초). 넘으면 바로 키워드 규칙으로 넘어가요.
# 멘토링(11/11): 10초는 사용자에게 너무 김. 측정값은 보통 1~2초, 가장 느린 것 4.5초라 5초로 줄였어요 (할 일 63번).
LLM_TIMEOUT_SECONDS = 5


@lru_cache
def _client():
    from openai import OpenAI

    return OpenAI(
        base_url=config.OPENAI_BASE_URL,
        api_key=config.OPENAI_API_KEY,
        timeout=LLM_TIMEOUT_SECONDS,
        max_retries=0,
    )


def _parse_json_safe(content: str) -> dict:
    text = content.strip()
    if text.startswith("```"):
        lines = text.splitlines()
        if lines and lines[0].startswith("```"):
            lines = lines[1:]
        if lines and lines[-1].strip().startswith("```"):
            lines = lines[:-1]
        text = "\n".join(lines).strip()
    return json.loads(text or "{}")


def _chat_json(system: str, user: str) -> dict:
    # 1. httpx를 통한 직접 호출 (jiter DLL 차단 우회 및 OpenRouter 완벽 지원)
    try:
        import httpx

        headers = {
            "Authorization": f"Bearer {config.OPENAI_API_KEY}",
            "Content-Type": "application/json",
        }
        payload = {
            "model": config.LLM_MODEL,
            "temperature": 0,
            "response_format": {"type": "json_object"},
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
        }
        base_url = config.OPENAI_BASE_URL.rstrip("/")
        url = f"{base_url}/chat/completions"
        resp = httpx.post(url, headers=headers, json=payload, timeout=LLM_TIMEOUT_SECONDS)
        resp.raise_for_status()
        content = resp.json()["choices"][0]["message"]["content"] or "{}"
        return _parse_json_safe(content)
    except Exception:
        pass

    # 2. openai 클라이언트 폴백
    resp = _client().chat.completions.create(
        model=config.LLM_MODEL,
        temperature=0,
        response_format={"type": "json_object"},
        messages=[{"role": "system", "content": system}, {"role": "user", "content": user}],
    )
    return _parse_json_safe(resp.choices[0].message.content or "{}")


def parse_todo(text: str) -> dict:
    out = _chat_json(load_prompt("todo_to_place"), text)
    places = out.get("place_types", [])
    if not isinstance(places, list):
        # 형식이 깨진 출력은 버려요. 부르는 쪽이 키워드 규칙으로 대신 처리해요
        raise ValueError("AI 출력의 place_types가 목록이 아니에요")
    # 목록에 없는 장소 종류는 버리고 확인 요청 (json-format.md 규칙)
    allowed = set(place_types())
    kept = [p for p in places if p in allowed]
    return {
        "type": "todo",
        "text": out.get("text") if isinstance(out.get("text"), str) and out.get("text") else text,
        "place_types": kept,
        "importance": "필수" if out.get("importance") == "필수" else None,
        # 장소가 필요 없는 할 일("엄마한테 전화하기")은 빈 목록이 정답이라 되묻지 않아요
        "needs_confirm": bool(out.get("needs_confirm")) or len(kept) != len(places),
    }


def classify_question(text: str, context: dict | None = None, history: list[dict] | None = None) -> dict:
    """history 는 최근 대화 (repository.recent_messages). "거기 말고"처럼 앞 대화를 가리킬 때 써요."""
    user = json.dumps(
        {"question": text, "context": context or {}, "recent_messages": history or []},
        ensure_ascii=False,
    )
    return normalize_question(_chat_json(load_prompt("question_intent"), user))


def normalize_question(out: dict) -> dict:
    """AI 결과를 json-format.md 2번 모양으로 맞춰요 (#12 회의 5번).

    - 목록에 없는 질문 종류·장소 종류는 버리고 되묻기
    - 질문 종류가 하나도 없으면 되묻기
    - 되묻는데 문장이 없으면 기본 문장
    """
    allowed_places = set(place_types())
    intents, dropped = [], False
    for item in out.get("intents") or []:
        if not isinstance(item, dict) or item.get("intent") not in INTENTS:
            dropped = True
            continue
        places = item.get("place_types") or []
        kept = [p for p in places if p in allowed_places]
        dropped = dropped or len(kept) != len(places)
        intents.append({**item, "place_types": kept})
    needs_confirm = bool(out.get("needs_confirm")) or dropped or not intents
    question = out.get("question") or None
    if needs_confirm and not question:
        question = DEFAULT_CONFIRM_QUESTION
    return {
        "type": "question",
        "intents": intents,
        "needs_confirm": needs_confirm,
        "question": question if needs_confirm else None,
    }


_NUM = re.compile(r"\d+")


# 서버 시각 문자열. 예: 2026-11-21T08:59:17+09:00
_ISO_TIME = re.compile(r"\d{4}-\d{2}-\d{2}T(\d{2}):(\d{2})(?::\d{2}(?:\.\d+)?)?(?:[+-]\d{2}:\d{2}|Z)?")


def _hour_minute_numbers(hh: int, mm: int) -> set[int]:
    """시각에서 답변에 나올 수 있는 숫자: 시(24시간·12시간), 분. 연·월·일·초는 넣지 않아요."""
    nums = {hh, mm}
    if hh > 12:
        nums.add(hh - 12)
    if hh == 0:
        nums.add(12)
    return nums


def _korean_time(hh: int, mm: int) -> str:
    return f"{hh}시" if mm == 0 else f"{hh}시 {mm}분"


def short_times(val):
    """계산 결과 속 시각 문자열을 "8시 59분"처럼 시·분만 남겨요. AI가 날짜·초를 문장에 쓰지 않게 해요."""
    if isinstance(val, str):
        return _ISO_TIME.sub(lambda m: _korean_time(int(m.group(1)), int(m.group(2))), val)
    if isinstance(val, dict):
        return {k: short_times(v) for k, v in val.items()}
    if isinstance(val, (list, tuple)):
        return [short_times(v) for v in val]
    return val


def extract_allowed_numbers(result: dict | None, base_answer: str = "") -> set[int]:
    """계산 결과(result)와 기본 답변(base_answer)에서 답변에 써도 되는 정수를 모아요.

    시각 문자열은 시·분만 허용해요. 2026-11-21T08:59:17 → {8, 59} (2026, 11, 21, 17은 안 됨)
    """
    allowed: set[int] = set()
    if base_answer:
        for n in _NUM.findall(base_answer):
            allowed.add(int(n))

    def _collect(val):
        if isinstance(val, int) and not isinstance(val, bool):
            allowed.add(val)
        elif isinstance(val, str):
            for m in _ISO_TIME.finditer(val):
                allowed.update(_hour_minute_numbers(int(m.group(1)), int(m.group(2))))
            # 시각을 뺀 나머지 글자 속 숫자 (노선 번호 "2115", 주소 등)
            for n in _NUM.findall(_ISO_TIME.sub(" ", val)):
                v = int(n)
                if v < 10000:
                    allowed.add(v)
        elif isinstance(val, dict):
            for v in val.values():
                _collect(v)
        elif isinstance(val, (list, tuple)):
            for v in val:
                _collect(v)

    if result:
        _collect(result)
    return allowed


def numbers_match(answer: str, allowed: set[int]) -> bool:
    """답변에 나온 숫자가 전부 계산 결과(allowed)에 있으면 True.

    allowed에는 분 값과 시각의 시·분을 넣어요. 예: 8시 23분 → {8, 23}
    False면 AI 문장 대신 정해진 템플릿 문장을 보여 줘요.
    """
    found = [int(n) for n in _NUM.findall(answer)]
    return all(n in allowed for n in found)


def explain_result(
    question: str,
    result: dict | list,
    base_answer: str,
    version: str | None = None,
    check=None,
) -> str:
    """#37: AI를 호출하여 자연스러운 설명 문장을 생성하고, numbers_match로 숫자를 대조 검증합니다.

    - 검증 통과 시: AI가 생성한 자연스러운 문장 반환
    - 검증 실패(숫자 조작/환각) 또는 오류 시: 안전한 기존 템플릿(base_answer) 반환
    """
    if not result:
        return base_answer

    allowed = extract_allowed_numbers(result, base_answer)
    # draft: 코드가 만든 기본 답변. AI는 이 사실을 유지한 채 말투만 자연스럽게 다듬어요
    shown = [short_times(r) for r in result] if isinstance(result, list) else short_times(result)
    user_payload = json.dumps({"question": question, "result": shown, "draft": base_answer}, ensure_ascii=False)

    try:
        system_prompt = load_prompt("explain_result", version=version)
        out = _chat_json(system_prompt, user_payload)
        ai_answer = out.get("answer", "").strip()
        if not ai_answer:
            return base_answer

        # 숫자 대조 검증 + 내용 검사(check, assistant._ai_content_ok)
        if numbers_match(ai_answer, allowed) and (check is None or check(ai_answer)):
            return ai_answer
        return base_answer
    except Exception:
        return base_answer
