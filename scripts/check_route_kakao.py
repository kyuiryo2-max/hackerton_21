"""실제 모드 경로 계산에서 카카오 API가 어디서 400을 내는지 하나씩 확인해요 (11/13 배포 오류 확인용).

서버가 /api/plan 을 계산할 때 부르는 순서 그대로 카카오를 직접 불러요.
  1) 목적지 검색      2) 대중교통 경로      3) 출발지 → 첫 정류장 도보
  4) 첫 정류장 근처 장소 검색 (할 일 후보)   5) 출발지 → 장소 → 정류장 경유 도보 (#45에서 새로 생긴 호출)
각 단계마다 [OK] 또는 [HTTP 400 (카카오가 보낸 이유)] 를 보여 줘요. 키 값은 출력하지 않아요.

실행 (루트 .env 에 KAKAO_REST_API_KEY 필요):
  cd server
  uv run python ../scripts/check_route_kakao.py 37.5665 126.9780 서울역
  uv run python ../scripts/check_route_kakao.py 37.5665 126.9780 서울역 --place 카페
  (순서: 출발 위도, 출발 경도, 목적지 이름. --place 는 할 일 장소 종류, 기본 '카페')

카카오는 하루 호출 한도를 다 써도 HTTP 400 으로 답해요. 이때 설명이 "API limit has been exceeded." 예요.
"""
import argparse
import sys
from pathlib import Path

import httpx

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "server"))

from app import config  # noqa: E402

BASE_URL = "https://dapi.kakao.com"


def call(name: str, path: str, params: dict) -> dict | None:
    """카카오를 한 번 불러 결과를 한 줄로 보여 줘요. 성공하면 응답, 실패하면 None."""
    headers = {"Authorization": f"KakaoAK {config.KAKAO_REST_API_KEY}"}
    try:
        res = httpx.get(f"{BASE_URL}{path}", headers=headers, params=params, timeout=10)
    except httpx.HTTPError as e:
        print(f"[연결 실패] {name}: {type(e).__name__}")
        return None
    if res.status_code != 200:
        try:
            body = res.json()
            why = body.get("msg") or body.get("message") or body.get("code") or ""
        except ValueError:
            why = res.text[:80]
        print(f"[HTTP {res.status_code}] {name}  ← 여기서 실패! 카카오 설명: {why}")
        if "limit" in str(why).lower():
            print("    → 오늘 호출 횟수를 다 쓴 거예요. 카카오 디벨로퍼스 > 내 애플리케이션 > 통계(또는 쿼터)에서 확인하세요.")
        return None
    data = res.json()
    status = data.get("status")
    if status is not None and status != "OK":
        print(f"[경로 없음] {name}: status={status}")
        return None
    print(f"[OK] {name}")
    return data


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("lat", type=float, help="출발 위도 (예: 37.5665)")
    p.add_argument("lng", type=float, help="출발 경도 (예: 126.9780)")
    p.add_argument("destination", help="목적지 이름 (예: 서울역)")
    p.add_argument("--place", default="카페", help="할 일 장소 종류 (기본: 카페)")
    args = p.parse_args()
    sys.stdout.reconfigure(errors="replace")

    if not config.KAKAO_REST_API_KEY:
        print("루트 .env 에 KAKAO_REST_API_KEY 가 없어요.")
        return 1
    origin = (round(args.lng, 4), round(args.lat, 4))  # (경도, 위도)
    print(f"출발: 위도 {origin[1]}, 경도 {origin[0]} → 목적지: {args.destination}\n")

    # 1) 목적지 검색
    found = call("1) 목적지 검색", "/v2/local/search/keyword.json", {"query": args.destination, "size": 1})
    if not found or not found.get("documents"):
        print("목적지를 찾지 못해서 여기서 멈춰요.")
        return 1
    doc = found["documents"][0]
    dest = (float(doc["x"]), float(doc["y"]))
    print(f"    → {doc['place_name']} ({dest[1]:.4f}, {dest[0]:.4f})")

    # 2) 대중교통 경로
    transit = call("2) 대중교통 경로", "/v2/routing/publictraffic",
                   {"start_x": origin[0], "start_y": origin[1], "end_x": dest[0], "end_y": dest[1]})
    if not transit or not transit.get("routes"):
        print("\n결론: 대중교통 경로 자체에서 막혀요. (가까운 거리이거나 카카오가 경로를 못 찾는 위치)")
        return 0
    route = transit["routes"][0]
    print(f"    → 경로 {len(transit['routes'])}개, 첫 경로 {route['properties'].get('totalTime', 0) // 60}분")
    first_ride = next((s for s in route.get("steps", [])
                       if s.get("properties", {}).get("type") in ("BUS", "SUBWAY")), None)
    points = (first_ride or {}).get("path", {}).get("points") or []
    if not points:
        print("첫 탑승 구간 좌표가 없어서 여기서 멈춰요.")
        return 0
    stop = (round(points[0][0], 4), round(points[0][1], 4))
    stop_name = (first_ride["properties"].get("stops") or [{}])[0].get("name", "첫 정류장")
    print(f"    → 첫 탑승: {stop_name}")

    # 3) 출발지 → 첫 정류장 도보
    call("3) 출발지 → 첫 정류장 도보", "/v2/routing/walk",
         {"start_x": origin[0], "start_y": origin[1], "end_x": stop[0], "end_y": stop[1]})

    # 4) 첫 정류장 근처 장소 검색
    near = call(f"4) 정류장 근처 '{args.place}' 검색", "/v2/local/search/keyword.json",
                {"query": args.place, "x": stop[0], "y": stop[1], "radius": 500, "size": 3, "sort": "distance"})
    if not near or not near.get("documents"):
        print("    → 근처 장소가 없어서 5번은 건너뛰어요.")
        return 0
    place_doc = near["documents"][0]
    place = (round(float(place_doc["x"]), 4), round(float(place_doc["y"]), 4))
    print(f"    → {place_doc['place_name']} ({place_doc.get('distance', '?')}m)")

    # 5) 출발지 → 장소 → 정류장 경유 도보 (#45에서 새로 생긴 호출)
    via = call("5) 출발지 → 장소 → 정류장 경유 도보", "/v2/routing/walk",
               {"start_x": origin[0], "start_y": origin[1], "end_x": stop[0], "end_y": stop[1],
                "via_x": str(place[0]), "via_y": str(place[1])})
    print()
    if via is None:
        print("결론: 5번(경유 도보)에서 막혀요. kakao_400_fix 로 완전히 해결되는 경우예요.")
    else:
        print("결론: 이 출발지에서는 모두 통과했어요. 오류 났던 위치와 같은 좌표인지 다시 확인해 보세요.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
