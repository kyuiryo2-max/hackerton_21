# 틈길 (가칭)

> 일정과 할 일을 말로 적어두면, 언제 준비하고 출발할지 알려주고
> 이동 중 남는 시간에 어떤 할 일을 끼워 넣을 수 있는지 알려주는 이동 보조 서비스

2026 인공지능학과 대학 연합 해커톤 · 팀 Sync-ro

- 배포 주소: (배포 후 추가)
- 시연 영상: (녹화 후 추가)

## 서비스 흐름

```
① 입력 → ② AI 이해 → ③ 조회 → ④ 계산 → ⑤ 추천 → ⑥ 알림
                                         ↑
                 ⑦ 대화형 질문 (②~④ 다시 실행)    ⑧ 선택 피드백
```

| 단계 | 하는 일 | 담당 |
|---|---|---|
| ① 입력 | 목적지, 도착 희망 시각, 준비 시간, 할 일(자연어) | 코드 |
| ② AI 이해 | 할 일 → 장소 종류, 질문 → 질문 종류 (JSON) | **AI** |
| ③ 조회 | 좌표 변환, 주변 장소, 도보 경로, 버스·지하철 도착 정보 | 코드 |
| ④ 계산 | 경로 총 시간, 최대로 쓸 수 있는 시간, 출발·준비 시각 | 코드 |
| ⑤ 추천 | 결과 안내 + 설명 문장 생성 | 코드 + **AI** |
| ⑥ 알림 | 화면이 켜져 있을 때 준비·출발·돌아올 시각 안내 | 코드 |
| ⑦ 대화형 질문 | "다음 버스 언제야?", "들렀다 가도 돼?" | **AI** + 코드 |
| ⑧ 피드백 | 고른 경로로 선호 가중치 조정 | 학습 |

## 개발 환경

| 구분 | 버전 |
|---|---|
| Flutter | **3.35.7** (웹 빌드 기준) |
| Python | **3.12.16** |
| FastAPI | **0.118.3** |
| 패키지 관리 | uv (`uv.lock`으로 버전 고정) |
| DB | SQLite |
| LLM | OpenRouter (OpenAI 호환 SDK) |

## 폴더 구조

```
app/        Flutter 앱 (웹)
server/     FastAPI 서버
  app/routers/    API 주소
  app/services/   조회·계산·LLM 모듈
  app/db/         SQLite
  tests/          계산 모듈 테스트
ai/
  prompts/    프롬프트 버전 (v1, v2 …)
  testcases/  테스트 문장 + 정답 CSV
  eval/       키워드 vs AI 정답률 비교
data/
  samples/    API 응답 샘플 JSON
  demo/       시연 지역 데이터, 장소 종류 표
docs/
  research/     설문 요약, 인터뷰 메모 (개인정보 X)
  design/       화면 스케치, JSON 형식 정의
  reports/      중간·최종 보고서, 테스트 결과표
  presentation/ 포스터, 발표 자료, 시연 대본
scripts/    GitHub 이슈 생성 스크립트 등
```

## 실행 방법

### 서버
```bash
uv self update                 # 예전 uv는 3.12.16을 못 받아요. 먼저 최신으로
uv python install 3.12.16
cd server
cp ../.env.example ../.env     # 키 값 채우기
uv sync
uv run uvicorn app.main:app --reload
# http://127.0.0.1:8000/health
```

테스트:
```bash
cd server
uv run pytest
```

### 앱 (Flutter 웹)
```bash
flutter --version              # 3.35.7 확인
cd app
flutter pub get
flutter run -d chrome
```

## 협업 규칙

- **main에 직접 push 금지.** 기능 하나당 브랜치 하나 → PR → 팀원 1명 확인 후 머지
- 브랜치 이름: `feat/<이슈번호>-<짧은설명>` (예: `feat/29-max-stay-time`), 문서는 `docs/<번호>-...`
- PR 본문에 `Closes #이슈번호`를 쓰면 머지할 때 이슈가 자동으로 닫혀요
- **API 키는 `.env`에만.** 코드·카톡·노션에 붙여넣지 않기. 배포 서버 키는 GitHub/배포 서비스의 Secrets에
- 설문 원본(이름·연락처)은 올리지 않고 요약본만 `docs/research/`에
- 매일 밤 10시: 단톡에 "오늘 끝낸 이슈 번호 / 막힌 것" 한 줄 공유

## 일정

| 마일스톤 | 날짜 |
|---|---|
| M1 중간 보고 | 11/8 (일) 23:59 |
| M2 기능 완성 | 11/12 (목) |
| M3 최종 제출 (포스터, 배포 링크, 시연 영상, 보고서) | 11/16 (월) |
| M4 본행사 (결선 발표 팀 공개 11/20) | 11/21 (토) |
