"""저장·조회 API 테스트 (작업 표 16번). test_health.py 처럼 임시 DB를 써요."""
import re
import sqlite3

import pytest
from fastapi.testclient import TestClient

from app.db.database import seed_demo_data

KST_TIME = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+09:00$")
SCHEDULE = {
    "user_id": "u1", "destination": "공학관",
    "destination_lat": 37.5833, "destination_lng": 127.0263,
    "arrive_by": "2026-11-21T09:00:00+09:00",
}


@pytest.fixture()
def client(tmp_path, monkeypatch):
    monkeypatch.setattr("app.config.DATABASE_PATH", str(tmp_path / "test.db"))
    from app.main import app

    with TestClient(app) as c:
        yield c


def _schedule(client, **overrides):
    return client.post("/api/schedules", json={**SCHEDULE, **overrides})


# ---------- 일정 ----------
def test_일정_저장하고_조회(client):
    res = _schedule(client, prep_minutes=40)
    assert res.status_code == 201
    saved = res.json()
    assert saved["arrive_by"] == "2026-11-21T09:00:00+09:00"
    assert (saved["destination_lat"], saved["destination_lng"]) == (37.5833, 127.0263)
    assert client.get(f"/api/schedules/{saved['id']}", params={"user_id": "u1"}).json() == saved
    assert client.get("/api/schedules", params={"user_id": "u1"}).json() == [saved]


def test_시간대가_붙어_와도_한국_시간으로(client):
    res = _schedule(client, arrive_by="2026-11-21T00:00:00Z")
    assert res.json()["arrive_by"] == "2026-11-21T09:00:00+09:00"
    assert res.json()["prep_minutes"] == 30  # 기본값


def test_시간대가_없으면_한국_시간으로_봄(client):
    assert _schedule(client, arrive_by="2026-11-21T09:00").json()["arrive_by"] == "2026-11-21T09:00:00+09:00"


def test_목적지_좌표가_없으면_거절(client):
    body = {k: v for k, v in SCHEDULE.items() if k != "destination_lat"}
    res = client.post("/api/schedules", json=body)
    assert res.status_code == 422
    assert res.json()["error"]["code"] == "invalid_request"


def test_일정_수정은_보낸_값만(client):
    s = _schedule(client).json()
    res = client.patch(f"/api/schedules/{s['id']}", params={"user_id": "u1"}, json={"prep_minutes": 10})
    assert res.json()["prep_minutes"] == 10
    assert res.json()["destination"] == "공학관"


def test_일정_삭제(client):
    s = _schedule(client).json()
    assert client.delete(f"/api/schedules/{s['id']}", params={"user_id": "u1"}).json() == {"ok": True}
    assert client.get(f"/api/schedules/{s['id']}", params={"user_id": "u1"}).status_code == 404


# ---------- 할 일 ----------
def test_할_일_저장하고_필수_먼저_조회(client):
    client.post("/api/todos", json={"user_id": "u1", "text": "선물", "place_types": ["꽃집"]})
    client.post("/api/todos", json={"user_id": "u1", "text": "약 사기", "place_types": ["약국"], "importance": "필수"})
    todos = client.get("/api/todos", params={"user_id": "u1"}).json()
    assert [t["text"] for t in todos] == ["약 사기", "선물"]
    assert todos[0]["place_types"] == ["약국"]
    assert todos[0]["done"] is False


def test_들르기_질문은_필수_할_일로(client):
    """stopover_check: '아 우유 사야 돼' → 중요도 높은(필수) 할 일로 등록"""
    res = client.post("/api/todos", json={
        "user_id": "u1", "text": "우유 사기", "place_types": ["편의점"], "importance": "필수",
    })
    assert res.status_code == 201
    assert res.json()["importance"] == "필수"


def test_할_일_변경_완료_삭제(client):
    """change_todo: '선물이 더 급해', '약은 안 사도 돼'"""
    t = client.post("/api/todos", json={"user_id": "u1", "text": "선물", "place_types": ["꽃집"]}).json()
    me = {"user_id": "u1"}
    assert client.patch(f"/api/todos/{t['id']}", params=me, json={"importance": "필수"}).json()["importance"] == "필수"
    client.patch(f"/api/todos/{t['id']}", params=me, json={"done": True})
    assert client.get("/api/todos", params={"user_id": "u1", "done": False}).json() == []
    assert client.delete(f"/api/todos/{t['id']}", params=me).json() == {"ok": True}
    assert client.patch(f"/api/todos/{t['id']}", params=me, json={"done": True}).status_code == 404


def test_목록에_없는_장소_종류는_거절(client):
    res = client.post("/api/todos", json={"user_id": "u1", "text": "x", "place_types": ["우주정거장"]})
    assert res.status_code == 422


def test_목록에_없는_중요도는_거절(client):
    res = client.post("/api/todos", json={"user_id": "u1", "text": "x", "importance": "보통"})
    assert res.status_code == 422


# ---------- 할 일 상태·출처 (#12 회의 3번) ----------
def test_새_할_일은_대기_입력(client):
    t = client.post("/api/todos", json={"user_id": "u1", "text": "약 사기", "place_types": ["약국"]}).json()
    assert (t["status"], t["source"], t["done"]) == ("대기", "입력", False)


def test_질문으로_들어온_할_일은_필수(client):
    """stopover_check '아 우유 사야 돼' → 중요도를 보내지 않아도, 선택으로 보내도 필수"""
    t = client.post("/api/todos", json={
        "user_id": "u1", "text": "우유 사기", "place_types": ["편의점"], "importance": "선택", "source": "질문",
    }).json()
    assert (t["importance"], t["source"]) == ("필수", "질문")


def test_상태_바꾸고_상태로_조회(client):
    me = {"user_id": "u1"}
    a = client.post("/api/todos", json={"user_id": "u1", "text": "약 사기"}).json()
    b = client.post("/api/todos", json={"user_id": "u1", "text": "선물"}).json()
    client.patch(f"/api/todos/{a['id']}", params=me, json={"status": "포함"})
    client.patch(f"/api/todos/{b['id']}", params=me, json={"status": "제외"})
    assert [t["text"] for t in client.get("/api/todos", params={**me, "status": "포함"}).json()] == ["약 사기"]
    assert [t["text"] for t in client.get("/api/todos", params={**me, "status": "제외"}).json()] == ["선물"]


def test_done은_완료_상태와_같음(client):
    me = {"user_id": "u1"}
    t = client.post("/api/todos", json={"user_id": "u1", "text": "약 사기"}).json()
    done = client.patch(f"/api/todos/{t['id']}", params=me, json={"done": True}).json()
    assert (done["status"], done["done"]) == ("완료", True)
    undone = client.patch(f"/api/todos/{t['id']}", params=me, json={"done": False}).json()
    assert (undone["status"], undone["done"]) == ("대기", False)


def test_목록에_없는_상태는_거절(client):
    res = client.post("/api/todos", json={"user_id": "u1", "text": "x", "status": "보류"})
    assert res.status_code == 422
    assert res.json()["error"]["code"] == "invalid_request"


def test_예전_DB_파일도_상태_열이_생김(tmp_path, monkeypatch):
    """11/8 이전 DB(done 열만 있음)를 열면 status·source 가 생기고 완료였던 건 '완료'"""
    db = tmp_path / "old.db"
    with sqlite3.connect(db) as conn:
        conn.execute("""CREATE TABLE todos (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT NOT NULL,
            text TEXT NOT NULL, place_types TEXT, importance TEXT NOT NULL DEFAULT '선택',
            done INTEGER NOT NULL DEFAULT 0)""")
        conn.execute("INSERT INTO todos (user_id, text, done) VALUES ('u1', '끝난 일', 1), ('u1', '남은 일', 0)")
    monkeypatch.setattr("app.config.DATABASE_PATH", str(db))
    from app.main import app

    with TestClient(app) as c:
        todos = {t["text"]: t for t in c.get("/api/todos", params={"user_id": "u1"}).json()}
        assert todos["끝난 일"]["status"] == "완료"
        assert (todos["남은 일"]["status"], todos["남은 일"]["source"]) == ("대기", "입력")
        assert c.post("/api/todos", json={"user_id": "u1", "text": "새 일"}).status_code == 201


# ---------- 질문 기록 (#12 회의 4번) ----------
def test_질문_기록_저장과_조회(client):
    from app.db import repository as repo

    repo.add_message("u1", "user", "약국 들러도 돼?", [{"intent": "stopover_check", "place_types": ["약국"]}])
    repo.add_message("u1", "assistant", "약국에서 최대 6분 있을 수 있어요.")
    messages = client.get("/api/messages", params={"user_id": "u1"}).json()
    assert [m["role"] for m in messages] == ["user", "assistant"]
    assert messages[0]["intents"][0]["intent"] == "stopover_check"
    assert messages[1]["intents"] is None
    assert KST_TIME.match(messages[0]["created_at"])
    assert client.get("/api/messages", params={"user_id": "u2"}).json() == []


def test_최근_대화는_마지막_몇_턴만_오래된_순(client):
    from app.db import repository as repo

    for i in range(1, 8):
        repo.add_message("u1", "user", f"질문{i}")
        repo.add_message("u1", "assistant", f"답변{i}")
    recent = repo.recent_messages("u1", turns=3)
    assert [m["text"] for m in recent] == ["질문5", "답변5", "질문6", "답변6", "질문7", "답변7"]
    assert recent[0] == {"role": "user", "text": "질문5"}
    assert [m["text"] for m in client.get("/api/messages", params={"user_id": "u1", "limit": 2}).json()] == ["질문7", "답변7"]


def test_테스트_케이스로_모을_질문은_사용자_질문만(client):
    from app.db import repository as repo

    repo.add_message("u1", "user", "다음 버스 언제야?")
    repo.add_message("u1", "assistant", "12분 뒤예요.")
    repo.add_message("demo", "user", "시연 질문")
    assert [m["text"] for m in repo.list_user_questions()] == ["다음 버스 언제야?"]


def test_역할은_user_assistant만(client):
    from app.db import repository as repo

    with pytest.raises(ValueError):
        repo.add_message("u1", "system", "x")


def test_재시작하면_demo_대화도_지워짐(client, tmp_path):
    from app.db import repository as repo

    repo.add_message("demo", "user", "시연 질문")
    seed_demo_data(str(tmp_path / "test.db"))
    assert client.get("/api/messages", params={"user_id": "demo"}).json() == []


# ---------- 설정 ----------
def test_설정_기본값과_저장(client):
    assert client.get("/api/settings/u1").json() == {
        "user_id": "u1", "w_time": 0.6, "w_transfer": 0.3, "w_fare": 0.1,
    }
    res = client.put("/api/settings/u1", json={"w_transfer": 0.5})
    assert res.json()["w_transfer"] == 0.5
    assert res.json()["w_time"] == 0.6  # 안 보낸 값은 그대로
    assert client.get("/api/settings/u1").json()["w_transfer"] == 0.5


# ---------- 경로 선택 기록 ----------
def test_경로_선택_기록(client):
    res = client.post("/api/choices", json={
        "user_id": "u1",
        "chosen_route": {"total_min": 42, "transfers": 1, "fare": 1500},
        "other_routes": [{"total_min": 48, "transfers": 0, "fare": 1500}],
    })
    assert res.status_code == 201
    assert KST_TIME.match(res.json()["created_at"])
    choices = client.get("/api/choices", params={"user_id": "u1"}).json()
    assert choices[0]["chosen_route"]["transfers"] == 1
    assert choices[0]["other_routes"][0]["total_min"] == 48


# ---------- 시연 데이터 ----------
def test_시연_데이터가_조회됨(client):
    schedule = client.get("/api/schedules", params={"user_id": "demo"}).json()[0]
    assert schedule["destination"] == "청량리역"
    assert KST_TIME.match(schedule["arrive_by"])
    texts = [t["text"] for t in client.get("/api/todos", params={"user_id": "demo"}).json()]
    assert texts == ["이어폰 사기", "다이소 들르기", "커피 사기"]  # 필수 먼저


def test_시연_데이터는_API로_바꿀_수_없음(client):
    demo = {"user_id": "demo"}
    todo_id = client.get("/api/todos", params=demo).json()[0]["id"]
    schedule_id = client.get("/api/schedules", params=demo).json()[0]["id"]
    blocked = [
        client.delete(f"/api/todos/{todo_id}", params=demo),
        client.patch(f"/api/todos/{todo_id}", params=demo, json={"done": True}),
        client.delete(f"/api/schedules/{schedule_id}", params=demo),
        client.patch(f"/api/schedules/{schedule_id}", params=demo, json={"prep_minutes": 0}),
        client.post("/api/todos", json={"user_id": "demo", "text": "장난"}),
        client.post("/api/schedules", json={**SCHEDULE, "user_id": "demo"}),
        client.put("/api/settings/demo", json={"w_time": 0}),
    ]
    for res in blocked:
        assert res.status_code == 403
        assert res.json()["error"]["code"] == "demo_readonly"
    assert len(client.get("/api/todos", params=demo).json()) == 3


def test_재시작하면_시연_데이터가_처음_상태로(client, tmp_path):
    db = str(tmp_path / "test.db")
    with sqlite3.connect(db) as conn:  # API를 거치지 않고 망가뜨린 상황
        conn.execute("DELETE FROM todos WHERE user_id = 'demo' AND text = '이어폰 사기'")
        conn.execute("INSERT INTO todos (user_id, text) VALUES ('demo', '장난')")
    seed_demo_data(db)
    texts = [t["text"] for t in client.get("/api/todos", params={"user_id": "demo"}).json()]
    assert texts == ["이어폰 사기", "다이소 들르기", "커피 사기"]
    assert len(client.get("/api/schedules", params={"user_id": "demo"}).json()) == 1


# ---------- 다른 사용자 데이터 ----------
def test_사용자끼리_섞이지_않음(client):
    client.post("/api/todos", json={"user_id": "u1", "text": "약 사기", "place_types": ["약국"]})
    assert client.get("/api/todos", params={"user_id": "u2"}).json() == []


def test_다른_사용자의_항목은_조회_수정_삭제_불가(client):
    s = _schedule(client).json()
    t = client.post("/api/todos", json={"user_id": "u1", "text": "약 사기"}).json()
    other = {"user_id": "u2"}
    assert client.get(f"/api/schedules/{s['id']}", params=other).status_code == 404
    assert client.patch(f"/api/schedules/{s['id']}", params=other, json={"prep_minutes": 0}).status_code == 404
    assert client.delete(f"/api/schedules/{s['id']}", params=other).status_code == 404
    assert client.patch(f"/api/todos/{t['id']}", params=other, json={"done": True}).status_code == 404
    assert client.delete(f"/api/todos/{t['id']}", params=other).status_code == 404
    # u1 의 데이터는 그대로
    assert client.get(f"/api/schedules/{s['id']}", params={"user_id": "u1"}).json() == s
    assert client.get("/api/todos", params={"user_id": "u1"}).json() == [t]


def test_user_id_없이_id로_접근하면_거절(client):
    s = _schedule(client).json()
    res = client.get(f"/api/schedules/{s['id']}")
    assert res.status_code == 422
    assert res.json()["error"]["code"] == "invalid_request"


# ---------- 오류 형식 ----------
def test_없는_항목은_404_오류_형식(client):
    res = client.get("/api/schedules/9999", params={"user_id": "u1"})
    assert res.status_code == 404
    assert res.json()["error"]["code"] == "not_found"


def test_입력_오류도_팀_오류_형식(client):
    res = client.post("/api/todos", json={"user_id": "u1"})  # text 빠짐
    assert res.status_code == 422
    body = res.json()
    assert "detail" not in body
    assert body["error"]["code"] == "invalid_request"
    assert "text" in body["error"]["message"]


def test_없는_주소도_팀_오류_형식(client):
    res = client.get("/api/없는주소")
    assert res.status_code == 404
    assert res.json() == {"error": {"code": "not_found", "message": "Not Found"}}


# ---------- 위치 ----------
def test_현재_위치는_저장하지_않음(client, tmp_path):
    """목적지 좌표는 저장하지만, 사용자의 현재 위치는 보내도 무시해요."""
    _schedule(client, lat=37.58, lng=127.02, current_location={"lat": 37.58, "lng": 127.02})
    with sqlite3.connect(tmp_path / "test.db") as conn:
        for table in ("schedules", "todos", "settings", "route_choices", "messages"):
            cols = {r[1] for r in conn.execute(f"PRAGMA table_info({table})")}
            assert not cols & {"lat", "lng", "location", "current_location", "current_lat", "current_lng"}


def test_재시작해도_시연_id가_그대로(client, tmp_path):
    """앱이 시연 할 일 id를 그대로 쓰므로 재시작해도 바뀌면 안 돼요 (PR #29)"""
    demo = {"user_id": "demo"}
    before = ([t["id"] for t in client.get("/api/todos", params=demo).json()],
              [s["id"] for s in client.get("/api/schedules", params=demo).json()])
    client.post("/api/todos", json={"user_id": "u1", "text": "약 사기"})  # 다른 사용자가 id를 하나 더 씀
    seed_demo_data(str(tmp_path / "test.db"))
    after = ([t["id"] for t in client.get("/api/todos", params=demo).json()],
             [s["id"] for s in client.get("/api/schedules", params=demo).json()])
    assert after == before


def test_처음_켜진_서버의_시연_id는_1부터(client):
    todos = client.get("/api/todos", params={"user_id": "demo"}).json()
    assert sorted(t["id"] for t in todos) == [1, 2, 3]
    assert client.get("/api/schedules", params={"user_id": "demo"}).json()[0]["id"] == 1



def test_할_일_머물_시간_저장과_변경(client):
    todo = client.post("/api/todos", json={"user_id": "u1", "text": "꽃 사기", "place_types": ["꽃집"],
                                           "stay_minutes": 15}).json()
    assert todo["stay_minutes"] == 15
    todo = client.patch(f"/api/todos/{todo['id']}", params={"user_id": "u1"}, json={"stay_minutes": 20}).json()
    assert todo["stay_minutes"] == 20
    other = client.post("/api/todos", json={"user_id": "u1", "text": "우유 사기"}).json()
    assert other["stay_minutes"] is None  # 없으면 계산할 때 기본 4분


def test_머물_시간은_1분에서_120분(client):
    res = client.post("/api/todos", json={"user_id": "u1", "text": "꽃 사기", "stay_minutes": 0})
    assert res.status_code == 422
