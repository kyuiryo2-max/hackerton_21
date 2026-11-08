"""SQLite 저장·조회 함수 (작업 표 16번: 일정·할 일·설정·선택 기록).

테이블은 database.py 의 SCHEMA 를 그대로 써요. 현재 위치는 저장하지 않아요.
id로 조회·수정·삭제할 때는 user_id 도 함께 받아 다른 사용자의 데이터는 건드리지 않아요.
다른 기능(/api/plan, 대화형 질문)에서도 이 함수들을 바로 불러 쓰면 돼요.

    from app.db import repository as repo
    repo.add_todo("u1", "우유 사기", ["편의점"], source="질문")   # stopover_check → 필수로 등록
    repo.recent_messages("u1")                                       # AI에 함께 보낼 최근 대화
"""
import json
import sqlite3

from app.db.database import connect

DEFAULT_SETTINGS = {"w_time": 0.6, "w_transfer": 0.3, "w_fare": 0.1}

# 할 일 상태·출처 (#12 회의 3번, json-format.md 4번)
STATUSES = ("대기", "포함", "제외", "완료")
SOURCES = ("입력", "질문")
DONE = "완료"
REQUIRED = "필수"
FROM_QUESTION = "질문"

# 질문 기록 (#12 회의 4번). 1턴 = 사용자 질문 1개 + 서버 답변 1개
RECENT_TURNS = 5
ROLES = ("user", "assistant")


def _rows(rows) -> list[dict]:
    return [dict(r) for r in rows]


# ---------- 일정 (schedules) ----------
def _schedule(r: sqlite3.Row) -> dict:
    return dict(r)


def add_schedule(
    user_id: str,
    destination: str,
    destination_lat: float,
    destination_lng: float,
    arrive_by: str,
    prep_minutes: int = 30,
) -> dict:
    with connect() as conn:
        cur = conn.execute(
            "INSERT INTO schedules (user_id, destination, destination_lat, destination_lng, arrive_by, prep_minutes) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (user_id, destination, destination_lat, destination_lng, arrive_by, prep_minutes),
        )
        new_id = cur.lastrowid
    return get_schedule(new_id, user_id)  # type: ignore[return-value]


def get_schedule(schedule_id: int, user_id: str) -> dict | None:
    with connect() as conn:
        r = conn.execute(
            "SELECT * FROM schedules WHERE id = ? AND user_id = ?", (schedule_id, user_id)
        ).fetchone()
    return _schedule(r) if r else None


def list_schedules(user_id: str) -> list[dict]:
    """가까운 일정부터."""
    with connect() as conn:
        rows = conn.execute(
            "SELECT * FROM schedules WHERE user_id = ? ORDER BY arrive_by, id", (user_id,)
        ).fetchall()
    return _rows(rows)


def update_schedule(schedule_id: int, user_id: str, **fields) -> dict | None:
    """보낸 값만 바꿔요. 예: update_schedule(1, "u1", prep_minutes=40)"""
    fields = {k: v for k, v in fields.items() if v is not None}
    with connect() as conn:
        if conn.execute(
            "SELECT 1 FROM schedules WHERE id = ? AND user_id = ?", (schedule_id, user_id)
        ).fetchone() is None:
            return None
        if fields:
            sets = ", ".join(f"{k} = ?" for k in fields)
            conn.execute(
                f"UPDATE schedules SET {sets} WHERE id = ? AND user_id = ?",
                (*fields.values(), schedule_id, user_id),
            )
    return get_schedule(schedule_id, user_id)


def delete_schedule(schedule_id: int, user_id: str) -> bool:
    with connect() as conn:
        return conn.execute(
            "DELETE FROM schedules WHERE id = ? AND user_id = ?", (schedule_id, user_id)
        ).rowcount > 0


# ---------- 할 일 (todos) ----------
def _todo(r: sqlite3.Row) -> dict:
    d = dict(r)
    d["place_types"] = json.loads(d["place_types"]) if d["place_types"] else []
    d["done"] = d["status"] == DONE  # 예전 앱 호환용. 기준은 status
    return d


def add_todo(
    user_id: str,
    text: str,
    place_types: list[str] | None = None,
    importance: str = "선택",
    status: str = "대기",
    source: str = "입력",
) -> dict:
    """질문으로 들어온 할 일(source="질문")은 중요도를 필수로 등록해요 (결정 로그 11/8)."""
    if source == FROM_QUESTION:
        importance = REQUIRED
    with connect() as conn:
        cur = conn.execute(
            "INSERT INTO todos (user_id, text, place_types, importance, status, source) VALUES (?, ?, ?, ?, ?, ?)",
            (user_id, text, json.dumps(place_types or [], ensure_ascii=False), importance, status, source),
        )
        new_id = cur.lastrowid
    return get_todo(new_id, user_id)  # type: ignore[return-value]


def get_todo(todo_id: int, user_id: str) -> dict | None:
    with connect() as conn:
        r = conn.execute("SELECT * FROM todos WHERE id = ? AND user_id = ?", (todo_id, user_id)).fetchone()
    return _todo(r) if r else None


def list_todos(user_id: str, done: bool | None = None, status: str | None = None) -> list[dict]:
    """필수 먼저, 그다음 등록 순서. done=False 는 완료가 아닌 것 전부."""
    sql, args = "SELECT * FROM todos WHERE user_id = ?", [user_id]
    if done is not None:
        sql += " AND status = ?" if done else " AND status != ?"
        args.append(DONE)
    if status is not None:
        sql += " AND status = ?"
        args.append(status)
    sql += " ORDER BY CASE importance WHEN '필수' THEN 0 ELSE 1 END, id"
    with connect() as conn:
        rows = conn.execute(sql, args).fetchall()
    return [_todo(r) for r in rows]


def update_todo(todo_id: int, user_id: str, **fields) -> dict | None:
    """change_todo 질문용. 예: update_todo(3, "u1", importance="필수"), update_todo(3, "u1", status="제외")

    done=True 는 status="완료", done=False 는 완료를 되돌려 "대기"로 바꿔요.
    """
    fields = {k: v for k, v in fields.items() if v is not None}
    done = fields.pop("done", None)
    if "place_types" in fields:
        fields["place_types"] = json.dumps(fields["place_types"], ensure_ascii=False)
    with connect() as conn:
        row = conn.execute(
            "SELECT status FROM todos WHERE id = ? AND user_id = ?", (todo_id, user_id)
        ).fetchone()
        if row is None:
            return None
        if done is True and "status" not in fields:
            fields["status"] = DONE
        elif done is False and "status" not in fields and row["status"] == DONE:
            fields["status"] = "대기"
        if fields:
            sets = ", ".join(f"{k} = ?" for k in fields)
            conn.execute(
                f"UPDATE todos SET {sets} WHERE id = ? AND user_id = ?",
                (*fields.values(), todo_id, user_id),
            )
    return get_todo(todo_id, user_id)


def delete_todo(todo_id: int, user_id: str) -> bool:
    with connect() as conn:
        return conn.execute(
            "DELETE FROM todos WHERE id = ? AND user_id = ?", (todo_id, user_id)
        ).rowcount > 0


# ---------- 설정 (settings: 경로 선호 가중치) ----------
def get_settings(user_id: str) -> dict:
    """저장된 값이 없으면 기본값을 돌려줘요 (DB에는 아직 안 넣음)."""
    with connect() as conn:
        r = conn.execute("SELECT * FROM settings WHERE user_id = ?", (user_id,)).fetchone()
    return dict(r) if r else {"user_id": user_id, **DEFAULT_SETTINGS}


def save_settings(user_id: str, **weights) -> dict:
    """보낸 가중치만 바꾸고 나머지는 지금 값을 유지해요."""
    current = get_settings(user_id)
    merged = {k: weights.get(k) if weights.get(k) is not None else current[k] for k in DEFAULT_SETTINGS}
    with connect() as conn:
        conn.execute(
            """INSERT INTO settings (user_id, w_time, w_transfer, w_fare) VALUES (?, ?, ?, ?)
               ON CONFLICT(user_id) DO UPDATE SET
                   w_time = excluded.w_time, w_transfer = excluded.w_transfer, w_fare = excluded.w_fare""",
            (user_id, merged["w_time"], merged["w_transfer"], merged["w_fare"]),
        )
    return get_settings(user_id)


# ---------- 경로 선택 기록 (route_choices, ⑧ 피드백용) ----------
def _choice(r: sqlite3.Row) -> dict:
    d = dict(r)
    d["chosen_route"] = json.loads(d["chosen_route"])
    d["other_routes"] = json.loads(d["other_routes"])
    return d


def add_route_choice(user_id: str, chosen_route: dict, other_routes: list[dict]) -> dict:
    with connect() as conn:
        cur = conn.execute(
            "INSERT INTO route_choices (user_id, chosen_route, other_routes) VALUES (?, ?, ?)",
            (user_id, json.dumps(chosen_route, ensure_ascii=False), json.dumps(other_routes, ensure_ascii=False)),
        )
        r = conn.execute("SELECT * FROM route_choices WHERE id = ?", (cur.lastrowid,)).fetchone()
    return _choice(r)


def list_route_choices(user_id: str) -> list[dict]:
    with connect() as conn:
        rows = conn.execute("SELECT * FROM route_choices WHERE user_id = ? ORDER BY id", (user_id,)).fetchall()
    return [_choice(r) for r in rows]


# ---------- 질문 기록 (messages, #12 회의 4번) ----------
def _message(r: sqlite3.Row) -> dict:
    d = dict(r)
    d["intents"] = json.loads(d["intents"]) if d["intents"] else None
    return d


def add_message(user_id: str, role: str, text: str, intents: list[dict] | None = None) -> dict:
    """/api/ask 가 질문(user)과 답변(assistant)을 하나씩 저장해요. intents 는 질문의 AI 분류 결과."""
    if role not in ROLES:
        raise ValueError(f"role 은 {ROLES} 중 하나예요")
    with connect() as conn:
        cur = conn.execute(
            "INSERT INTO messages (user_id, role, text, intents) VALUES (?, ?, ?, ?)",
            (user_id, role, text, json.dumps(intents, ensure_ascii=False) if intents is not None else None),
        )
        r = conn.execute("SELECT * FROM messages WHERE id = ?", (cur.lastrowid,)).fetchone()
    return _message(r)


def list_messages(user_id: str, limit: int | None = None) -> list[dict]:
    """오래된 것부터. limit 이 있으면 가장 최근 limit 개만 (그래도 오래된 것부터)."""
    with connect() as conn:
        if limit is None:
            rows = conn.execute("SELECT * FROM messages WHERE user_id = ? ORDER BY id", (user_id,)).fetchall()
        else:
            rows = conn.execute(
                "SELECT * FROM (SELECT * FROM messages WHERE user_id = ? ORDER BY id DESC LIMIT ?) ORDER BY id",
                (user_id, limit),
            ).fetchall()
    return [_message(r) for r in rows]


def recent_messages(user_id: str, turns: int = RECENT_TURNS) -> list[dict]:
    """AI에 함께 보낼 최근 대화. llm.classify_question(history=...) 에 그대로 넣는 모양이에요.

    [{"role": "user", "text": "약국 들러도 돼?"}, {"role": "assistant", "text": "최대 6분 있을 수 있어요."}]
    """
    return [{"role": m["role"], "text": m["text"]} for m in list_messages(user_id, limit=turns * 2)]


def list_user_questions(user_id: str | None = None) -> list[dict]:
    """테스트 케이스로 모을 사용자 질문. user_id 가 없으면 모든 사용자(시연 demo 제외)."""
    sql, args = "SELECT * FROM messages WHERE role = 'user'", []
    if user_id is None:
        sql += " AND user_id != 'demo'"
    else:
        sql += " AND user_id = ?"
        args.append(user_id)
    with connect() as conn:
        rows = conn.execute(sql + " ORDER BY id", args).fetchall()
    return [_message(r) for r in rows]
