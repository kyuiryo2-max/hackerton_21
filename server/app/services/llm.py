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


@lru_cache
def _client():
    from openai import OpenAI

    return OpenAI(base_url=config.OPENAI_BASE_URL, api_key=config.OPENAI_API_KEY)


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
        resp = httpx.post(url, headers=headers, json=payload, timeout=60)
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
    # 목록에 없는 장소 종류는 버리고 확인 요청 (json-format.md 규칙)
    allowed = set(place_types())
    kept = [p for p in out.get("place_types", []) if p in allowed]
    if len(kept) != len(out.get("place_types", [])):
        out["needs_confirm"] = True
    out["place_types"] = kept
    return out


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


def numbers_match(answer: str, allowed: set[int]) -> bool:
    """답변에 나온 숫자가 전부 계산 결과(allowed)에 있으면 True.

    allowed에는 분 값과 시각의 시·분을 넣어요. 예: 8시 23분 → {8, 23}
    False면 AI 문장 대신 정해진 템플릿 문장을 보여 줘요.
    """
    return all(int(n) in allowed for n in _NUM.findall(answer))
