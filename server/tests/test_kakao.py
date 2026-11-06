import json
from pathlib import Path

import httpx
import pytest

from app import config
from app.services import kakao
from app.services.timecalc import route_total_seconds

START = (127.02934, 37.58631)
END = (127.04691, 37.58029)

TRANSIT = {
    "status": "OK",
    "routes": [
        {
            "properties": {
                "type": "BUS",
                "totalTime": 1035,
                "transfers": 0,
                "fare": {"value": 1500},
            },
            "steps": [
                {
                    "properties": {
                        "type": "BUS",
                        "time": 797,
                        "guidance": "지선 2115 (안암역3번출구 > 청량리역환승센터)",
                        "stops": [{"name": "안암역3번출구"}, {"name": "제기시장"}],
                        "vehicles": [{"name": "2115", "type": "지선"}],
                    },
                    "path": {"points": [[127.03045087, 37.58624821]]},
                }
            ],
        },
        {
            "properties": {
                "type": "BUS",
                "totalTime": 1305,
                "transfers": 1,
                "fare": {"min": 1500, "max": 2500},
            },
            "steps": [],
        },
    ],
}
WALK = {"status": "OK", "route": {"properties": {"totalTime": 2208}}}


@pytest.fixture
def api(monkeypatch):
    """외부 호출 없이 응답을 정해 두고, 호출 기록을 남겨요."""
    calls = []
    responses = {}

    def handler(request):
        calls.append(request)
        return responses[request.url.path](request)

    monkeypatch.setattr(config, "KAKAO_REST_API_KEY", "TEST-KEY")
    monkeypatch.setattr(kakao, "_client", lambda: httpx.Client(transport=httpx.MockTransport(handler)))
    kakao.clear_cache()
    yield calls, responses
    kakao.clear_cache()


def reply(body, status=200):
    return lambda _: httpx.Response(status, json=body)


def test_주소를_좌표로_변환(api):
    calls, responses = api
    responses["/v2/local/search/address.json"] = reply({"documents": [{"x": "127.03", "y": "37.58"}]})
    assert kakao.geocode("서울 성북구 안암로 145") == (127.03, 37.58)
    assert calls[0].headers["Authorization"] == "KakaoAK TEST-KEY"


def test_없는_주소는_None(api):
    _, responses = api
    responses["/v2/local/search/address.json"] = reply({"documents": []})
    assert kakao.geocode("없는 주소") is None


def test_카테고리로_장소_검색(api):
    calls, responses = api
    responses["/v2/local/search/category.json"] = reply({"documents": [{
        "place_name": "대학약국", "road_address_name": "서울 성북구 고려대로 89",
        "x": "127.0291", "y": "37.5864", "distance": "18",
    }]})
    places = kakao.search_places(START, category="PM9")
    assert places[0]["name"] == "대학약국"
    assert places[0]["distance_m"] == 18
    assert calls[0].url.params["sort"] == "distance"


def test_키워드로_장소_검색(api):
    calls, responses = api
    responses["/v2/local/search/keyword.json"] = reply({"documents": []})
    assert kakao.search_places(START, keyword="꽃집") == []
    assert calls[0].url.params["query"] == "꽃집"


def test_장소_검색은_키워드나_카테고리_중_하나만():
    with pytest.raises(ValueError):
        kakao.search_places(START)
    with pytest.raises(ValueError):
        kakao.search_places(START, keyword="꽃집", category="PM9")


def test_대중교통_응답_정리():
    routes = kakao.parse_transit(TRANSIT)
    assert routes[0]["moving_seconds"] == 797
    assert routes[0]["kakao_total_seconds"] == 1035
    assert routes[0]["legs"][0]["stops"][0] == "안암역3번출구"
    assert routes[0]["legs"][0]["vehicles"] == ["2115"]
    assert routes[0]["legs"][0]["start"] == (127.03045087, 37.58624821)
    assert routes[0]["legs"][0]["end"] == (127.03045087, 37.58624821)


def test_실제_응답의_총_시간은_구간_합과_앞뒤_도보로_계산():
    sample = Path(__file__).resolve().parents[2] / "data" / "samples" / "kakao_transit.json"
    route = kakao.parse_transit(json.loads(sample.read_text(encoding="utf-8")))[0]
    # 2115번 버스 구간 797초, 처음 도보 118초, 마지막 도보 119초 (실제 도보 API 값)
    assert route["moving_seconds"] == 797
    assert route_total_seconds(route["moving_seconds"], 118, 119, 0) == 1034
    # 실시간 대기 5분을 더하면 카카오 totalTime보다 길어요
    assert route_total_seconds(route["moving_seconds"], 118, 119, 300) > route["kakao_total_seconds"]


def test_요금은_두_가지_형식을_처리():
    routes = kakao.parse_transit(TRANSIT)
    assert (routes[0]["fare_min"], routes[0]["fare_max"]) == (1500, 1500)
    assert (routes[1]["fare_min"], routes[1]["fare_max"]) == (1500, 2500)


def test_같은_구간은_한_번만_호출(api):
    calls, responses = api
    responses["/v2/routing/publictraffic"] = reply(TRANSIT)
    first = kakao.transit_routes(START, END)
    second = kakao.transit_routes(START, END)
    assert first == second
    assert len(calls) == 1


def test_10m_안쪽_차이는_같은_구간(api):
    calls, responses = api
    responses["/v2/routing/walk"] = reply(WALK)
    kakao.walk_seconds((127.02934, 37.58631), END)
    kakao.walk_seconds((127.02932, 37.58629), END)
    assert len(calls) == 1


def test_다른_구간은_따로_호출(api):
    calls, responses = api
    responses["/v2/routing/walk"] = reply(WALK)
    kakao.walk_seconds(START, END)
    kakao.walk_seconds(END, START)
    assert len(calls) == 2


def test_대중교통과_도보는_저장_공간이_다름(api):
    calls, responses = api
    responses["/v2/routing/publictraffic"] = reply(TRANSIT)
    responses["/v2/routing/walk"] = reply(WALK)
    kakao.transit_routes(START, END)
    assert kakao.walk_seconds(START, END) == 2208
    assert len(calls) == 2


def test_저장_시간이_지나면_다시_호출(api, monkeypatch):
    calls, responses = api
    responses["/v2/routing/publictraffic"] = reply(TRANSIT)
    now = [1000.0]
    monkeypatch.setattr(kakao.time, "monotonic", lambda: now[0])
    kakao.transit_routes(START, END)
    now[0] += kakao.TRANSIT_TTL_SECONDS
    kakao.transit_routes(START, END)
    assert len(calls) == 2


def test_경로가_없는_결과는_저장하지_않음(api):
    calls, responses = api
    responses["/v2/routing/publictraffic"] = reply({"status": "NO_RESULTS"})
    assert kakao.transit_routes(START, END) == []
    assert kakao.transit_routes(START, END) == []
    assert len(calls) == 2


def test_도보_경로가_없으면_None(api):
    _, responses = api
    responses["/v2/routing/walk"] = reply({"status": "TOO_FAR_AWAY"})
    assert kakao.walk_seconds(START, END) is None


def test_출발과_도착이_같으면_호출_없이_0(api):
    calls, _ = api
    assert kakao.walk_seconds(START, START) == 0
    assert calls == []


def test_왕복_도보는_성공하면_재시도하지_않음(api):
    calls, responses = api
    responses["/v2/routing/walk"] = reply(WALK)
    assert kakao.walk_seconds(START, START, via=[END]) == 2208
    assert len(calls) == 1


def test_왕복_도보가_실패하면_도착을_옮겨_재시도(api):
    calls, responses = api
    answers = [{"status": "SAME_POINT"}, WALK]
    responses["/v2/routing/walk"] = lambda _: httpx.Response(200, json=answers.pop(0))
    assert kakao.walk_seconds(START, START, via=[END]) == 2208
    assert len(calls) == 2
    assert calls[0].url.params["end_x"] != calls[1].url.params["end_x"]
    assert calls[0].url.params["end_y"] == calls[1].url.params["end_y"]


def test_왕복_재시도도_실패하면_None(api):
    calls, responses = api
    responses["/v2/routing/walk"] = reply({"status": "ROUTE_RESULT_NOT_FOUND"})
    assert kakao.walk_seconds(START, START, via=[END]) is None
    assert len(calls) == 2


def test_경유지는_쉼표로_전달(api):
    calls, responses = api
    responses["/v2/routing/walk"] = reply(WALK)
    kakao.walk_seconds(START, END, via=[(127.03, 37.58), (127.04, 37.59)])
    assert calls[0].url.params["via_x"] == "127.03,127.04"
    assert calls[0].url.params["via_y"] == "37.58,37.59"


def test_경유지는_5개까지():
    with pytest.raises(ValueError):
        kakao.walk_seconds(START, END, via=[START] * 6)


def test_호출_실패는_저장하지_않고_키를_숨김(api):
    calls, responses = api
    responses["/v2/routing/walk"] = reply({"code": -10}, status=429)
    with pytest.raises(kakao.KakaoError) as error:
        kakao.walk_seconds(START, END)
    assert "429" in str(error.value)
    assert "TEST-KEY" not in str(error.value)
    with pytest.raises(kakao.KakaoError):
        kakao.walk_seconds(START, END)
    assert len(calls) == 2


def test_저장_개수는_한도를_넘지_않음(api, monkeypatch):
    _, responses = api
    responses["/v2/routing/walk"] = reply(WALK)
    monkeypatch.setattr(kakao, "MAX_CACHE_SIZE", 2)
    for i in range(3):
        kakao.walk_seconds((127.0 + i, 37.5), END)
    assert len(kakao._cache) == 2
