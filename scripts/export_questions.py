"""질문 기록 → 테스트 케이스 후보 (#12 회의 4번).

DB의 사용자 질문(messages, role=user)을 CSV로 뽑아요. 시연용 demo 질문은 빼요.
expected_intents 칸은 비어 있어요. 사람이 정답을 채운 줄만 ai/testcases/questions.csv 로 옮기면 돼요.

실행 (server 폴더에서, 서버가 쓰는 DB 파일 기준):
  uv run python ../scripts/export_questions.py
  uv run python ../scripts/export_questions.py --db 다른.db --user u1
결과: ai/testcases/collected_questions_<날짜>.csv
"""
import argparse
import csv
import sys
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "server"))

from app import config  # noqa: E402
from app.db import repository as repo  # noqa: E402
from app.db.database import init_db  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", default=None, help="DB 파일 (기본: .env 의 DATABASE_PATH)")
    parser.add_argument("--user", default=None, help="한 사용자만 (기본: demo 를 뺀 전체)")
    args = parser.parse_args()
    if args.db:
        config.DATABASE_PATH = args.db
    if not Path(config.DATABASE_PATH).exists():
        sys.exit(f"DB 파일이 없어요: {config.DATABASE_PATH}")
    init_db()  # 예전 DB 파일이면 messages 표를 만들어요

    questions = repo.list_user_questions(args.user)
    out = ROOT / "ai" / "testcases" / f"collected_questions_{date.today().isoformat()}.csv"
    with open(out, "w", encoding="utf-8-sig", newline="") as f:  # 엑셀에서도 한글이 안 깨지게
        writer = csv.writer(f)
        writer.writerow(["id", "text", "ai_intents", "expected_intents", "user_id", "created_at"])
        for i, q in enumerate(questions, 1):
            ai = "|".join(it.get("intent", "") for it in q["intents"] or [])
            writer.writerow([f"C{i:02d}", q["text"], ai, "", q["user_id"], q["created_at"]])
    print(f"질문 {len(questions)}개 → {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
