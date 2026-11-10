"""시연 모드 테스트 (할 일 30번). 시연 대본의 숫자가 깨지지 않게 지켜요."""
from datetime import datetime, timedelta, timezone

import httpx
import pytest
from fastapi.testclient import TestClient

from app.services import demo
from app.services.timecalc import wait_minutes_from_seconds

STOP = demo.scenario()["stop"]["ars_id"]


@pytest.fixture()
def client(tmp_path, monkeypatch):
    monkeypatch.setattr("app.config.DATABASE_PATH", str(tmp_path / "test.db"))
    from app.main import app

    with TestClient(app) as c:
        yield c


def statuses(result) -> dict:
    return {d.todo_id: d.status for d in result.decisions}


# ---------- 고정 값 ----------
def test_시각과_위치가_고정():
    assert demo.current_time() == datetime(2026, 11, 21, 8, 32, tzinfo=timezone(timedelta(hours=9)))
    assert demo.current_location() == (127.03045087, 37.58624821)


def test_호출할_때마다_같은_결과():
    assert demo.decide([1]) == demo.decide([1])


def test_시연은_외부_API를_부르지_않음(monkeypatch):
    def blocked(*args, **kwargs):
        raise AssertionError("외부 호출 금지")

    monkeypatch.setattr(httpx.Client, "send", blocked)
    assert demo.arrivals(STOP)
    assert demo.decide([1, 2, 3]).decisions


# ---------- 시연 대본 ----------
def test_대본_버스까지_12분_편의점_최대_6분():
    result = demo.decide([1])
    assert statuses(result) == {1: "included"}
    assert wait_minutes_from_seconds(result.board_seconds) == 12
    assert wait_minutes_from_seconds(result.max_stay_seconds) == 6


def test_대본_편의점에_들러도_9시_전_도착():
    result = demo.decide([1])
    arrive_at = demo.current_time(result.total_seconds)
    assert arrive_at < datetime.fromisoformat(demo.scenario()["schedule"]["arrive_by"])


def test_대본_카페는_선택이라_제외():
    assert statuses(demo.decide([1, 2])) == {1: "included", 2: "excluded"}


def test_대본_다이소는_필수라_물어봄():
    result = demo.decide([1, 3])
    assert statuses(result) == {1: "included", 3: "ask"}
    assert result.decisions[1].reason == "시간이 부족해요"


def test_대본_경유_없이도_다음_버스는_지각():
    vehicles = demo.route_timing().vehicle_seconds
    after_board = demo.route_timing().moving_seconds + demo.route_timing().last_walk_seconds
    assert vehicles[0] + after_board <= demo.deadline_seconds()
    assert vehicles[1] + after_board > demo.deadline_seconds()


def test_시간이_지나면_남은_시간이_줄어듦():
    assert demo.arrivals(STOP, 60)[0]["first_seconds"] == 660
    assert demo.deadline_seconds(60) == demo.deadline_seconds() - 60


def test_지나간_차는_빠지고_다음_차가_첫_차():
    arrival = demo.arrivals(STOP, 800)[0]
    assert arrival["first_seconds"] == 400
    assert arrival["second_seconds"] is None


def test_다른_정류소는_빈_목록():
    assert demo.arrivals("00000") == []


def test_장소_도보_시간은_양수():
    assert all(p["round_trip_walk_seconds"] > 0 for p in demo.scenario()["places"])


def test_장소는_허용_목록_안의_종류():
    from app.services.llm import place_types

    assert {p["place_type"] for p in demo.scenario()["places"]} <= set(place_types())


def test_설문_1위_편의점이_대표_장면():
    first = demo.scenario()["places"][0]
    assert (first["place_type"], first["importance"]) == ("편의점", "필수")


# ---------- API ----------
def test_도착_API_시연_모드(client):
    res = client.get("/api/arrivals", params={"stop_id": STOP, "demo": True})
    assert res.status_code == 200
    assert res.json()["arrivals"][0] == {
        "route": "2115", "minutes": 12, "next_minutes": 20, "direction": "중랑공영차고지",
    }


def test_도착_API_시간_경과(client):
    res = client.get("/api/arrivals", params={"stop_id": STOP, "demo": True, "elapsed_seconds": 600})
    assert res.json()["arrivals"][0]["minutes"] == 2


def test_도착_API_시연은_실시간_키가_없어도_동작(client, monkeypatch):
    monkeypatch.setattr("app.config.DATA_GO_KR_SERVICE_KEY", "")
    res = client.get("/api/arrivals", params={"stop_id": STOP, "demo": True})
    assert res.status_code == 200


def test_시연_정보_API(client):
    data = client.get("/api/demo/context").json()
    assert data["now"] == "2026-11-21T08:32:00+09:00"
    assert data["stop"]["ars_id"] == STOP
    assert data["schedule"]["destination"]["name"] == "청량리역"


def _meters(a, b) -> float:
    """두 좌표(경도, 위도) 사이 대략 거리(m)."""
    dx = (a[0] - b[0]) * 88_000  # 서울 위도에서 경도 1도 ≈ 88km
    dy = (a[1] - b[1]) * 110_540
    return (dx * dx + dy * dy) ** 0.5


def test_지도용_경로_선은_출발_정류장에서_도착_정류장까지():
    data = demo.scenario()
    path, location = data["route"]["path"], data["location"]
    assert len(path) >= 2
    assert all(len(p) == 2 and 126 < p[0] < 128 and 37 < p[1] < 38 for p in path)  # [경도, 위도]
    assert _meters(path[0], (location["lng"], location["lat"])) < 50
    destination = data["schedule"]["destination"]
    # 하차 후 도보 120초 거리 안
    assert _meters(path[-1], (destination["lng"], destination["lat"])) < 300


def test_지도용_정류장은_경로_순서대로_경로_선_근처():
    route = demo.scenario()["route"]
    points = route["stop_points"]
    assert [p["name"] for p in points] == route["stops"]
    for p in points:
        nearest = min(_meters((p["lng"], p["lat"]), q) for q in route["path"])
        assert nearest < 50, f"{p['name']} 정류장이 경로 선에서 {nearest:.0f}m 떨어져 있어요"


def test_지도용_장소_좌표는_출발_정류장_근처():
    data = demo.scenario()
    here = (data["location"]["lng"], data["location"]["lat"])
    for p in data["places"]:
        assert p.get("lng") and p.get("lat"), f"{p['name']} 좌표가 없어요. scripts/add_demo_coords.py 를 실행해 주세요"
        # 왕복 도보가 가장 긴 다이소도 690초라 1km 안이에요
        assert _meters((p["lng"], p["lat"]), here) < 1000


def test_시연_정보_API에_지도_좌표가_있음(client):
    data = client.get("/api/demo/context").json()
    assert data["route"]["path"][0] == demo.scenario()["route"]["path"][0]
    assert [p["name"] for p in data["route"]["stop_points"]] == data["route"]["stops"]
    assert [p["todo"] for p in data["places"]] == ["이어폰 사기", "커피 사기", "다이소 들르기"]
    assert all({"lng", "lat"} <= p.keys() for p in data["places"])
