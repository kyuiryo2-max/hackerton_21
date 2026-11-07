"""서울시 버스 도착 정리 테스트 (할 일 22번). 외부 호출 없이 data/samples 실제 응답으로 확인해요."""
import copy
import json
from pathlib import Path

import httpx
import pytest

from app import config
from app.services import kakao, seoul_bus

SAMPLES = Path(__file__).resolve().parents[2] / "data" / "samples"
NEAR = json.loads((SAMPLES / "seoul_bus_near_stops.json").read_text(encoding="utf-8"))
ARRIVALS = json.loads((SAMPLES / "seoul_bus_arrivals.json").read_text(encoding="utf-8"))
TRANSIT = json.loads((SAMPLES / "kakao_transit.json").read_text(encoding="utf-8"))
BUS_LEG = kakao.parse_transit(TRANSIT)[0]["legs"][0]  # 2115, 안암역3번출구 → 제기시장 → … 청량리역환승센터


def arrivals_for(ars_id: str, stop_name: str, next_stop: str) -> dict:
    """샘플 도착 응답을 다른 정류소(길 건너편 등)인 것처럼 바꿔요."""
    data = copy.deepcopy(ARRIVALS)
    for item in data["msgBody"]["itemList"]:
        item.update(arsId=ars_id, stNm=stop_name, nxtStn=next_stop)
    return data


# ---------- 응답 정리 ----------
def test_근처_정류소는_가까운_순():
    stops = seoul_bus.parse_near_stops(NEAR)
    assert stops[0] == {
        "ars_id": "08301", "station_id": "107000205", "name": "안암역3번출구",
        "lng": 127.0305239036, "lat": 37.586229248, "distance_m": 6,
    }
    distances = [s["distance_m"] for s in stops]
    assert distances == sorted(distances)


def test_도착은_문장이_아니라_traTime_초():
    by_route = {a["route"]: a for a in seoul_bus.parse_arrivals(ARRIVALS)}
    assert by_route["2115"]["first_seconds"] == 39       # "곧 도착"
    assert by_route["2115"]["second_seconds"] == 613     # "9분후[5번째 전]"
    assert by_route["273"]["first_seconds"] == 387       # "6분후[3번째 전]"
    assert by_route["2115"]["next_stop"] == "제기시장"
    assert by_route["2115"]["direction"] == "중랑공영차고지"
    assert by_route["2115"]["interval_minutes"] == 8


def test_운행종료_출발대기는_None():
    data = copy.deepcopy(ARRIVALS)
    item = data["msgBody"]["itemList"][0]
    item.update(traTime1="0", arrmsg1="운행종료", traTime2="0", arrmsg2="출발대기")
    first = seoul_bus.parse_arrivals(data)[0]
    assert first["first_seconds"] is None
    assert first["second_seconds"] is None


def test_곧_도착인데_초가_0이면_0초():
    data = copy.deepcopy(ARRIVALS)
    data["msgBody"]["itemList"][0].update(traTime1="0", arrmsg1="곧 도착")
    assert seoul_bus.parse_arrivals(data)[0]["first_seconds"] == 0


def test_막차_표시():
    data = copy.deepcopy(ARRIVALS)
    data["msgBody"]["itemList"][0]["isLast1"] = "1"
    assert seoul_bus.parse_arrivals(data)[0]["first_is_last"] is True


def test_결과_한_건이면_목록으로_감쌈():
    data = copy.deepcopy(ARRIVALS)
    data["msgBody"]["itemList"] = data["msgBody"]["itemList"][0]
    assert len(seoul_bus.parse_arrivals(data)) == 1


def test_결과_없음은_빈_목록():
    data = {"msgHeader": {"headerCd": "4", "headerMsg": "결과가 없습니다."}, "msgBody": {"itemList": None}}
    assert seoul_bus.parse_near_stops(data) == []


def test_오류_코드는_예외():
    data = {"msgHeader": {"headerCd": "7", "headerMsg": "인증 실패"}, "msgBody": {}}
    with pytest.raises(seoul_bus.SeoulBusError):
        seoul_bus.parse_arrivals(data)


# ---------- 정류소 고르기 ----------
def test_노선_번호로_정류소와_도착을_고름():
    stop = seoul_bus.parse_near_stops(NEAR)[0]
    found = seoul_bus.choose_stop([(stop, seoul_bus.parse_arrivals(ARRIVALS))], ["2115"], "제기시장")
    assert found["stop"]["ars_id"] == "08301"
    assert found["arrival"]["route"] == "2115"


def test_같은_이름_정류소는_다음_정류장으로_방향을_구분():
    """샘플에 실제로 있는 '우신향병원' 쌍(08157 160m, 06176 180m). 먼 쪽이 맞는 방향인 경우."""
    stops = [s for s in seoul_bus.parse_near_stops(NEAR) if s["name"] == "우신향병원"]
    assert [s["ars_id"] for s in stops] == ["08157", "06176"]
    near_side = seoul_bus.parse_arrivals(arrivals_for("08157", "우신향병원", "고려대학교앞"))
    far_side = seoul_bus.parse_arrivals(arrivals_for("06176", "우신향병원", "제기시장"))
    found = seoul_bus.choose_stop([(stops[0], near_side), (stops[1], far_side)], ["2115"], "제기시장")
    assert found["stop"]["ars_id"] == "06176"


def test_정류장_이름의_구분_기호는_무시():
    """카카오 '홍파초등학교.정화여중고' 와 서울시 '홍파초등학교·정화여중고' 처럼 기호만 다른 경우."""
    stops = [s for s in seoul_bus.parse_near_stops(NEAR) if s["name"] == "우신향병원"]
    a = seoul_bus.parse_arrivals(arrivals_for("08157", "우신향병원", "고려대학교앞"))
    b = seoul_bus.parse_arrivals(arrivals_for("06176", "우신향병원", "홍파초등학교·정화여중고"))
    found = seoul_bus.choose_stop([(stops[0], a), (stops[1], b)], ["2115"], ["홍파초등학교.정화여중고"])
    assert found["stop"]["ars_id"] == "06176"


def test_바로_다음이_아니어도_이후_정류장과_맞으면_그쪽():
    """카카오가 서울시보다 정류장 하나를 건너뛴 경우에도 방향을 맞춰요."""
    stops = [s for s in seoul_bus.parse_near_stops(NEAR) if s["name"] == "우신향병원"]
    a = seoul_bus.parse_arrivals(arrivals_for("08157", "우신향병원", "고려대학교앞"))
    b = seoul_bus.parse_arrivals(arrivals_for("06176", "우신향병원", "홍파초등학교.정화여중고"))
    later = BUS_LEG["stops"][1:]  # 제기시장, 홍파초등학교.정화여중고, …
    found = seoul_bus.choose_stop([(stops[0], a), (stops[1], b)], ["2115"], later)
    assert found["stop"]["ars_id"] == "06176"


def test_방향을_모르면_가까운_정류소():
    stops = [s for s in seoul_bus.parse_near_stops(NEAR) if s["name"] == "우신향병원"]
    a = seoul_bus.parse_arrivals(arrivals_for("08157", "우신향병원", "고려대학교앞"))
    b = seoul_bus.parse_arrivals(arrivals_for("06176", "우신향병원", "제기시장"))
    found = seoul_bus.choose_stop([(stops[0], a), (stops[1], b)], ["2115"], None)
    assert found["stop"]["ars_id"] == "08157"


def test_노선이_없으면_None():
    stop = seoul_bus.parse_near_stops(NEAR)[0]
    assert seoul_bus.choose_stop([(stop, seoul_bus.parse_arrivals(ARRIVALS))], ["101"]) is None


# ---------- 외부 호출 (가짜 서버) ----------
@pytest.fixture
def api(monkeypatch):
    calls = []
    responses = {}

    def handler(request):
        calls.append(request)
        return responses[request.url.path](request)

    monkeypatch.setattr(config, "DATA_GO_KR_SERVICE_KEY", "TEST-KEY")
    monkeypatch.setattr(seoul_bus, "_client", lambda: httpx.Client(transport=httpx.MockTransport(handler)))
    seoul_bus.clear_cache()
    yield calls, responses
    seoul_bus.clear_cache()


def reply(body, status=200):
    return lambda _: httpx.Response(status, json=body)


def test_카카오_버스_구간으로_정류소_번호와_도착을_찾음(api):
    calls, responses = api
    responses["/api/rest/stationinfo/getStationByPos"] = reply(NEAR)
    responses["/api/rest/stationinfo/getStationByUid"] = reply(ARRIVALS)
    found = seoul_bus.match_leg(BUS_LEG)
    assert found["stop"]["ars_id"] == "08301"
    assert found["arrival"]["route"] == "2115"
    assert found["arrival"]["first_seconds"] == 39
    assert calls[0].url.params["resultType"] == "json"
    assert calls[0].url.params["serviceKey"] == "TEST-KEY"
    assert calls[1].url.params["arsId"] == "08301"
    assert len(calls) == 2  # 같은 이름 정류소가 하나라 도착 조회는 1번


def test_같은_요청은_다시_부르지_않음(api):
    calls, responses = api
    responses["/api/rest/stationinfo/getStationByPos"] = reply(NEAR)
    responses["/api/rest/stationinfo/getStationByUid"] = reply(ARRIVALS)
    seoul_bus.match_leg(BUS_LEG)
    seoul_bus.match_leg(BUS_LEG)
    assert len(calls) == 2


def test_버스가_아닌_구간은_None(api):
    walk = {**BUS_LEG, "type": "WALKING"}
    assert seoul_bus.match_leg(walk) is None


def test_키가_틀리면_XML이_와도_키를_드러내지_않음(api):
    _, responses = api
    responses["/api/rest/stationinfo/getStationByUid"] = lambda _: httpx.Response(
        200, text="<OpenAPI_ServiceResponse><cmmMsgHeader>SERVICE_KEY_IS_NOT_REGISTERED_ERROR</cmmMsgHeader>"
    )
    with pytest.raises(seoul_bus.SeoulBusError) as e:
        seoul_bus.arrivals("08301")
    assert "TEST-KEY" not in str(e.value)


def test_HTTP_오류(api):
    _, responses = api
    responses["/api/rest/stationinfo/getStationByUid"] = reply({}, status=500)
    with pytest.raises(seoul_bus.SeoulBusError):
        seoul_bus.arrivals("08301")
