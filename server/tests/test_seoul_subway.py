"""서울 지하철 도착 정리 테스트 (할 일 23번). 외부 호출 없이 실제 응답 형식으로 확인해요."""
import json
from datetime import datetime, timedelta
from pathlib import Path

import httpx
import pytest

from app import config
from app.services import kakao, seoul_subway as subway

SAMPLE = Path(__file__).resolve().parents[2] / "data" / "samples" / "seoul_subway.json"
NOW = datetime(2026, 11, 7, 13, 40, 0, tzinfo=subway.KST)


def item(**fields) -> dict:
    base = {
        "subwayId": "1006", "updnLine": "상행", "trainLineNm": "응암순환(상선)행 - 보문방면",
        "bstatnNm": "응암순환(상선)", "barvlDt": "180", "arvlCd": "99", "arvlMsg2": "3분 후 (창신)",
        "recptnDt": "2026-11-07 13:40:00", "btrainNo": "6118", "btrainSttus": "일반", "lstcarAt": "0",
    }
    return {**base, **fields}


def parse(*items) -> list[dict]:
    return subway.parse_arrivals({"realtimeArrivalList": list(items)}, NOW)


@pytest.fixture
def api(monkeypatch):
    calls = []
    responses = {}

    def handler(request):
        calls.append(request)
        name = request.url.path.rsplit("/", 1)[-1]
        return httpx.Response(200, json=responses.get(name, {"code": "INFO-200"}))

    monkeypatch.setattr(config, "SEOUL_OPEN_API_KEY", "TEST-KEY")
    monkeypatch.setattr(subway, "_client", lambda: httpx.Client(transport=httpx.MockTransport(handler)))
    subway.clear_cache()
    yield calls, responses
    subway.clear_cache()


# ---------- 남은 시간 ----------
def test_실시간_초를_그대로_사용():
    train = parse(item())[0]
    assert train["seconds"] == 180
    assert train["estimated"] is False
    assert train["line"] == "6호선"
    assert train["direction"] == "보문"


def test_barvlDt가_0이어도_곧_도착이_아님():
    train = parse(item(barvlDt="0", arvlMsg2="[5]번째 전역 (용산)"))[0]
    assert train["seconds"] == 600
    assert train["estimated"] is True


def test_도착_코드로_대략_계산():
    assert parse(item(barvlDt="0", arvlCd="5", arvlMsg2="전역 도착"))[0]["seconds"] == 120
    assert parse(item(barvlDt="0", arvlCd="0", arvlMsg2="안암 진입"))[0]["seconds"] == 30


def test_도착한_차는_0초이고_추정이_아님():
    train = parse(item(barvlDt="0", arvlCd="1", arvlMsg2="안암 도착"))[0]
    assert train["seconds"] == 0
    assert train["estimated"] is False


def test_출발한_차는_제외():
    assert parse(item(barvlDt="0", arvlCd="2", arvlMsg2="안암 출발")) == []


def test_알_수_없는_형식은_제외():
    assert parse(item(barvlDt="0", arvlMsg2="운행 정보 없음")) == []


def test_지난_시간을_뺌():
    assert parse(item(recptnDt="2026-11-07 13:39:00"))[0]["seconds"] == 120


def test_오래된_도착_기록은_이미_떠난_차():
    old = (NOW - timedelta(minutes=4)).strftime("%Y-%m-%d %H:%M:%S")
    assert parse(item(barvlDt="0", arvlCd="1", arvlMsg2="왕십리 도착", recptnDt=old)) == []


def test_몇_번째_전역은_오래돼도_남음():
    old = (NOW - timedelta(minutes=5)).strftime("%Y-%m-%d %H:%M:%S")
    assert parse(item(barvlDt="0", arvlMsg2="[23]번째 전역 (오리)", recptnDt=old))[0]["seconds"] == 2460


def test_수신_시각이_미래여도_더하지_않음():
    assert parse(item(recptnDt="2026-11-07 13:44:00"))[0]["seconds"] == 180


def test_같은_열차는_한_번만():
    trains = parse(item(), item())
    assert len(trains) == 1


def test_추정값이어도_빨리_오는_열차가_앞():
    trains = parse(
        item(btrainNo="1", barvlDt="0", arvlCd="5", arvlMsg2="전역 도착"),  # 약 120초
        item(btrainNo="2", barvlDt="240"),
    )
    assert [t["train_no"] for t in trains] == ["1", "2"]


def test_급행과_막차_표시():
    train = parse(item(trainLineNm="인천공항2터미널행 - 계양방면 (급행)", btrainSttus="급행", lstcarAt="1"))[0]
    assert train["direction"] == "계양"
    assert train["is_express"] is True
    assert train["is_last"] is True


# ---------- 방향 ----------
def test_다음_역이_같은_방향만_남김():
    trains = parse(
        item(btrainNo="1"),
        item(btrainNo="2", updnLine="하행", trainLineNm="신내행 - 고려대방면"),
    )
    chosen = subway.choose_trains(trains, ["6호선"], ["보문", "창신"])
    assert [t["train_no"] for t in chosen] == ["1"]


def test_괄호가_있는_다음_역도_같은_역():
    trains = parse(item(trainLineNm="신내행 - 고려대방면"))
    assert subway.choose_trains(trains, ["6호선"], ["고려대(종암)"]) != []


def test_방향을_모르면_고르지_않음():
    assert subway.choose_trains(parse(item()), ["6호선"], ["다른역"]) == []


def test_다른_호선은_제외():
    assert subway.choose_trains(parse(item()), ["1호선"], ["보문"]) == []


# ---------- 역명 ----------
@pytest.mark.parametrize("name, expected", [
    ("안암(고대병원앞)", ["안암(고대병원앞)", "안암"]),
    ("고려대(종암)", ["고려대(종암)", "고려대"]),
    ("서울역", ["서울역", "서울"]),
    ("역삼", ["역삼"]),
])
def test_역명_시도_순서(name, expected):
    assert subway.station_names(name) == expected


def test_없는_역명이면_다른_표기로_재시도(api):
    calls, responses = api
    responses["고려대"] = {"realtimeArrivalList": [item()]}
    assert len(subway.arrivals("고려대(종암)", NOW)) == 1
    assert len(calls) == 2


def test_같은_역은_잠시_저장(api):
    calls, responses = api
    responses["역삼"] = {"realtimeArrivalList": [item()]}
    subway.arrivals("역삼", NOW)
    subway.arrivals("역삼", NOW)
    assert len(calls) == 1


def test_저장값도_지금_시각으로_다시_계산(api):
    _, responses = api
    responses["역삼"] = {"realtimeArrivalList": [item()]}
    subway.arrivals("역삼", NOW)
    later = subway.arrivals("역삼", NOW + timedelta(seconds=10))
    assert later[0]["seconds"] == 170


def test_없는_역은_빈_목록(api):
    assert subway.arrivals("없는역", NOW) == []


# ---------- 카카오 구간 ----------
def test_카카오_지하철_구간으로_열차를_찾음(api):
    _, responses = api
    responses["안암(고대병원앞)"] = json.loads(
        SAMPLE.read_text(encoding="utf-8")
    )
    transit = json.loads((SAMPLE.parent / "kakao_transit.json").read_text(encoding="utf-8"))
    leg = next(
        leg for route in kakao.parse_transit(transit) for leg in route["legs"]
        if leg["type"] == "SUBWAY" and leg["stops"][:2] == ["안암(고대병원앞)", "보문"]
    )
    now = datetime(2026, 11, 5, 17, 8, 0, tzinfo=subway.KST)
    found = subway.match_leg(leg, now)
    assert found["station"] == "안암(고대병원앞)"
    assert {t["direction"] for t in found["trains"]} == {"보문"}


def test_첫_표기에_호선이_없으면_다음_표기까지_확인(api):
    calls, responses = api
    responses["서울역"] = {"realtimeArrivalList": [item(subwayId="1032", trainLineNm="운정중앙행 - 연신내방면")]}
    responses["서울"] = {"realtimeArrivalList": [item(subwayId="1001", trainLineNm="연천행 - 남영방면")]}
    leg = {"type": "SUBWAY", "stops": ["서울역", "남영"], "vehicles": ["1호선"]}
    assert subway.match_leg(leg, NOW)["trains"][0]["line"] == "1호선"
    assert len(calls) == 2


def test_방향_확인이_안_되면_None(api):
    _, responses = api
    responses["금정"] = {"realtimeArrivalList": [item(subwayId="1001", trainLineNm="신창행 - 군포방면")]}
    leg = {"type": "SUBWAY", "stops": ["금정", "성균관대"], "vehicles": ["1호선"]}
    assert subway.match_leg(leg, NOW) is None


def test_지하철이_아닌_구간은_None():
    assert subway.match_leg({"type": "BUS", "stops": ["안암"]}) is None


# ---------- 오류 ----------
def test_인증_오류는_예외이고_키를_숨김(api):
    _, responses = api
    responses["역삼"] = {"status": 500, "code": "INFO-100", "message": "인증키 오류"}
    with pytest.raises(subway.SeoulSubwayError) as error:
        subway.arrivals("역삼")
    assert "TEST-KEY" not in str(error.value)


def test_연결_실패에_주소를_드러내지_않음(monkeypatch):
    def handler(request):
        raise httpx.ConnectError(f"실패 {request.url}")

    monkeypatch.setattr(config, "SEOUL_OPEN_API_KEY", "TEST-KEY")
    monkeypatch.setattr(subway, "_client", lambda: httpx.Client(transport=httpx.MockTransport(handler)))
    subway.clear_cache()
    with pytest.raises(subway.SeoulSubwayError) as error:
        subway.arrivals("역삼")
    assert "TEST-KEY" not in str(error.value)
