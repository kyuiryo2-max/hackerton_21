"""장소 종류별 실제 검색 결과 확인 (할 일 14번 '팀 확인'용).

시연 지역 주변에서 종류마다 몇 곳이 나오는지, 가장 가까운 곳이 어디인지 표로 보여 줘요.
결과가 0곳이거나 엉뚱한 곳이 나오면 data/demo/place_types.csv 의 search_value 를 고치면 돼요.
카카오 장소 검색은 하루 100,000건 한도라 12번 호출은 부담 없어요.

실행 (루트 .env 에 KAKAO_REST_API_KEY 필요):
  cd server
  uv run python ../scripts/check_place_types.py
  uv run python ../scripts/check_place_types.py --center 127.0293,37.5863 --radius 800
  (--center 는 "경도,위도", 기본값은 고려대 정문 근처)
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "server"))

from app import config  # noqa: E402
from app.services import kakao, places  # noqa: E402


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--center", default="127.0293,37.5863")
    p.add_argument("--radius", type=int, default=500)
    args = p.parse_args()
    if not config.KAKAO_REST_API_KEY:
        sys.exit("루트 .env 에 KAKAO_REST_API_KEY 가 없어요")
    x, y = (float(v) for v in args.center.split(","))

    print(f"중심 {args.center}, 반경 {args.radius}m\n")
    print(f"{'장소 종류':<8} {'검색':<14} {'결과':>4}  가장 가까운 곳")
    print("-" * 70)
    empty = []
    for s in places.place_searches().values():
        try:
            found = places.search_by_place_type(s.place_type, (x, y), radius_m=args.radius, size=15)
        except kakao.KakaoError as e:
            print(f"{s.place_type:<8} 오류: {e}")
            continue
        nearest = f"{found[0]['name']} ({found[0]['distance_m']}m)" if found else "-"
        print(f"{s.place_type:<8} {s.search_type[:3]}:{s.search_value:<10} {len(found):>4}  {nearest}")
        if not found:
            empty.append(s.place_type)
    if empty:
        print(f"\n결과 없음: {', '.join(empty)} → 반경을 늘리거나 search_value 를 바꿔 보세요")


if __name__ == "__main__":
    main()
