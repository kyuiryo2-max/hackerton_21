"""외부 API 첫 호출 확인 (작업 표 5~8번).

호출 결과를 표로 보여 주고, 응답을 data/samples/ 에 저장해요.
키는 루트 .env 에서 읽고, 키가 없는 API는 건너뛰어요.

실행:
  cd server
  uv run python ../scripts/api_smoke.py
  uv run python ../scripts/api_smoke.py --start 127.0293,37.5863 --end 127.0469,37.5803 --station 안암
  (--start, --end 는 "경도,위도")
"""
import argparse
import json
import os
import sys
from pathlib import Path
from urllib.parse import quote

import httpx
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[1]
SAMPLES = ROOT / "data" / "samples"
TIMEOUT = 15

KAKAO = "https://dapi.kakao.com"
TAGO = "https://apis.data.go.kr/1613000"
SEOUL_BUS = "http://ws.bus.go.kr/api/rest"
SEOUL_SUBWAY = "http://swopenAPI.seoul.go.kr/api/subway"

results: list[tuple[str, str, str]] = []


def env(name: str) -> str:
    return os.getenv(name, "").strip()


def secrets() -> list[str]:
    names = ("DATA_GO_KR_SERVICE_KEY", "SEOUL_OPEN_API_KEY", "KAKAO_REST_API_KEY")
    values = [env(n) for n in names]
    return [v for v in values if v]


def scrub(text: str) -> str:
    """응답이나 오류 문장에 키가 섞여 있어도 저장·출력되지 않게 지워요."""
    for key in secrets():
        text = text.replace(key, "***").replace(quote(key, safe=""), "***")
    return text


def save(name: str, res: httpx.Response) -> None:
    is_json = "json" in res.headers.get("content-type", "") or res.text.lstrip()[:1] in "{["
    path = SAMPLES / f"{name}.{'json' if is_json else 'xml'}"
    path.write_text(scrub(res.text), encoding="utf-8")


def report(name: str, status: str, note: str = "") -> None:
    # call()에서 이미 기록한 항목을 또 쓰지 않아요
    if any(done == name for done, _, _ in results):
        return
    results.append((name, status, scrub(note)))


def call(name: str, client: httpx.Client, url: str, **kwargs) -> dict | None:
    """호출하고 저장해요. 실패해도 멈추지 않고, 오류 문장에 주소(키 포함)를 넣지 않아요."""
    try:
        res = client.get(url, timeout=TIMEOUT, **kwargs)
    except httpx.HTTPError as e:
        report(name, "실패", type(e).__name__)
        return None
    save(name, res)
    if res.status_code != 200:
        report(name, "실패", f"HTTP {res.status_code} {' '.join(res.text.split())[:120]}")
        return None
    try:
        return res.json()
    except ValueError:
        report(name, "확인 필요", "JSON이 아님, 저장 파일 확인")
        return None


def kakao_tests(client: httpx.Client, start: str, end: str) -> dict | None:
    key = env("KAKAO_REST_API_KEY")
    names = ("kakao_address", "kakao_pharmacy", "kakao_transit", "kakao_walk")
    if not key:
        for name in names:
            report(name, "건너뜀", "KAKAO_REST_API_KEY 없음")
        return None
    headers = {"Authorization": f"KakaoAK {key}"}
    sx, sy = start.split(",")
    ex, ey = end.split(",")

    data = call("kakao_address", client, f"{KAKAO}/v2/local/search/address.json",
                headers=headers, params={"query": "서울 성북구 안암로 145"})
    if data:
        report("kakao_address", "성공", f"결과 {len(data.get('documents', []))}건")

    data = call("kakao_pharmacy", client, f"{KAKAO}/v2/local/search/category.json",
                headers=headers,
                params={"category_group_code": "PM9", "x": sx, "y": sy, "radius": 500, "sort": "distance"})
    if data:
        report("kakao_pharmacy", "성공", f"약국 {len(data.get('documents', []))}건")

    route = {"start_x": sx, "start_y": sy, "end_x": ex, "end_y": ey}
    transit = call("kakao_transit", client, f"{KAKAO}/v2/routing/publictraffic",
                   headers=headers, params=route)
    if transit:
        routes = transit.get("routes", [])
        report("kakao_transit", "성공" if routes else "확인 필요",
               f"status={transit.get('status')}, 경로 {len(routes)}개")

    walk = call("kakao_walk", client, f"{KAKAO}/v2/routing/walk", headers=headers, params=route)
    if walk:
        total = walk.get("route", {}).get("properties", {}).get("totalTime")
        report("kakao_walk", "성공" if total is not None else "확인 필요",
               f"status={walk.get('status')}, totalTime={total}초")
    return transit


def first_bus_leg(transit: dict | None) -> tuple[float, float, str, list[str]] | None:
    """카카오 경로에서 첫 버스 구간의 (경도, 위도, 정류장명, 노선 번호들)을 꺼내요."""
    for route in (transit or {}).get("routes", []):
        for step in route.get("steps", []):
            prop = step.get("properties", {})
            points = step.get("path", {}).get("points", [])
            stops = prop.get("stops", [])
            if prop.get("type") == "BUS" and points and stops:
                lng, lat = points[0]
                vehicles = [v.get("name", "") for v in prop.get("vehicles", [])]
                return lng, lat, stops[0].get("name", ""), vehicles
    return None


def tago_items(data: dict | None) -> list[dict]:
    """TAGO 응답의 item을 항상 목록으로 바꿔요. (1건이면 객체, 0건이면 빈 문자열일 수 있어요)"""
    body = ((data or {}).get("response") or {}).get("body") or {}
    items = body.get("items")
    item = items.get("item") if isinstance(items, dict) else None
    if item is None:
        return []
    return item if isinstance(item, list) else [item]


def tago_tests(client: httpx.Client, lng: float, lat: float, leg_name: str, leg_routes: list[str]) -> None:
    key = env("DATA_GO_KR_SERVICE_KEY")
    if not key:
        report("tago", "건너뜀", "DATA_GO_KR_SERVICE_KEY 없음")
        return
    common = {"serviceKey": key, "_type": "json", "numOfRows": 300, "pageNo": 1}

    cities = tago_items(call("tago_cities", client,
                             f"{TAGO}/ArvlInfoInqireService/getCtyCodeList", params=common))
    seoul = [c for c in cities if "서울" in str(c.get("cityname"))]
    report("tago_cities", "성공" if cities else "확인 필요",
           f"도시 {len(cities)}개, 서울 {'있음' if seoul else '없음'}")

    params = {**common, "numOfRows": 20, "gpsLati": lat, "gpsLong": lng}
    stops = tago_items(call("tago_near_stops", client,
                            f"{TAGO}/BusSttnInfoInqireService/getCrdntPrxmtSttnList", params=params))
    report("tago_near_stops", "성공" if stops else "확인 필요", f"근처 정류소 {len(stops)}개")
    if not stops:
        return

    # 카카오 정류장명과 이름이 같은 곳을 먼저 시험해요 (맞은편 구분은 아직 안 해요)
    same_name = [s for s in stops if str(s.get("nodenm")) == leg_name]
    stop = (same_name or stops)[0]
    report("kakao↔tago 정류장", "성공" if same_name else "확인 필요",
           f"카카오 '{leg_name}' / TAGO '{stop.get('nodenm')}'")

    params = {**common, "numOfRows": 50, "cityCode": stop.get("citycode"), "nodeId": stop.get("nodeid")}
    arrivals = tago_items(call("tago_arrivals", client,
                               f"{TAGO}/ArvlInfoInqireService/getSttnAcctoArvlPrearngeInfoList",
                               params=params))
    report("tago_arrivals", "성공" if arrivals else "확인 필요", f"도착 정보 {len(arrivals)}건")

    wanted = [a for a in arrivals if str(a.get("routeno")) in leg_routes]
    if arrivals:
        report("kakao↔tago 노선", "성공" if wanted else "확인 필요",
               f"카카오 {leg_routes} 중 일치 {len(wanted)}건")
    if arrivals:
        params = {**common, "cityCode": stop.get("citycode"), "routeId": arrivals[0].get("routeid")}
        info = tago_items(call("tago_route_info", client,
                               f"{TAGO}/BusRouteInfoInqireService/getRouteInfoIem", params=params))
        has_interval = bool(info) and info[0].get("intervaltime") not in (None, "")
        report("tago_route_info", "성공" if has_interval else "확인 필요",
               f"배차 간격 {'있음' if has_interval else '없음'}")


def seoul_bus_tests(client: httpx.Client, lng: float, lat: float) -> None:
    key = env("DATA_GO_KR_SERVICE_KEY")
    if not key:
        report("seoul_bus", "건너뜀", "DATA_GO_KR_SERVICE_KEY 없음")
        return
    common = {"serviceKey": key, "resultType": "json"}
    params = {**common, "tmX": lng, "tmY": lat, "radius": 300}
    data = call("seoul_bus_near_stops", client, f"{SEOUL_BUS}/stationinfo/getStationByPos", params=params)
    stops = (data or {}).get("msgBody", {}).get("itemList") or []
    report("seoul_bus_near_stops", "성공" if stops else "확인 필요", f"근처 정류소 {len(stops)}개")
    if not stops:
        return
    params = {**common, "arsId": stops[0].get("arsId")}
    data = call("seoul_bus_arrivals", client, f"{SEOUL_BUS}/stationinfo/getStationByUid", params=params)
    items = (data or {}).get("msgBody", {}).get("itemList") or []
    report("seoul_bus_arrivals", "성공" if items else "확인 필요", f"도착 정보 {len(items)}건")


def seoul_subway_test(client: httpx.Client, station: str) -> None:
    key = env("SEOUL_OPEN_API_KEY")
    if not key:
        report("seoul_subway", "건너뜀", "SEOUL_OPEN_API_KEY 없음")
        return
    url = f"{SEOUL_SUBWAY}/{key}/json/realtimeStationArrival/0/5/{quote(station)}"
    data = call("seoul_subway", client, url)
    if data:
        items = data.get("realtimeArrivalList") or []
        if items:
            report("seoul_subway", "성공", f"도착 정보 {len(items)}건")
        elif str(data.get("code", "")).startswith("INFO-1"):
            report("seoul_subway", "실패", str(data.get("message", "인증 오류")))
        else:
            report("seoul_subway", "확인 필요", "도착 정보 0건")


def main() -> int:
    parser = argparse.ArgumentParser(description="외부 API 첫 호출 확인")
    parser.add_argument("--start", default="127.0293,37.5863", help="출발 경도,위도 (기본: 안암역 부근)")
    parser.add_argument("--end", default="127.0469,37.5803", help="도착 경도,위도 (기본: 청량리역 부근)")
    parser.add_argument("--station", default="안암", help="지하철 실시간 조회 역명")
    args = parser.parse_args()

    # Windows 콘솔에서 표시할 수 없는 문자가 있어도 멈추지 않게 해요
    sys.stdout.reconfigure(errors="replace")
    load_dotenv(ROOT / ".env")
    SAMPLES.mkdir(parents=True, exist_ok=True)

    with httpx.Client(follow_redirects=True) as client:
        transit = kakao_tests(client, args.start, args.end)
        leg = first_bus_leg(transit)
        if leg:
            lng, lat, name, routes = leg
            print(f"첫 버스 구간: {name} / 노선 {routes}")
        else:
            lng, lat = (float(v) for v in args.start.split(","))
            name, routes = "", []
            report("kakao 버스 구간", "확인 필요", "버스 구간이 없어 출발 좌표로 시험")
        tago_tests(client, lng, lat, name, routes)
        seoul_bus_tests(client, lng, lat)
        seoul_subway_test(client, args.station)

    print()
    for name, status, note in results:
        print(f"[{status}] {name}  {note}")
    print(f"\n응답 저장 위치: {SAMPLES}")
    print("커밋 전에 저장 파일에 개인 주소 같은 정보가 없는지 확인해 주세요.")
    return 1 if any(status == "실패" for _, status, _ in results) else 0


if __name__ == "__main__":
    sys.exit(main())
