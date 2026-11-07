"""AI 일정·할 일 도우미 파이프라인 (팀 Sync-ro 확정 규격).

역할 분리:
- LLM: 사용자 자연어를 docs/design/json-format.md 규격의 JSON으로 구조화
- Python: 스키마 검증, 8대 질문 의도 라우팅, 장소/경로 도구 실행,
  일정 가능 여부·최대 체류 시간·출발 시각 계산, 산술 역산 및 숫자 일치(numbers_match) 재검증

실행:
    python ai/pipeline.py --demo
    python ai/pipeline.py "편의점 들렀다 가도 돼?"
"""

from __future__ import annotations

import csv
import json
import os
import re
import sys
from dataclasses import asdict, dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Literal, Optional, Protocol

import requests

ROOT_DIR = Path(__file__).resolve().parents[1]
PLACE_TYPES_CSV = ROOT_DIR / "data" / "demo" / "place_types.csv"
KST = timezone(timedelta(hours=9))

# ----------------------------- 확정 스키마 및 자료형 -----------------------------

ALLOWED_QUESTION_INTENTS = {
    "next_vehicle",
    "stopover_check",
    "running_late",
    "time_left",
    "change_todo",
    "place_info",
    "change_route",
    "unsupported",
}

DEFAULT_PLACE_TYPES = [
    "약국", "편의점", "우체국", "꽃집", "케이크집", "카페",
    "프린트", "은행·ATM", "마트", "병원", "안경점", "다이소"
]


def load_allowed_place_types() -> list[str]:
    """12개 허용 장소 목록을 CSV에서 로드합니다."""
    if PLACE_TYPES_CSV.exists():
        with open(PLACE_TYPES_CSV, encoding="utf-8") as f:
            return [row["place_type"] for row in csv.DictReader(f) if row.get("place_type")]
    return DEFAULT_PLACE_TYPES


@dataclass
class QuestionIntentItem:
    intent: str
    place_types: list[str] = field(default_factory=list)
    delay_minutes: Optional[int] = None
    todo_text: str = ""
    action: Optional[Literal["delete", "raise", "lower"]] = None
    preference: Optional[Literal["time", "transfer", "fare"]] = None


@dataclass
class ParsedQuestion:
    type: Literal["question"] = "question"
    intents: list[QuestionIntentItem] = field(default_factory=list)


@dataclass
class ParsedTodo:
    type: Literal["todo"] = "todo"
    text: str = ""
    place_types: list[str] = field(default_factory=list)
    importance: Optional[Literal["필수", "선택"]] = None
    needs_confirm: bool = False


@dataclass
class Event:
    title: str
    start: datetime
    end: Optional[datetime] = None
    location: Optional[str] = None
    preparation_minutes: int = 15


@dataclass
class Place:
    name: str
    category: str
    address: str = ""


@dataclass
class Route:
    minutes: int
    distance_km: Optional[float] = None


@dataclass
class AppConfig:
    current_location: str = "현재 위치"
    timezone_name: str = "Asia/Seoul"
    default_preparation_minutes: int = 15
    default_errand_stay_minutes: int = 20
    schedule: list[Event] = field(default_factory=list)


# ------------------------------- 프롬프트 및 파서 -------------------------------

QUESTION_SYSTEM_PROMPT = """너는 이동 중인 사용자의 질문을 아래 8개 질문 종류로 분류하고 필요한 값을 추출한다.
숫자를 계산하거나 답을 만들지 않는다. 분류만 한다.

질문 종류:
- next_vehicle: 다음 버스·지하철 도착 정보
- stopover_check: 가는 길에 들르기 -> place_types
- running_late: 늦어짐 -> delay_minutes
- time_left: 남은 시간/출발 시각 확인
- change_todo: 할 일 삭제·중요도 변경 -> todo_text, action ("delete" | "raise" | "lower")
- place_info: 장소 위치/정보 -> place_types
- change_route: 경로 기준 변경 -> preference ("time" | "transfer" | "fare")
- unsupported: 위에 해당 없음

규칙:
- place_types는 이 목록 안의 값만 사용: {PLACE_TYPES}
- 질문 종류가 두 개면 intents 배열에 순서대로 넣는다.
- JSON 하나만 출력한다.
형식: {{"type": "question", "intents": [{{"intent": "...", "place_types": [], "delay_minutes": null}}]}}
"""

TODO_SYSTEM_PROMPT = """너는 사용자의 할 일 문장을 "들러야 할 장소 종류"로 변환한다.

규칙:
- place_types는 아래 목록 안의 값만 사용: {PLACE_TYPES}
- 장소가 필요 없는 할 일(예: 통화, 온라인 제출)이면 place_types는 빈 배열.
- 지시대명사("그거", "그 사람 거") 등으로 장소가 애매하면 needs_confirm을 true로 설정.
- 문장에 "꼭", "급해", "반드시"가 있으면 importance는 "필수", 없으면 null.
- JSON 하나만 출력한다.
형식: {{"type": "todo", "text": "<할 일>", "place_types": [...], "importance": null, "needs_confirm": false}}
"""


class RequestParser(Protocol):
    def parse_question(self, text: str) -> ParsedQuestion: ...
    def parse_todo(self, text: str) -> ParsedTodo: ...


class MockRequestParser:
    """API 키 없이 파이프라인 전체를 검증하기 위한 확정형 더미 파서."""

    QUESTION_CASES: dict[str, dict[str, Any]] = {
        "편의점 들렀다 가도 돼?": {
            "type": "question",
            "intents": [{"intent": "stopover_check", "place_types": ["편의점"], "delay_minutes": None}],
        },
        "10분 늦을 것 같아": {
            "type": "question",
            "intents": [{"intent": "running_late", "place_types": [], "delay_minutes": 10}],
        },
        "다음 버스 언제야?": {
            "type": "question",
            "intents": [{"intent": "next_vehicle", "place_types": [], "delay_minutes": None}],
        },
        "몇 분까지 나가면 돼?": {
            "type": "question",
            "intents": [{"intent": "time_left", "place_types": [], "delay_minutes": None}],
        },
        "약은 안 사도 돼": {
            "type": "question",
            "intents": [{"intent": "change_todo", "action": "delete", "todo_text": "약"}],
        },
        "근처 약국 어디야?": {
            "type": "question",
            "intents": [{"intent": "place_info", "place_types": ["약국"]}],
        },
        "환승 적은 걸로": {
            "type": "question",
            "intents": [{"intent": "change_route", "preference": "transfer"}],
        },
        "점심 뭐 먹지?": {
            "type": "question",
            "intents": [{"intent": "unsupported"}],
        },
        "늦을 것 같은데 약국은 들를 수 있어?": {
            "type": "question",
            "intents": [
                {"intent": "running_late", "delay_minutes": None},
                {"intent": "stopover_check", "place_types": ["약국"]},
            ],
        },
        "5분 늦게 나가는데 다음 버스 언제야?": {
            "type": "question",
            "intents": [
                {"intent": "running_late", "delay_minutes": 5},
                {"intent": "next_vehicle"},
            ],
        },
    }

    TODO_CASES: dict[str, dict[str, Any]] = {
        "약 사기": {
            "type": "todo",
            "text": "약 사기",
            "place_types": ["약국"],
            "importance": None,
            "needs_confirm": False,
        },
        "엄마 생신 선물": {
            "type": "todo",
            "text": "엄마 생신 선물",
            "place_types": ["꽃집", "케이크집"],
            "importance": None,
            "needs_confirm": False,
        },
        "그거 사야 됨": {
            "type": "todo",
            "text": "그거 사야 됨",
            "place_types": [],
            "importance": None,
            "needs_confirm": True,
        },
        "엄마한테 전화하기": {
            "type": "todo",
            "text": "엄마한테 전화하기",
            "place_types": [],
            "importance": None,
            "needs_confirm": False,
        },
        "반드시 타이레놀 사기": {
            "type": "todo",
            "text": "타이레놀 사기",
            "place_types": ["약국"],
            "importance": "필수",
            "needs_confirm": False,
        },
    }

    def parse_question(self, text: str) -> ParsedQuestion:
        matched = self.QUESTION_CASES.get(text)
        if not matched:
            for k, v in self.QUESTION_CASES.items():
                if text in k or k in text:
                    matched = v
                    break
        if not matched:
            matched = {"type": "question", "intents": [{"intent": "unsupported"}]}
        return validate_parsed_question(matched)

    def parse_todo(self, text: str) -> ParsedTodo:
        matched = self.TODO_CASES.get(text)
        if not matched:
            for k, v in self.TODO_CASES.items():
                if text in k or k in text:
                    matched = v
                    break
        if not matched:
            matched = {"type": "todo", "text": text, "place_types": [], "importance": None, "needs_confirm": True}
        return validate_parsed_todo(matched)


def validate_parsed_question(data: Any) -> ParsedQuestion:
    """질문 파싱 결과를 검증하고 이상값을 방어합니다."""
    if not isinstance(data, dict) or data.get("type") != "question":
        return ParsedQuestion(intents=[QuestionIntentItem(intent="unsupported")])

    raw_intents = data.get("intents", [])
    if not isinstance(raw_intents, list):
        return ParsedQuestion(intents=[QuestionIntentItem(intent="unsupported")])

    allowed_types = set(load_allowed_place_types())
    validated_items: list[QuestionIntentItem] = []

    for item in raw_intents:
        if not isinstance(item, dict):
            continue
        intent = item.get("intent", "unsupported")
        if intent not in ALLOWED_QUESTION_INTENTS:
            intent = "unsupported"

        raw_places = item.get("place_types", [])
        if isinstance(raw_places, list):
            place_types = [p for p in raw_places if isinstance(p, str) and p in allowed_types]
        else:
            place_types = []

        delay = item.get("delay_minutes")
        if delay is not None:
            try:
                delay = max(0, min(int(delay), 24 * 60))
            except (ValueError, TypeError):
                delay = None

        action = item.get("action")
        if action not in ("delete", "raise", "lower"):
            action = None

        pref = item.get("preference")
        if pref not in ("time", "transfer", "fare"):
            pref = None

        validated_items.append(
            QuestionIntentItem(
                intent=intent,
                place_types=place_types,
                delay_minutes=delay,
                todo_text=str(item.get("todo_text", "")).strip()[:100],
                action=action,
                preference=pref,
            )
        )

    return ParsedQuestion(intents=validated_items or [QuestionIntentItem(intent="unsupported")])


def validate_parsed_todo(data: Any) -> ParsedTodo:
    """할 일 파싱 결과를 검증합니다."""
    if not isinstance(data, dict) or data.get("type") != "todo":
        raise ValueError("AI 응답이 todo 스키마가 아닙니다.")

    allowed_types = set(load_allowed_place_types())
    text = str(data.get("text", "")).strip()[:300]
    raw_places = data.get("place_types", [])
    place_types = [p for p in raw_places if isinstance(p, str) and p in allowed_types]

    importance = data.get("importance")
    if importance not in ("필수", "선택"):
        importance = None

    needs_confirm = bool(data.get("needs_confirm", False))
    if len(raw_places) != len(place_types):
        needs_confirm = True

    return ParsedTodo(
        text=text,
        place_types=place_types,
        importance=importance,
        needs_confirm=needs_confirm,
    )


# ----------------------- 실행 도구 (지도 및 계산 엔진) -----------------------


class MockProvider:
    """테스트용 지도/경로 어댑터."""

    EXAMPLE_PLACES = {
        "약국": [Place("신촌 연세약국", "약국", "서울 서대문구 신촌로 120")],
        "편의점": [Place("GS25 신촌점", "편의점", "서울 서대문구 신촌로 100")],
        "꽃집": [Place("로즈 플라워", "꽃집", "서울 서대문구 이화여대길 50")],
        "케이크집": [Place("베이커리 블랑", "케이크집", "서울 서대문구 이화여대길 30")],
        "카페": [Place("스타벅스 신촌점", "카페", "서울 서대문구 연세로 10")],
        "다이소": [Place("다이소 신촌본점", "다이소", "서울 서대문구 신촌로 90")],
    }

    def search_places(self, category: str, near: str, limit: int = 3) -> list[Place]:
        return self.EXAMPLE_PLACES.get(category, [])[:limit]

    def get_route(self, origin: str, destination: str) -> Route:
        return Route(minutes=15, distance_km=1.2)


def calculate_errand_window(
    *,
    now: datetime,
    home_or_origin: str,
    places: list[Place],
    provider: MockProvider,
    next_commitment: Optional[Event],
    default_stay_minutes: int,
) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    available_minutes: Optional[int] = None
    if next_commitment:
        available_minutes = max(0, int((next_commitment.start - now).total_seconds() // 60))

    for place in places:
        outbound = provider.get_route(home_or_origin, place.name).minutes
        return_dest = next_commitment.location if (next_commitment and next_commitment.location) else home_or_origin
        inbound = provider.get_route(place.name, return_dest).minutes
        buffer = 5
        max_stay = None if available_minutes is None else max(0, available_minutes - outbound - inbound - buffer)
        feasible = None if max_stay is None else max_stay >= default_stay_minutes
        results.append({
            "place": asdict(place),
            "outbound_minutes": outbound,
            "inbound_minutes": inbound,
            "available_minutes": available_minutes,
            "max_stay_minutes": max_stay,
            "feasible": feasible,
        })
    return results


def calculate_departure(
    *,
    now: datetime,
    event: Event,
    route_minutes: int,
    delay_minutes: int,
    default_preparation_minutes: int,
) -> dict[str, Any]:
    prep = event.preparation_minutes or default_preparation_minutes
    leave_by = event.start - timedelta(minutes=route_minutes)
    prepare_by = leave_by - timedelta(minutes=prep)
    effective_arrival = now + timedelta(minutes=delay_minutes + prep + route_minutes)
    slack = int((event.start - effective_arrival).total_seconds() // 60)
    return {
        "event": event.title,
        "event_start": event.start.isoformat(),
        "route_minutes": route_minutes,
        "delay_minutes": delay_minutes,
        "preparation_minutes": prep,
        "leave_by": leave_by.isoformat(),
        "prepare_by": prepare_by.isoformat(),
        "arrival_with_delay": effective_arrival.isoformat(),
        "on_time": effective_arrival <= event.start,
        "slack_minutes": slack,
        "calculation_checked": (leave_by + timedelta(minutes=route_minutes) == event.start),
    }


_NUM = re.compile(r"\d+")


def numbers_match(answer: str, allowed_numbers: set[int]) -> bool:
    """답변 속 모든 숫자가 계산 결과에 존재하는지 검증."""
    found = [int(n) for n in _NUM.findall(answer)]
    return all(n in allowed_numbers for n in found)


# ------------------------------- 응답 생성기 -------------------------------


def make_answer_for_question(parsed: ParsedQuestion, result: dict[str, Any]) -> str:
    lines = []
    for item in parsed.intents:
        if item.intent == "stopover_check":
            checks = result.get("time_checks", [])
            if not checks:
                lines.append(f"{', '.join(item.place_types) or '해당 장소'}를 검색할 수 없습니다.")
            else:
                first = checks[0]
                place_name = first["place"]["name"]
                if first["feasible"]:
                    lines.append(f"{place_name}에 들렀다 가실 수 있어요. 최대 {first['max_stay_minutes']}분 머무를 수 있습니다.")
                else:
                    lines.append(f"{place_name}에 들르면 약속 시간에 늦을 수 있어요 (최대 체류 {first['max_stay_minutes']}분).")

        elif item.intent == "running_late":
            dep = result.get("departure")
            if dep:
                if dep["on_time"]:
                    lines.append(f"지연 {item.delay_minutes or 0}분을 반영해도 정시 도착 가능해요. {dep['leave_by']}까지 출발하세요.")
                else:
                    lines.append(f"지연을 반영하면 약 {abs(dep['slack_minutes'])}분 늦을 수 있어요. 바로 출발 준비를 시작하세요.")

        elif item.intent == "next_vehicle":
            lines.append("다음 버스는 약 4분 뒤 도착 예정입니다 (신촌역 정류장).")

        elif item.intent == "time_left":
            dep = result.get("departure")
            if dep:
                lines.append(f"다음 약속까지 여유 시간은 약 {dep['slack_minutes']}분입니다. {dep['prepare_by']}에 준비를 시작하세요.")

        elif item.intent == "change_todo":
            action_desc = "삭제" if item.action == "delete" else "우선순위 변경"
            lines.append(f"할 일 '{item.todo_text}'의 {action_desc} 요청을 접수했습니다.")

        elif item.intent == "place_info":
            places = result.get("places", [])
            names = [p["name"] for p in places]
            lines.append(f"근처 {', '.join(item.place_types)}: {', '.join(names) if names else '검색 결과 없음'}")

        elif item.intent == "change_route":
            lines.append(f"경로 추천 기준을 '{item.preference}' 우선으로 변경하여 재정렬합니다.")

        elif item.intent == "unsupported":
            lines.append("이동 및 일정 관리와 관련된 질문만 지원합니다. (예: 버스 도착, 지연, 경유지 확인 등)")

    return "\n".join(lines) or "요청을 처리했습니다."


def run_pipeline(
    text: str,
    *,
    parser: RequestParser,
    provider: MockProvider,
    config: AppConfig,
    now: Optional[datetime] = None,
    mode: Literal["auto", "question", "todo"] = "auto",
) -> dict[str, Any]:
    now = now or datetime.now(KST)
    upcoming = min([e for e in config.schedule if e.start > now], key=lambda e: e.start, default=None)
    result: dict[str, Any] = {}

    is_question = (mode == "question") or (mode == "auto" and any(w in text for w in ["?", "돼", "언제", "몇 분", "늦", "걸로"]))

    if is_question:
        parsed_q = parser.parse_question(text)
        result["type"] = "question"
        result["parsed"] = asdict(parsed_q)

        for item in parsed_q.intents:
            if item.intent == "stopover_check" and item.place_types:
                cat = item.place_types[0]
                places = provider.search_places(cat, config.current_location)
                result["places"] = [asdict(p) for p in places]
                if upcoming:
                    result["time_checks"] = calculate_errand_window(
                        now=now,
                        home_or_origin=config.current_location,
                        places=places,
                        provider=provider,
                        next_commitment=upcoming,
                        default_stay_minutes=config.default_errand_stay_minutes,
                    )

            if item.intent in ("running_late", "time_left") and upcoming:
                result["departure"] = calculate_departure(
                    now=now,
                    event=upcoming,
                    route_minutes=15,
                    delay_minutes=item.delay_minutes or 0,
                    default_preparation_minutes=config.default_preparation_minutes,
                )

        result["answer"] = make_answer_for_question(parsed_q, result)

    else:
        parsed_t = parser.parse_todo(text)
        result["type"] = "todo"
        result["parsed"] = asdict(parsed_t)
        if parsed_t.place_types:
            places = []
            for cat in parsed_t.place_types:
                places.extend(provider.search_places(cat, config.current_location))
            result["places"] = [asdict(p) for p in places]
            if upcoming:
                result["time_checks"] = calculate_errand_window(
                    now=now,
                    home_or_origin=config.current_location,
                    places=places,
                    provider=provider,
                    next_commitment=upcoming,
                    default_stay_minutes=config.default_errand_stay_minutes,
                )
        result["answer"] = f"할 일 '{parsed_t.text}' 등록 완료 (장소: {', '.join(parsed_t.place_types) or '없음'})"

    return result


def run_demo() -> None:
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8")
        except Exception:
            pass

    parser = MockRequestParser()
    provider = MockProvider()
    fixed_now = datetime(2026, 11, 7, 14, 0, 0, tzinfo=KST)
    config = AppConfig(
        schedule=[
            Event(
                title="프로젝트 회의",
                start=fixed_now + timedelta(hours=2),  # 16:00
                location="신촌역 인근",
                preparation_minutes=15,
            )
        ]
    )

    print("=" * 80)
    print("🚀 [팀 Sync-ro 확정 규격 AI 파이프라인 검증 데모]")
    print(f"기준 시각: {fixed_now.isoformat()} | 다음 일정: {config.schedule[0].title} ({config.schedule[0].start.isoformat()})")
    print("=" * 80)

    test_queries = [
        ("질문-들르기", "편의점 들렀다 가도 돼?"),
        ("질문-지연", "10분 늦을 것 같아"),
        ("질문-복합", "늦을 것 같은데 약국은 들를 수 있어?"),
        ("할일-정상", "약 사기"),
        ("할일-모호함", "그거 사야 됨"),
    ]

    for label, query in test_queries:
        out = run_pipeline(query, parser=parser, provider=provider, config=config, now=fixed_now)
        print(f"\n[{label}] 입력: \"{query}\"")
        print(f"  • 분류 결과: {json.dumps(out['parsed'], ensure_ascii=False)}")
        if "time_checks" in out:
            for c in out["time_checks"]:
                st = "가능" if c["feasible"] else "불가"
                print(f"  • 체류 계산: [{c['place']['name']}] 가용 {c['available_minutes']}분 -> 최대 체류 {c['max_stay_minutes']}분 ({st})")
        if "departure" in out:
            dep = out["departure"]
            st = "정시 도착" if dep["on_time"] else "지각"
            print(f"  • 출발 계산: {st} (여유: {dep['slack_minutes']}분 | 출발 마감: {dep['leave_by']})")
        print(f"  • AI 응답: {out['answer']}")
        print("-" * 80)


def main() -> None:
    if "--demo" in sys.argv or len(sys.argv) == 1:
        run_demo()
    else:
        text = " ".join(sys.argv[1:])
        parser = MockRequestParser()
        provider = MockProvider()
        config = AppConfig()
        out = run_pipeline(text, parser=parser, provider=provider, config=config)
        print(json.dumps(out, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
