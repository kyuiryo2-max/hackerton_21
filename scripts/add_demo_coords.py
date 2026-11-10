"""시연 지도용 좌표를 data/demo/scenario.json에 넣어요.

1. 2115번 경로 선(route.path): data/samples/kakao_transit.json(11/5 카카오 실제 응답)에서 가져와요. 키 필요 없음
2. 정류장 좌표(route.stop_points): 경로 선에서 버스가 정류장에 들렀다 나오는 자리(같은 점이 두 번)로 정해요.
   SEOUL_OPEN_API_KEY가 있으면 서울시 정류소 좌표로 바꿔요 (같은 이름 중 경로 선에 가장 가까운 쪽)
3. 장소 좌표(places[].lng, lat): KAKAO_REST_API_KEY로 이름을 검색하고, 주소가 같은 곳을 써요.
   못 찾으면 주소를 좌표로 바꿔요

여러 번 실행해도 돼요. 파일의 줄 모양은 그대로 두고 좌표만 넣거나 바꿔요.
저장한 뒤 docs/design/api-examples/demo_context.json 예시도 실제 응답으로 바꿔요.

    cd server
    uv run python ../scripts/add_demo_coords.py          # 키가 있으면 전부, 없으면 1·2만
    uv run python ../scripts/add_demo_coords.py --check  # 바꾸지 않고 결과만 보기
"""
import argparse
import json
import math
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "server"))

from app import config  # noqa: E402
from app.services import kakao, seoul_bus  # noqa: E402

SCENARIO = ROOT / "data" / "demo" / "scenario.json"
SAMPLE = ROOT / "data" / "samples" / "kakao_transit.json"
EXAMPLE = ROOT / "docs" / "design" / "api-examples" / "demo_context.json"
POINTS_PER_LINE = 4
STOP_SEARCH_RADIUS_M = 150
PLACE_SEARCH_RADIUS_M = 1500


def meters(a: tuple[float, float], b: tuple[float, float]) -> float:
    """두 좌표(경도, 위도) 사이 거리(m). 짧은 거리라 평면으로 계산해요."""
    dx = (a[0] - b[0]) * 111_320 * math.cos(math.radians((a[1] + b[1]) / 2))
    dy = (a[1] - b[1]) * 110_540
    return math.hypot(dx, dy)


# ---------- 1. 경로 선 ----------
def route_path(route_name: str, guidance: str) -> list[list[float]]:
    data = json.loads(SAMPLE.read_text(encoding="utf-8"))
    for route in data["routes"]:
        for step in route["steps"]:
            if step["properties"].get("guidance") == guidance:
                return step["path"]["points"]
    raise SystemExit(f"{SAMPLE.name}에서 {route_name}번 경로({guidance})를 찾지 못했어요")


# ---------- 2. 정류장 ----------
def stop_indices(path: list[list[float]], count: int) -> list[int]:
    """처음 점, 같은 점이 연달아 나오는 자리(버스가 정류장에 들렀다 나옴), 마지막 점."""
    middle = [i for i in range(1, len(path)) if path[i] == path[i - 1]]
    indices = [0, *middle, len(path) - 1]
    if len(indices) != count:
        raise SystemExit(f"경로 선에서 정류장 {len(indices)}곳을 찾았는데 정류장 이름은 {count}개예요. 직접 확인해 주세요")
    return indices


def stop_points(names: list[str], path: list[list[float]]) -> list[dict]:
    points = []
    for name, i in zip(names, stop_indices(path, len(names))):
        lng, lat = path[i]
        points.append({"name": name, "lng": lng, "lat": lat, "source": "path"})
    if not config.SEOUL_OPEN_API_KEY:
        print("· SEOUL_OPEN_API_KEY 없음: 정류장은 경로 선 위치로 둬요")
        return points
    for p in points:
        here = (p["lng"], p["lat"])
        same = [s for s in seoul_bus.near_stops(here, STOP_SEARCH_RADIUS_M)
                if seoul_bus._norm(s["name"]) == seoul_bus._norm(p["name"])]
        if not same:
            print(f"· {p['name']}: 서울시 정류소를 못 찾아 경로 선 위치로 둬요")
            continue
        best = min(same, key=lambda s: meters(here, (s["lng"], s["lat"])))
        print(f"· {p['name']}: 서울시 정류소 {best['ars_id']} (경로 선과 {meters(here, (best['lng'], best['lat'])):.0f}m)")
        p.update(lng=best["lng"], lat=best["lat"], source="seoul_bus", ars_id=best["ars_id"])
    return points


# ---------- 3. 장소 ----------
def _same_address(a: str, b: str) -> bool:
    return a.replace(" ", "") == b.replace(" ", "")


def place_coord(place: dict, center: tuple[float, float]) -> tuple[float, float] | None:
    for found in kakao.search_places(center, keyword=place["name"], radius_m=PLACE_SEARCH_RADIUS_M, size=5):
        if _same_address(found["address"], place["address"]):
            return found["lng"], found["lat"]
    coord = kakao.geocode(place["address"])
    if coord:
        print(f"· {place['name']}: 이름 검색 결과에 같은 주소가 없어 주소 좌표를 써요")
    return coord


# ---------- 파일 고치기 (줄 모양 유지) ----------
def _fmt(v: float) -> str:
    return repr(round(v, 8))


def replace_route_block(text: str, path: list[list[float]], points: list[dict]) -> str:
    # 이미 넣은 path, stop_points는 지우고 다시 넣어요 (블록은 늘 앞에 쉼표를 달고 stops 바로 뒤에 있어요)
    text = re.sub(r',\n    "path": \[\n.*?\n    \]', "", text, flags=re.S)
    text = re.sub(r',\n    "stop_points": \[\n.*?\n    \]', "", text, flags=re.S)
    path_lines = []
    for i in range(0, len(path), POINTS_PER_LINE):
        chunk = ", ".join(f"[{_fmt(lng)}, {_fmt(lat)}]" for lng, lat in path[i:i + POINTS_PER_LINE])
        path_lines.append(f"      {chunk}")
    stop_lines = []
    for p in points:
        extra = f', "ars_id": "{p["ars_id"]}"' if p.get("ars_id") else ""
        stop_lines.append(
            f'      {{ "name": "{p["name"]}", "lng": {_fmt(p["lng"])}, "lat": {_fmt(p["lat"])}, '
            f'"source": "{p["source"]}"{extra} }}'
        )
    block = (
        ',\n    "path": [\n' + ",\n".join(path_lines) + "\n    ]"
        ',\n    "stop_points": [\n' + ",\n".join(stop_lines) + "\n    ]"
    )
    anchor = re.search(r'\n    "stops": \[[^\n]*\]', text)
    if not anchor:
        raise SystemExit("scenario.json의 route.stops 줄을 찾지 못했어요")
    return text[:anchor.end()] + block + text[anchor.end():]


def set_place_coord(text: str, name: str, coord: tuple[float, float]) -> str:
    pattern = re.compile(r'(\{ [^\n]*"name": "' + re.escape(name) + r'"[^\n]*?)(, "lng": [-\d.]+, "lat": [-\d.]+)?(, "round_trip_walk_seconds")')
    new, n = pattern.subn(lambda m: f'{m.group(1)}, "lng": {_fmt(coord[0])}, "lat": {_fmt(coord[1])}{m.group(3)}', text)
    if n != 1:
        raise SystemExit(f"scenario.json에서 장소 {name} 줄을 찾지 못했어요")
    return new


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="파일을 바꾸지 않고 결과만 보여 줘요")
    args = parser.parse_args()

    text = SCENARIO.read_text(encoding="utf-8")
    data = json.loads(text)
    route = data["route"]
    center = (data["location"]["lng"], data["location"]["lat"])

    path = route_path(route["name"], route["guidance"])
    points = stop_points(route["stops"], path)
    print(f"경로 선 {len(path)}점, 정류장 {len(points)}곳")
    text = replace_route_block(text, path, points)

    if config.KAKAO_REST_API_KEY:
        for place in data["places"]:
            coord = place_coord(place, center)
            if coord is None:
                raise SystemExit(f"{place['name']} ({place['address']}) 좌표를 찾지 못했어요")
            print(f"· {place['name']}: {coord[1]:.6f}, {coord[0]:.6f} (정류장에서 {meters(center, coord):.0f}m)")
            text = set_place_coord(text, place["name"], coord)
    else:
        print("· KAKAO_REST_API_KEY 없음: 장소 좌표는 넣지 않았어요")

    json.loads(text)  # 깨진 JSON을 저장하지 않게 확인
    if args.check:
        print("(--check) 파일은 바꾸지 않았어요")
        return
    SCENARIO.write_text(text, encoding="utf-8")
    print(f"저장: {SCENARIO.relative_to(ROOT)}")
    update_example()


def update_example() -> None:
    """docs/design/api-examples/demo_context.json 응답을 실제 서버 응답으로 바꿔요."""
    from app.routers.transit import demo_context

    doc = json.loads(EXAMPLE.read_text(encoding="utf-8"))
    doc["examples"][0]["response"]["body"] = demo_context()
    EXAMPLE.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"저장: {EXAMPLE.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
