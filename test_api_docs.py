"""docs/design/api-examples 가 서버 코드와 같은지 확인해요 (#12 회의 9번).

- "있음" 예시의 경로는 서버에 실제로 있어야 해요
- "만들 예정" 예시(plan, ask, tasks_parse)의 경로가 서버에 생기면 이 테스트가 알려 줘요 → 문서의 상태를 "있음"으로
"""
import json
import re
from pathlib import Path

from app.main import app

EXAMPLES = Path(__file__).resolve().parents[2] / "docs" / "design" / "api-examples"
PLANNED = {"plan", "ask", "tasks_parse"}


def _routes() -> set[tuple[str, str]]:
    out = set()
    for r in app.routes:
        for m in getattr(r, "methods", set()) or set():
            out.add((m, re.sub(r"\{[^}]+\}", "{}", r.path)))
    return out


def _documented(name: str) -> set[tuple[str, str]]:
    data = json.loads((EXAMPLES / f"{name}.json").read_text(encoding="utf-8"))
    return {
        (e["request"]["method"], re.sub(r"/\d+(?=/|$)", "/{}", e["request"]["path"]))
        for e in data["examples"]
    }


def test_예시_파일이_있음():
    names = {p.stem for p in EXAMPLES.glob("*.json")}
    assert {"schedules", "todos", "messages", "settings", "choices", "arrivals", "errors"} <= names
    assert PLANNED <= names


def test_있는_API_예시는_서버에_실제로_있음():
    routes = _routes()
    for path in EXAMPLES.glob("*.json"):
        if path.stem in PLANNED:
            continue
        for method, route in _documented(path.stem):
            route = re.sub(r"/settings/[^/]+$", "/settings/{}", route)
            assert (method, route) in routes, f"{path.name}: {method} {route} 가 서버에 없어요"


def test_만들_예정_API가_생기면_문서도_고치기():
    routes = _routes()
    for name in PLANNED:
        for method, route in _documented(name):
            assert (method, route) not in routes, f"{name}.json: {route} 가 생겼어요. api.md 상태를 '있음'으로 바꾸고 예시를 실제 응답으로"
