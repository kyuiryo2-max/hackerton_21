"""AI가 고른 매장 후보를 카카오 장소 검색으로 실제 지점과 연결해요.

앱의 로컬 의미 규칙으로 추천을 만들지 못했을 때만 호출하는 보조 기능이에요.
AI가 매장 이름을 지어내지 않도록, 응답에는 카카오가 찾은 실제 지점만 넣어요.
현재 위치 좌표는 검색 중심으로만 쓰고 저장하지 않아요.
"""
from concurrent.futures import ThreadPoolExecutor, as_completed
import math

from app.services import kakao, llm

# 가까운 지점을 먼저 찾고, 없을 때만 조금 넓혀요.
SEARCH_RADIUS_M = 5000
FALLBACK_RADIUS_M = 20000
LOOKUP_SIZE = 3
MAX_WORKERS = 3


def _distance_m(center: kakao.Coord, place: dict) -> int | None:
    """카카오가 거리를 안 줬을 때 직선거리로 채워요."""
    try:
        lat1, lng1 = center[1], center[0]
        lat2, lng2 = float(place["lat"]), float(place["lng"])
    except (KeyError, TypeError, ValueError):
        return None
    radius = 6371000
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lng2 - lng1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return round(radius * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a)))


def _lookup(candidate: dict, center: kakao.Coord) -> list[dict]:
    """AI 후보 하나를 카카오에서 검색해 가장 가까운 실제 지점을 돌려줘요."""
    query = candidate["search_query"]
    found: list[dict] = []
    for radius in (SEARCH_RADIUS_M, FALLBACK_RADIUS_M):
        found = kakao.search_places(
            center,
            keyword=query,
            radius_m=radius,
            size=LOOKUP_SIZE,
            sort="distance",
        )
        if found:
            break
    if not found:
        return []

    place = found[0]
    distance = place.get("distance_m")
    if not isinstance(distance, (int, float)):
        distance = _distance_m(center, place)
    return [
        {
            "name": place.get("name") or candidate["name"],
            "address": place.get("address") or "",
            "lat": place.get("lat"),
            "lng": place.get("lng"),
            "category": candidate["category"],
            "reason": candidate["reason"],
            "search_query": query,
            "distance_m": round(distance) if isinstance(distance, (int, float)) else None,
            "place_url": place.get("place_url") or "",
            "verified": True,
        }
    ]


def recommend(text: str, center: kakao.Coord, limit: int = 3) -> list[dict]:
    """AI 후보를 실제 카카오 검색 결과로 바꿔 가까운 순서로 돌려줘요.

    카카오 호출이 모두 실패하면 첫 오류를 올려서 라우터가 502로 답하게 해요.
    일부만 실패하면 찾은 지점은 그대로 보여 줘요.
    """
    candidates = llm.recommend_places(text, center, limit=limit)
    if not candidates:
        return []

    order = {candidate["search_query"]: index for index, candidate in enumerate(candidates)}
    results: list[dict] = []
    errors: list[Exception] = []
    workers = min(MAX_WORKERS, len(candidates))
    with ThreadPoolExecutor(max_workers=workers, thread_name_prefix="place-recommend") as pool:
        futures = {pool.submit(_lookup, candidate, center): candidate for candidate in candidates}
        for future in as_completed(futures):
            try:
                results.extend(future.result())
            except kakao.KakaoError as e:
                errors.append(e)

    if not results and errors:
        raise errors[0]

    unique: dict[str, dict] = {}
    for item in results:
        key = item["name"].casefold()
        previous = unique.get(key)
        if previous is None or (item.get("distance_m") or 10**9) < (previous.get("distance_m") or 10**9):
            unique[key] = item

    def sort_key(item: dict) -> tuple[float, int]:
        distance = item.get("distance_m")
        return (distance if isinstance(distance, (int, float)) else 10**9,
                order.get(item.get("search_query"), 99))

    return sorted(unique.values(), key=sort_key)[:limit]
