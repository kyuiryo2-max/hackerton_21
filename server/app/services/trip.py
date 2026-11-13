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

from pydantic import BaseModel, Field

Phase = Literal["to_place", "at_place", "to_stop", "waiting", "riding", "arrived"]

PHASE_LABEL = {
    "to_place": "경유지로 가는 중",
    "at_place": "경유지에 있음",
    "to_stop": "정류장으로 가는 중",
    "waiting": "차 기다리는 중",
    "riding": "타고 가는 중",
    "arrived": "도착",
}

TRIP_INTENTS = {"time_left", "next_vehicle", "running_late"}


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
