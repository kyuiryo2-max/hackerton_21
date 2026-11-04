"""작업 표(scripts/tasks.csv)를 GitHub 라벨·마일스톤·이슈로 한 번에 만들어요.

준비:
  1) GitHub CLI 설치 후 로그인:  gh auth login
  2) 저장소 폴더 안에서 실행 (원격 저장소가 연결돼 있어야 해요)

실행:
  python scripts/create_issues.py --dry-run   # 만들 내용만 미리 보기
  python scripts/create_issues.py             # 실제로 만들기

여러 번 실행해도 같은 제목의 이슈는 다시 만들지 않아요.
"""
import csv
import json
import re
import subprocess
import sys
from pathlib import Path

DRY = "--dry-run" in sys.argv
CSV_PATH = Path(__file__).with_name("tasks.csv")

LABELS = {
    "기획": "C5DEF5", "AI": "D4C5F9", "서버": "BFD4F2", "앱": "C2E0C6",
    "전원": "FEF2C0", "P1": "B60205", "P2": "FBCA04", "P3": "0E8A16",
    "blocked": "000000",
}
# 마감은 한국 시간 23:59 → UTC 14:59
MILESTONES = {
    "M1 중간 보고": "2026-11-08T14:59:59Z",
    "M2 기능 완성": "2026-11-12T14:59:59Z",
    "M3 최종 제출": "2026-11-16T14:59:59Z",
    "M4 본행사": "2026-11-21T14:59:59Z",
}


def gh(*args: str) -> str:
    if DRY:
        print("  gh", " ".join(args)[:140])
        return ""
    res = subprocess.run(["gh", *args], capture_output=True, text=True)
    if res.returncode != 0:
        sys.exit(f"gh 오류: {' '.join(args)[:80]}\n{res.stderr}")
    return res.stdout


def gh_json(*args: str):
    if DRY:
        return []
    out = subprocess.run(["gh", *args], capture_output=True, text=True, check=True).stdout
    return json.loads(out or "[]")


def task_numbers(text: str) -> list[int]:
    """'20~22', '5, 14', '9, 10, 11' → [20,21,22], [5,14], [9,10,11]"""
    nums: list[int] = []
    for part in re.split(r"[,\s]+", text):
        m = re.fullmatch(r"(\d+)~(\d+)", part)
        if m:
            nums += list(range(int(m[1]), int(m[2]) + 1))
        elif part.isdigit():
            nums.append(int(part))
    return nums


def body(row: dict, links: dict[int, int]) -> str:
    deps = task_numbers(row["선행"])
    dep_txt = ", ".join(
        f"#{links[n]}" if n in links else f"작업 {n}" for n in deps
    ) or "없음"
    return (
        f"**날짜:** {row['날짜']}\n"
        f"**분야 / 순위:** {row['분야']} / {row['순위']}\n"
        f"**선행 작업:** {dep_txt}\n"
        f"**결과물:** {row['결과물']}\n"
        f"**완료 기준:** {row['완료 기준']}\n"
    )


def main() -> None:
    rows = list(csv.DictReader(CSV_PATH.open(encoding="utf-8")))
    print(f"작업 {len(rows)}개 {'(미리 보기)' if DRY else ''}")

    print("1) 라벨")
    for name, color in LABELS.items():
        gh("label", "create", name, "--color", color, "--force")

    print("2) 마일스톤")
    existing = {m["title"] for m in gh_json("api", "repos/{owner}/{repo}/milestones?state=all")}
    for title, due in MILESTONES.items():
        if title not in existing:
            gh("api", "repos/{owner}/{repo}/milestones", "-f", f"title={title}", "-f", f"due_on={due}")

    print("3) 이슈")
    existing_issues = {
        i["title"]: i["number"]
        for i in gh_json("issue", "list", "--state", "all", "--limit", "500", "--json", "title,number")
    }
    links: dict[int, int] = {}
    for row in rows:
        n = int(row["순서"])
        title = f"[{n}] {row['작업']}"
        if title in existing_issues:
            links[n] = existing_issues[title]
            continue
        labels = [p for p in re.split(r"[·,]", row["분야"]) if p in LABELS]
        if row["순위"] in ("1", "2", "3"):
            labels.append(f"P{row['순위']}")
        args = ["issue", "create", "--title", title, "--body", body(row, links),
                "--milestone", row["마일스톤"]]
        for lb in labels:
            args += ["--label", lb]
        out = gh(*args)
        m = re.search(r"/issues/(\d+)", out)
        if m:
            links[n] = int(m[1])

    print("4) 선행 작업을 이슈 링크로 바꾸기")
    for row in rows:
        n = int(row["순서"])
        if n in links and task_numbers(row["선행"]):
            gh("issue", "edit", str(links[n]), "--body", body(row, links))

    print("완료!")


if __name__ == "__main__":
    main()
