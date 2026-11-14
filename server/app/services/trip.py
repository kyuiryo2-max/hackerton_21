"""이동 중 질문 답변 (11/13).

앱이 "이동 시작" 뒤에 질문하면 지금 어느 단계인지(가게로 가는 중, 가게에 있음, 정류장으로 가는 중,
차 기다리는 중, 타는 중, 도착)와 그 이동의 시각들을 함께 보내요. 여기서는 그 값으로만 답해요.
시각은 앱 코드가 계산한 값이고, 여기서도 뺄셈만 해요. AI는 질문 종류만 정하고 숫자는 만들지 않아요.

단계 기준으로 답하는 질문: 남은 시간(time_left), 다음 차(next_vehicle), 늦어짐(running_late).
나머지 질문은 원래 처리(실제 모드·시연 모드)를 그대로 써요.
"""
from __future__ import annotations

from datetime import datetime, timedelta
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

Phase = Literal["to_place", "at_place", "to_stop", "waiting", "riding", "arrived"]
StepKind = Literal["walk", "wait", "ride", "stay"]

PHASE_LABEL = {
    "to_place": "경유지로 가는 중",
    "at_place": "경유지에 있음",
    "to_stop": "정류장으로 가는 중",
    "waiting": "차 기다리는 중",
    "riding": "타고 가는 중",
    "arrived": "도착",
}

TRIP_INTENTS = {"time_left", "next_vehicle", "running_late"}


class TripStep(BaseModel):
    """상세 경로 한 구간 (v3). 앱이 경로 카드의 구간과 시각을 그대로 보내요.

    kind: walk(도보) / wait(대기) / ride(탑승) / stay(경유지 체류)
    """
    model_config = ConfigDict(populate_by_name=True)

    index: int = Field(ge=0)
    kind: StepKind
    start: datetime | None = None
    end: datetime | None = None
    minutes: int | None = Field(default=None, ge=0)
    # `from` 은 파이썬 예약어라 이름을 바꿔 받아요
    from_name: str | None = Field(default=None, alias="from")
    to: str | None = None
    at: str | None = None
    line: str | None = None


def step_label(step: TripStep) -> str:
    """사람이 읽는 구간 설명. AI context와 삽입 위치 답변에 같이 써요."""
    if step.kind == "walk":
        if step.from_name and step.to:
            return f"{step.from_name} → {step.to}"
        return step.to or step.from_name or "걷는 길"
    if step.kind == "wait":
        return f"{step.at}에서 대기" if step.at else "대기"
    if step.kind == "ride":
        line = f"{step.line} 탑승: " if step.line else "탑승: "
        if step.from_name and step.to:
            return f"{line}{step.from_name} → {step.to}"
        return line.rstrip(": ")
    if step.kind == "stay":
        return f"{step.at}에 머무는 중" if step.at else "경유지에 머무는 중"
    return f"{step.index}번 구간"


def _ro(word: str) -> str:
    """받침에 맞는 '으로/로' (예: 출구로, 정류장으로)."""
    last = word[-1] if word else ""
    has_final = "가" <= last <= "힣" and (ord(last) - ord("가")) % 28 > 0
    if last.isdigit():
        has_final = last in "013678"
    return f"{word}으로" if has_final else f"{word}로"


def _step_entry(step: TripStep, position: str, label: str, reason: str) -> dict:
    return {
        "step_index": step.index,
        "position": position,          # during | before | after | at
        "step_kind": step.kind,
        "step_label": step_label(step),
        "label": label,
        "reason": reason,
    }


def _same(a: str | None, b: str | None) -> bool:
    if not a or not b:
        return False
    a, b = a.strip(), b.strip()
    return a == b or a in b or b in a


def insert_at(place: dict, trip: TripIn) -> dict | None:
    """찾은 장소를 상세 경로 어디에 끼울지 정해요 (v3). 숫자는 앱이 보낸 steps 그대로예요.

    우선순위: 지금 경유지에 있음 → 이름이 맞는 구간 → 정류장으로 걷는 길 → 탑승 대기 → 탑승 전.
    steps가 없거나 이미 탔으면 None (기존 답변 문장 그대로).
    """
    steps = trip.steps
    if not steps or trip.phase in ("riding", "arrived"):
        return None
    name = (place or {}).get("name") or ""

    if trip.phase == "at_place":
        stay = next((s for s in steps if s.kind == "stay"), None)
        if stay is not None:
            where = stay.at or trip.place_name or name
            return _step_entry(stay, "at", f"{where}에 있는 동안", "지금 경유지에 머무는 중이에요")

    for step in steps:
        if name and any(_same(name, v) for v in (step.from_name, step.to, step.at)):
            return _step_entry(step, "during", f"{step_label(step)} 구간에", "찾은 장소가 그 구간에 있어요")

    if trip.phase == "waiting":
        wait = next((s for s in steps if s.kind == "wait"), None)
        if wait is not None:
            at = wait.at or trip.stop_name or name
            return _step_entry(wait, "at", f"{at}에서 기다리는 동안", "지금 탑승 대기 중이에요")

    walks = [s for s in steps if s.kind == "walk" and _same(s.to, trip.stop_name)]
    if walks:
        step = walks[-1]
        at = step.to or trip.stop_name
        return _step_entry(step, "during", f"{_ro(at)} 걷는 길에", "찾은 장소가 정류장까지 걷는 구간에 있어요")

    waits = [s for s in steps if s.kind == "wait"]
    if waits:
        step = waits[0]
        at = step.at or trip.stop_name or ""
        return _step_entry(step, "at", f"{at}에서 기다리는 동안", "찾은 장소가 탑승 정류장 근처에 있어요")

    before_ride = [s for s in steps if s.kind == "ride" and s.index > 0]
    if before_ride:
        step = steps[before_ride[0].index - 1]
        return _step_entry(step, "before", f"{step_label(step)} 뒤에", "탑승 전에 들를 수 있어요")
    return None


class TransferIn(BaseModel):
    """갈아타기 (11/14, 인터뷰 P1·P3: 환승하기 전에 근처에서 들르기).

    환승하러 가는 중·환승 대기 중이면 지금 갈아탈 곳, 첫 차를 타는 중이면 다음에 갈아탈 곳이에요.
    좌표는 갈아탈 정류장·역이에요 (사용자 위치 아님)."""
    get_off_name: str | None = Field(default=None, description="앞 차에서 내리는 곳")
    get_off_at: datetime | None = Field(default=None, description="앞 차에서 내리는 시각")
    stop_name: str | None = Field(default=None, description="갈아탈 정류장·역")
    lat: float  # 범위를 막지 않아요: 이상한 좌표 하나로 질문 전체가 422로 실패하지 않게 (장소를 못 찾을 뿐)
    lng: float
    reach_at: datetime | None = Field(default=None, description="갈아탈 곳에 걸어서 닿는 시각")
    board_at: datetime = Field(description="갈아탈 차 시각")
    ride_name: str | None = Field(default=None, description='"1호선", "273번"')


class TripIn(BaseModel):
    """이동 중 상황. 시각은 모두 ISO 8601 (+09:00)."""
    phase: Phase
    now: datetime = Field(description="앱 기준 지금 (시연 모드는 시연 시각 + 경과)")
    place_name: str | None = Field(default=None, description="들르는 곳 (경유가 없으면 비움)")
    leave_place_at: datetime | None = Field(default=None, description="경유지에서 늦어도 나올 시각")
    stop_name: str | None = None
    board_at: datetime | None = Field(default=None, description="탈 차 시각")
    ride_name: str | None = Field(default=None, description='"2115번", "2호선"')
    arrive_at: datetime | None = None
    destination: str | None = None
    next_vehicles_min: list[int] = Field(default_factory=list, description="탈 정류장에 곧 오는 차 (지금 기준 분)")
    # 상세 경로 (v3). 없으면 기존과 똑같이 동작해요
    steps: list[TripStep] = Field(default_factory=list, description="상세 경로 구간 (앱 경로 카드 순서)")
    current_step: int | None = Field(default=None, ge=0, description="지금 있는 steps index")
    transfer: TransferIn | None = Field(default=None, description="갈아타기 (11/14). 없으면 한 번에 가는 경로")


def _josa(word: str, pair: str) -> str:
    last = word[-1] if word else ""
    has_final = "가" <= last <= "힣" and (ord(last) - ord("가")) % 28 > 0
    if last.isdigit():  # "2115번"처럼 끝나지 않은 숫자: 받침 있는 숫자(0,1,3,6,7,8)
        has_final = last in "013678"
    return word + (pair[0] if has_final else pair[1])


def _hm(dt: datetime) -> str:
    return f"{dt.hour}시" if dt.minute == 0 else f"{dt.hour}시 {dt.minute}분"


def _minutes(until: datetime | None, now: datetime) -> int | None:
    """지금부터 그 시각까지 남은 분 (지났으면 0, 내림)"""
    if until is None:
        return None
    return max(int((until - now).total_seconds() // 60), 0)


def _ride(trip: TripIn) -> str:
    return trip.ride_name or "탈 차"


def _time_left(trip: TripIn) -> tuple[dict, str]:
    now, ride = trip.now, _ride(trip)
    result = {"intent": "time_left", "phase": trip.phase}
    if trip.phase in ("to_place", "at_place") and trip.place_name and trip.leave_place_at:
        m = _minutes(trip.leave_place_at, now)
        result.update(minutes=m, leave_place_at=trip.leave_place_at.isoformat())
        if trip.phase == "at_place":
            if m == 0:
                return result, f"지금 나가야 {_josa(ride, '을를')} 탈 수 있어요."
            return result, (f"{trip.place_name}에서 {m}분 더 있어도 돼요. "
                            f"{_hm(trip.leave_place_at)}에 나오면 {_josa(ride, '을를')} 탈 수 있어요.")
        return result, (f"{trip.place_name}에 들렀다가 {_hm(trip.leave_place_at)}까지 나오면 돼요. "
                        f"지금부터 {m}분 남았어요.")
    if trip.phase in ("to_place", "at_place", "to_stop", "waiting") and trip.board_at:
        m = _minutes(trip.board_at, now)
        result.update(minutes=m, board_at=trip.board_at.isoformat())
        where = f"{trip.stop_name}에서 " if trip.stop_name else ""
        return result, f"{where}{_hm(trip.board_at)}에 {_josa(ride, '을를')} 타요. {m}분 남았어요."
    if trip.phase == "riding" and trip.arrive_at:
        m = _minutes(trip.arrive_at, now)
        result.update(minutes=m, arrive_at=trip.arrive_at.isoformat())
        dest = trip.destination or "목적지"
        return result, f"{dest}에 {_hm(trip.arrive_at)} 도착 예정이에요. {m}분 남았어요."
    if trip.phase == "arrived":
        return result, f"{trip.destination or '목적지'}에 도착했어요."
    return result, "지금 이동 시각을 알 수 없어요. 경로를 새로고침해 주세요."


def _next_vehicle(trip: TripIn) -> tuple[dict, str]:
    now, ride = trip.now, _ride(trip)
    result = {"intent": "next_vehicle", "phase": trip.phase}
    if trip.phase in ("riding", "arrived"):
        if trip.arrive_at is None:
            return result, f"이미 {_josa(ride, '을를')} 탔어요."
        result["arrive_at"] = trip.arrive_at.isoformat()
        return result, f"이미 {_josa(ride, '을를')} 탔어요. {_hm(trip.arrive_at)} 도착 예정이에요."
    soon = sorted(m for m in trip.next_vehicles_min if m >= 0)
    if soon:
        result.update(minutes=soon[0], next_minutes=soon[1] if len(soon) > 1 else None)
        if len(soon) > 1:
            return result, f"{_josa(ride, '이가')} {soon[0]}분 뒤에 와요. 그다음 차는 {soon[1]}분 뒤예요."
        return result, f"{_josa(ride, '이가')} {soon[0]}분 뒤에 와요."
    if trip.board_at:
        m = _minutes(trip.board_at, now)
        result.update(minutes=m, board_at=trip.board_at.isoformat())
        return result, f"{_josa(ride, '을를')} {_hm(trip.board_at)}에 타요. {m}분 남았어요."
    return result, "다음 차 시각을 알 수 없어요. 경로를 새로고침해 주세요."


def _running_late(trip: TripIn, delay: int | None) -> tuple[dict, str]:
    now, ride = trip.now, _ride(trip)
    result = {"intent": "running_late", "phase": trip.phase, "delay_minutes": delay}
    if delay is None:
        return result, "몇 분 늦을 것 같은지 알려 주세요."
    if trip.phase in ("riding", "arrived"):
        arrive = f" 도착은 {_hm(trip.arrive_at)} 그대로예요." if trip.arrive_at else ""
        return result, f"이미 {_josa(ride, '을를')} 탔어요.{arrive}"
    at_place = trip.phase in ("to_place", "at_place") and trip.place_name and trip.leave_place_at
    deadline = trip.leave_place_at if at_place else trip.board_at
    if deadline is None:
        return result, "지금 이동 시각을 알 수 없어요. 경로를 새로고침해 주세요."
    slack = _minutes(deadline, now)
    on_time = delay <= slack
    result.update(slack_minutes=slack, on_time=on_time)
    if on_time:
        if at_place:
            return result, (f"{delay}분 늦어도 괜찮아요. {_hm(deadline)}까지만 {trip.place_name}에서 나오면 "
                            f"{_josa(ride, '을를')} 탈 수 있어요.")
        return result, f"{delay}분 늦어도 {_hm(deadline)} {_josa(ride, '을를')} 탈 수 있어요."
    later = [m for m in trip.next_vehicles_min if m >= slack + delay]
    if at_place:
        return result, (f"{delay}분 늦으면 {_hm(trip.board_at or deadline)} {_josa(ride, '을를')} 놓쳐요. "
                        f"{_josa(trip.place_name, '은는')} 빼고 바로 정류장으로 가는 걸 추천해요.")
    tail = f" 다음 차는 {later[0]}분 뒤예요." if later else " 경로를 새로고침해서 다음 차를 확인해 주세요."
    return result, f"{delay}분 늦으면 {_hm(deadline)} {_josa(ride, '을를')} 놓쳐요.{tail}"


MISSED_WORDS = ("놓쳤", "놓침", "놓쳐버", "못 탔", "못탔")


def _missed(trip: TripIn, name: str) -> tuple[dict, str]:
    """ "버스 놓쳤어": 타려던 차 다음 차를 알려 줘요 (11/13)."""
    ride = _ride(trip)
    board_in = _minutes(trip.board_at, trip.now) if trip.board_at else 0
    later = [m for m in sorted(trip.next_vehicles_min) if m > board_in]
    result = {"intent": name, "phase": trip.phase, "missed": True}
    if not later:
        return result, f"{_josa(ride, '을를')} 놓쳤다면 경로를 새로고침해서 다음 차를 확인해 주세요."
    nxt = later[0]
    at = trip.now + timedelta(minutes=nxt)
    result.update(minutes=nxt)
    return result, f"{_josa(ride, '을를')} 놓쳤으면 다음 차는 {nxt}분 뒤({_hm(at)})에 와요."


def answer(intent: dict, trip: TripIn, text: str = "") -> tuple[dict, str] | None:
    """이동 중 단계로 답할 수 있는 질문이면 (결과, 답변), 아니면 None (원래 처리)."""
    name = intent["intent"]
    # "버스 놓쳤어"는 남은 시간·다음 차·늦어짐 어느 것으로 분류돼도 다음 차를 알려 줘요
    # AI가 범위 밖(unsupported)으로 잘못 고른 경우도 이동 중이면 받아 줘요
    if ((name in TRIP_INTENTS or name == "unsupported") and trip.phase not in ("riding", "arrived")
            and any(w in text for w in MISSED_WORDS)):
        return _missed(trip, name)
    if name == "time_left":
        return _time_left(trip)
    if name == "next_vehicle":
        return _next_vehicle(trip)
    if name == "running_late":
        return _running_late(trip, intent.get("delay_minutes"))
    return None
