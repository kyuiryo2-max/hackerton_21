"""시연 지역(안암역3번출구 정류장 근처)에 할 일 없이 들를 수 있는 장소를 넣어요 (11/19).

시연 대본의 장소는 편의점·카페·다이소 3곳뿐이라, 관객이 "약 사야 해", "장 봐야 해"처럼
다른 할 일을 넣으면 "시연 지역에 없는 장소예요"가 나왔어요.
이 스크립트는 KAKAO_REST_API_KEY로 장소 종류마다 정류장에서 가장 가까운 곳을 찾고,
정류장 → 장소 → 정류장 도보 시간을 재서 data/demo/scenario.json의 extra_places에 넣어요.
대본 할 일(places)과 시연 계산은 그대로예요. 서버는 시연 중에 외부 API를 부르지 않아요.

    cd server
    uv run python ../scripts/add_demo_places.py              # 약국, 마트 (기본)
    uv run python ../scripts/add_demo_places.py --all        # 장소 종류 목록 전부 (이미 있는 종류는 빼고)
    uv run python ../scripts/add_demo_places.py 약국 올리브영  # 고른 종류만
    uv run python ../scripts/add_demo_places.py --check      # 바꾸지 않고 결과만 보기
"""
import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "server"))

from app import config  # noqa: E402
from app.services import kakao, places  # noqa: E402
from app.services.planner import default_stay_minutes  # noqa: E402

SCENARIO = ROOT / "data" / "demo" / "scenario.json"
DEFAULT_TYPES = ["약국", "마트"]
SEARCH_RADIUS_M = 600   # 정류장에서 걸어서 다녀올 만한 거리
WALK_SPEED_MPS = 1.1    # 도보 경로를 못 받을 때만 쓰는 어림값


def find(place_type: str, stop: tuple[float, float]) -> dict | None:
    found = places.search_by_place_type(place_type, stop, radius_m=SEARCH_RADIUS_M, size=5)
    if not found:
        return None
    p = found[0]  # 가까운 순
    coord = (p["lng"], p["lat"])
    walk = kakao.walk_seconds(stop, stop, via=[coord], use_cache=False)
    if walk is None:
        walk = round((p["distance_m"] or 0) * 2 * 1.3 / WALK_SPEED_MPS)
    return {
        "place_type": place_type,
        "name": p["name"],
        "address": p["address"],
        "lng": round(p["lng"], 8),
        "lat": round(p["lat"], 8),
        "round_trip_walk_seconds": int(walk),
        "stay_seconds": (default_stay_minutes([place_type]) or 4) * 60,
    }


def write(extra: list[dict]) -> None:
    """파일의 다른 줄 모양은 그대로 두고 맨 끝의 extra_places만 넣거나 바꿔요."""
    text = SCENARIO.read_text(encoding="utf-8")
    text = re.sub(r',\s*"extra_places"\s*:\s*\[.*?\n  \]', "", text, flags=re.S)
    body = ",\n".join("    " + json.dumps(p, ensure_ascii=False) for p in extra)
    end = text.rstrip().rfind("}")
    text = text[:end].rstrip() + ',\n  "extra_places": [\n' + body + "\n  ]\n}\n"
    json.loads(text)  # 깨진 JSON은 저장하지 않아요
    SCENARIO.write_text(text, encoding="utf-8")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("types", nargs="*", help="장소 종류 (없으면 약국, 마트)")
    ap.add_argument("--all", action="store_true", help="장소 종류 목록 전부")
    ap.add_argument("--check", action="store_true", help="바꾸지 않고 결과만 보기")
    args = ap.parse_args()
    if not config.KAKAO_REST_API_KEY:
        raise SystemExit("KAKAO_REST_API_KEY가 없어요. 루트 .env에 넣고 다시 실행해 주세요")

    data = json.loads(SCENARIO.read_text(encoding="utf-8"))
    loc = data["location"]
    stop = (loc["lng"], loc["lat"])
    in_script = {p["place_type"] for p in data["places"]}
    kept = {p["place_type"]: p for p in data.get("extra_places", [])}
    types = list(places.place_searches()) if args.all else (args.types or DEFAULT_TYPES)
    for t in types:
        if t in in_script:
            print(f"- {t}: 대본 장소에 이미 있어요 (건너뜀)")
            continue
        p = find(t, stop)
        if p is None:
            print(f"- {t}: 정류장 {SEARCH_RADIUS_M}m 안에서 찾지 못했어요")
            continue
        kept[t] = p
        print(f"- {t}: {p['name']} ({p['address']}) 왕복 도보 {p['round_trip_walk_seconds']}초")
    extra = list(kept.values())
    if args.check:
        print("\n--check: 저장하지 않았어요")
        return
    write(extra)
    print(f"\n{SCENARIO.relative_to(ROOT)}에 extra_places {len(extra)}곳을 저장했어요")


if __name__ == "__main__":
    main()
