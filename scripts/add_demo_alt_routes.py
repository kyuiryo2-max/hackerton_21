"""시연 모드의 대안 경로 2개(6호선 → 1호선, 1222번)를 data/demo/scenario.json의 alt_routes에 넣어요 (11/19).

경로 모양·구간 시간은 data/samples/kakao_transit.json(11/5 카카오 실제 응답)에서 가져와요. 키 필요 없음.
도착 정보(arrivals)와 처음·마지막 도보는 시연 대본에 맞춘 고정값이에요 (2115번 arrivals와 같은 방식).
여러 번 실행해도 돼요. 파일의 다른 줄 모양은 그대로 두고 alt_routes만 넣거나 바꿔요.

    python scripts/add_demo_alt_routes.py
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCENARIO = ROOT / "data" / "demo" / "scenario.json"
SAMPLE = ROOT / "data" / "samples" / "kakao_transit.json"
MAX_LEG_POINTS = 40  # server/app/services/kakao.py 와 같아요

# guidance(첫 구간) → 시연 고정값. 지금(08:32) 기준 몇 초 뒤에 오는지
ALT = {
    "6호선 (안암(고대병원앞) > 동묘앞)": {
        "first_walk_seconds": 150,   # 안암역3번출구 정류장 → 6호선 타는 곳
        "last_walk_seconds": 180,    # 청량리역 1호선 → 청량리역
        "arrivals": {"direction": "신내행", "interval_minutes": 7, "first_seconds": 300, "second_seconds": 720},
    },
    "지선 1222 (우신향병원 > 청량리역환승센터(2번승강장))": {
        "first_walk_seconds": 180,   # 안암역3번출구 정류장 → 우신향병원 정류장
        "last_walk_seconds": 120,
        "arrivals": {"direction": "청량리역환승센터", "interval_minutes": 11, "first_seconds": 420, "second_seconds": 1080},
    },
}


def thin(points: list) -> list[list[float]]:
    pts = [[float(p[0]), float(p[1])] for p in points if len(p) >= 2]
    if len(pts) <= MAX_LEG_POINTS:
        return pts
    step = (len(pts) - 1) / (MAX_LEG_POINTS - 1)
    return [pts[round(i * step)] for i in range(MAX_LEG_POINTS)]


def leg_of(step: dict) -> dict:
    prop = step.get("properties", {})
    points = step.get("path", {}).get("points", [])
    return {
        "type": prop.get("type"),
        "seconds": prop.get("time", 0),
        "guidance": prop.get("guidance", ""),
        "stops": [s.get("name", "") for s in prop.get("stops", [])],
        "vehicles": list(dict.fromkeys(v.get("name", "") for v in prop.get("vehicles", []))),
        "start": points[0] if points else None,
        "end": points[-1] if points else None,
        "points": thin(points),
    }


def build() -> list[dict]:
    data = json.loads(SAMPLE.read_text(encoding="utf-8"))
    out = []
    for guidance, fixed in ALT.items():
        route = next(r for r in data["routes"] if r["steps"][0]["properties"].get("guidance") == guidance)
        prop = route["properties"]
        legs = [leg_of(s) for s in route["steps"]]
        first = next(leg for leg in legs if leg["type"] in ("BUS", "SUBWAY"))
        fare = prop.get("fare") or {}
        out.append({
            "type": prop.get("type"),
            "name": "·".join(first["vehicles"][:3]),
            "guidance": first["guidance"],
            "board_stop": first["stops"][0],
            "moving_seconds": sum(leg["seconds"] for leg in legs),
            "transfers": prop.get("transfers"),
            "fare_min": fare.get("min", fare.get("value")),
            "fare_max": fare.get("max", fare.get("value")),
            **fixed,
            "legs": legs,
        })
    return out


def write(alt: list[dict]) -> None:
    text = SCENARIO.read_text(encoding="utf-8")
    text = re.sub(r',\s*"alt_routes"\s*:\s*\[.*?\n  \]', "", text, flags=re.S)
    body = ",\n".join("    " + json.dumps(r, ensure_ascii=False) for r in alt)
    end = text.rstrip().rfind("}")
    text = text[:end].rstrip() + ',\n  "alt_routes": [\n' + body + "\n  ]\n}\n"
    json.loads(text)
    SCENARIO.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    alt = build()
    write(alt)
    for r in alt:
        print(f"- {r['name']}: {r['board_stop']} 탑승, 구간 {r['moving_seconds']}초, "
              f"{r['arrivals']['first_seconds'] // 60}분·{r['arrivals']['second_seconds'] // 60}분 뒤")
