"""1순위 흐름 확인 (할 일 35번): 앱이 쓰는 순서대로 서버 API를 끝까지 불러 봐요.

할 일 입력 → 장소 이해 → 저장 → 경로 계획 → 이동 중 질문 → 질문 기록 → 경로 선택 기록

실행:
  cd server
  uv run python ../scripts/check_flow.py                                      # 로컬 서버 (먼저 uvicorn 실행)
  uv run python ../scripts/check_flow.py --base https://teumgil-server.onrender.com
시연 모드(demo=true)로 계산하므로 외부 교통 API는 부르지 않아요. 할 일은 임시 사용자로 저장해요.
"""
import argparse
import sys
import uuid

import httpx

STEPS: list[tuple[str, bool, str]] = []


def check(name: str, ok: bool, detail: str = "") -> bool:
    STEPS.append((name, ok, detail))
    print(f"[{'통과' if ok else '실패'}] {name}  {detail}")
    return ok


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--base", default="http://127.0.0.1:8000")
    args = p.parse_args()
    sys.stdout.reconfigure(errors="replace")
    user = f"flow-{uuid.uuid4().hex[:8]}"
    api = httpx.Client(base_url=args.base.rstrip("/"), timeout=60)  # 무료 서버는 첫 응답이 느려요

    if not check("서버 상태", api.get("/health").status_code == 200):
        return 1

    # 1. 할 일 문장 → 장소 종류 (저장 안 함)
    texts = ["아 이어폰 사야 돼", "커피 사기", "다이소 들르기"]
    parsed = []
    for text in texts:
        res = api.post("/api/tasks/parse", json={"user_id": user, "text": text})
        body = res.json()
        parsed.append(body)
        check(f"할 일 이해: {text}", res.status_code == 200, f"{body.get('place_types')} ({body.get('engine')})")

    # 2. 사용자가 확인한 할 일 저장 (장소를 모르면 화면에서 고른다고 보고 시연 장소로 채움)
    fallback = {"아 이어폰 사야 돼": ["편의점"], "커피 사기": ["카페"], "다이소 들르기": ["다이소"]}
    importance = {"아 이어폰 사야 돼": "필수", "커피 사기": "선택", "다이소 들르기": "필수"}
    todo_ids = []
    for text, body in zip(texts, parsed):
        res = api.post("/api/todos", json={
            "user_id": user, "text": text, "importance": importance[text],
            "place_types": body.get("place_types") or fallback[text],
        })
        check(f"할 일 저장: {text}", res.status_code == 201)
        todo_ids.append(res.json().get("id"))

    # 3. 경로 계획
    res = api.post("/api/plan", json={"user_id": user, "todo_ids": todo_ids, "demo": True})
    plan = res.json()
    route = (plan.get("routes") or [{}])[0]
    check("경로 계획", res.status_code == 200 and bool(plan.get("routes")),
          f"{route.get('name')}번 대기 {route.get('wait_min')}분, 최대 체류 {route.get('max_stay_min')}분, 도착 {plan.get('arrive_at')}")
    statuses = {t["text"]: t["status"] for t in plan.get("todos", [])}
    check("할 일 상태 계산", set(statuses.values()) <= {"포함", "제외", "대기"} and bool(statuses), str(statuses))
    saved = {t["text"]: t["status"] for t in api.get("/api/todos", params={"user_id": user}).json()}
    check("할 일 상태 저장", saved == statuses, str(saved))

    # 4. 이동 중 질문
    for question in ["다음 버스 언제야?", "10분 늦을 것 같아", "점심 뭐 먹지?"]:
        res = api.post("/api/ask", json={"user_id": user, "text": question, "demo": True})
        body = res.json()
        check(f"질문: {question}", res.status_code == 200 and bool(body.get("answer")),
              f"{body.get('answer')} ({body.get('engine')})")

    # 5. 질문 기록, 경로 선택 기록
    messages = api.get("/api/messages", params={"user_id": user}).json()
    check("질문 기록", len(messages) == 6, f"{len(messages)}개")
    res = api.post("/api/choices", json={"user_id": user, "chosen_route": route, "other_routes": []})
    check("경로 선택 기록", res.status_code == 201)

    failed = [name for name, ok, _ in STEPS if not ok]
    print(f"\n{len(STEPS) - len(failed)}/{len(STEPS)} 통과" + (f", 실패: {failed}" if failed else ""))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
