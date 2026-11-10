"""버스 도착 정리 실제 확인 (할 일 22번).

카카오 대중교통 경로를 받아서, 버스 구간마다 서울시 정류소 번호(arsId)와 실시간 도착을 찾아 보여 줘요.
호출 수: 카카오 경로 1건 + 버스 구간마다 정류소 1건·도착 1~3건.

실행 (루트 .env 에 KAKAO_REST_API_KEY, DATA_GO_KR_SERVICE_KEY 필요):
  cd server
  uv run python ../scripts/check_bus_arrivals.py
  uv run python ../scripts/check_bus_arrivals.py --start 127.0293,37.5863 --end 126.9768,37.5714
  (좌표는 "경도,위도". 기본값은 안암역 → 청량리역)
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "server"))

from app import config  # noqa: E402
from app.services import kakao, seoul_bus  # noqa: E402


def coord(text: str) -> tuple[float, float]:
    x, y = (float(v) for v in text.split(","))
    return x, y


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--start", default="127.02934,37.58631")
    p.add_argument("--end", default="127.04691,37.58029")
    p.add_argument("--routes", type=int, default=5, help="확인할 경로 수")
    args = p.parse_args()
    missing = [n for n in ("KAKAO_REST_API_KEY", "DATA_GO_KR_SERVICE_KEY") if not getattr(config, n)]
    if missing:
        sys.exit(f"루트 .env 에 {', '.join(missing)} 가 없어요")

    routes = kakao.transit_routes(coord(args.start), coord(args.end))
    print(f"카카오 경로 {len(routes)}개 중 버스 구간 확인\n")
    found_any = False
    for n, route in enumerate(routes[: args.routes], 1):
        for leg in route["legs"]:
            if leg["type"] != "BUS":
                continue
            found_any = True
            name = leg["stops"][0] if leg["stops"] else "?"
            nxt = leg["stops"][1] if len(leg["stops"]) > 1 else "-"
            try:
                found = seoul_bus.match_leg(leg)
            except seoul_bus.SeoulBusError as e:
                print(f"[경로 {n}] {name} {leg['vehicles']} → 오류: {e}")
                continue
            if found is None:
                print(f"[경로 {n}] {name} {leg['vehicles']} (다음 {nxt}) → 정류소 못 찾음")
                continue
            s, a = found["stop"], found["arrival"]
            first = "없음" if a["first_seconds"] is None else f"{a['first_seconds']}초"
            second = "없음" if a["second_seconds"] is None else f"{a['second_seconds']}초"
            print(f"[경로 {n}] {name} {leg['vehicles']} (다음 {nxt})")
            print(f"    → {s['name']} {s['ars_id']} ({s['distance_m']}m), {a['route']}번 {a['direction']} 방면, "
                  f"다음 정류장 {a['next_stop']}")
            print(f"    → 첫 차 {first} ({a['first_message']}), 둘째 {second} ({a['second_message']})")
    if not found_any:
        print("버스 구간이 있는 경로가 없어요. --start, --end 를 바꿔 보세요")


if __name__ == "__main__":
    main()
