"""SQLite 연결과 테이블 생성.

무료 배포 서버는 재시작하면 DB 파일이 초기화될 수 있어서,
서버가 켜질 때 시연용 데이터를 지우고 처음 상태로 다시 넣어요 (seed_demo_data).
목적지 좌표는 저장하지만, 사용자의 현재 위치는 저장하지 않아요.
시각은 모두 한국 시간 ISO 8601 (예: 2026-11-21T09:00:00+09:00) 이에요.
"""
import sqlite3
from contextlib import contextmanager

from app import config

DEMO_USER_ID = "demo"

SCHEMA = """
CREATE TABLE IF NOT EXISTS schedules (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id         TEXT NOT NULL,
    destination     TEXT NOT NULL,
    destination_lat REAL NOT NULL,          -- 목적지 좌표 (현재 위치 아님)
    destination_lng REAL NOT NULL,
    arrive_by       TEXT NOT NULL,          -- 예: 2026-11-21T09:00:00+09:00
    prep_minutes    INTEGER NOT NULL DEFAULT 30
);

CREATE TABLE IF NOT EXISTS todos (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id         TEXT NOT NULL,
    text            TEXT NOT NULL,          -- 사용자가 쓴 원문: "엄마 생신 선물"
    place_types     TEXT,                   -- AI 결과(JSON 문자열): ["꽃집","케이크집"]
    importance      TEXT NOT NULL DEFAULT '선택',  -- 필수 / 선택
    done            INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS settings (
    user_id         TEXT PRIMARY KEY,
    w_time          REAL NOT NULL DEFAULT 0.6,
    w_transfer      REAL NOT NULL DEFAULT 0.3,
    w_fare          REAL NOT NULL DEFAULT 0.1
);

CREATE TABLE IF NOT EXISTS route_choices (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id         TEXT NOT NULL,
    chosen_route    TEXT NOT NULL,          -- 고른 경로 특징(JSON 문자열)
    other_routes    TEXT NOT NULL,          -- 안 고른 후보들(JSON 문자열)
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%S+09:00', 'now', '+9 hours'))
);
"""


@contextmanager
def connect(path: str | None = None):
    conn = sqlite3.connect(path or config.DATABASE_PATH)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def init_db(path: str | None = None) -> None:
    with connect(path) as conn:
        conn.executescript(SCHEMA)


def seed_demo_data(path: str | None = None) -> None:
    """시연용 사용자 데이터. 켜질 때마다 demo 데이터를 지우고 처음 상태로 다시 넣어요."""
    with connect(path) as conn:
        for table in ("schedules", "todos", "settings", "route_choices"):
            conn.execute(f"DELETE FROM {table} WHERE user_id = ?", (DEMO_USER_ID,))
        conn.execute(
            "INSERT INTO schedules (user_id, destination, destination_lat, destination_lng, arrive_by, prep_minutes) "
            "VALUES (?, '공학관', 37.5833, 127.0263, '2026-11-21T09:00:00+09:00', 30)",
            (DEMO_USER_ID,),
        )
        conn.executemany(
            "INSERT INTO todos (user_id, text, place_types, importance) VALUES (?, ?, ?, ?)",
            [
                (DEMO_USER_ID, "약 사기", '["약국"]', "필수"),
                (DEMO_USER_ID, "엄마 생신 선물", '["꽃집","케이크집"]', "선택"),
            ],
        )
        conn.execute("INSERT INTO settings (user_id) VALUES (?)", (DEMO_USER_ID,))
