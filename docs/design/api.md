# 앱 ↔ 서버 API (#12 회의 9번: GitHub 서버 구조 기준)

이 문서는 **지금 서버 코드에 있는 경로**를 기준으로 쓴다. 앱은 이 모양대로 화면을 만들고, 서버를 고치면 이 문서와 예시도 같이 고친다.

- 예시는 [`api-examples/`](api-examples/) 폴더. 파일 하나가 API 묶음 하나다.
- **있음** 표시 예시는 실제 서버 응답을 그대로 저장한 것이다.
- **만들 예정** 예시는 시연 모드 계산 결과(`app/services/demo.py`)로 만든 값이다.
- AI 출력 모양(할 일 → 장소, 질문 → 질문 종류)은 [`json-format.md`](json-format.md)가 기준이다.
- 서버를 켜고 http://127.0.0.1:8000/docs 에서 직접 눌러 볼 수 있다.

## 공통 규칙

| 항목 | 규칙 |
| --- | --- |
| 필드 이름 | `snake_case` |
| 시각 | ISO 8601 + `+09:00` (예: `2026-11-21T09:00:00+09:00`). 시간대 없이 보내면 한국 시간으로 본다 |
| 시간 길이 | 서버 안에서는 초. 앱에 보낼 때 분 정수(`_min`, `minutes`). 이동·도보는 올림, 교통편까지 남은 시간과 최대 체류 시간은 내림 (늦지 않는 쪽) |
| 사용자 | `user_id` (로그인 없음, 기기마다 하나). id로 조회·수정·삭제할 때는 `?user_id=` 필수, 다른 사용자 항목은 404 |
| 시연 | `user_id=demo`. demo 데이터는 API로 바꿀 수 없음(403). 서버가 켜질 때마다 처음 상태로 돌아감 |
| 시연 모드 | `demo=true` 면 시각·위치·도착 정보를 `data/demo/scenario.json` 고정값으로 |
| 오류 | `{"error": {"code", "message"}}` 한 형식 → [errors.json](api-examples/errors.json) |
| 위치 | 목적지 좌표는 저장, 사용자 현재 위치는 받지도 저장하지도 않음 |
| 키 | API 키는 서버에만. 앱은 카카오·서울시·LLM을 직접 부르지 않음 |

## API 목록

| 상태 | API | 하는 일 | 예시 | 코드 |
| --- | --- | --- | --- | --- |
| 있음 | `GET /health` | 서버 확인, 무료 서버 깨우기 | `{"status": "ok"}` | main.py |
| 있음 | `POST·GET /api/schedules`, `GET·PATCH·DELETE /api/schedules/{id}` | 일정 | [schedules.json](api-examples/schedules.json) | routers/storage.py |
| 있음 | `POST·GET /api/todos`, `PATCH·DELETE /api/todos/{id}` | 할 일 (상태·출처 포함) | [todos.json](api-examples/todos.json) | routers/storage.py |
| 있음 | `GET /api/messages` | 질문 기록 조회 (대화창 다시 그리기) | [messages.json](api-examples/messages.json) | routers/storage.py |
| 있음 | `GET·PUT /api/settings/{user_id}` | 경로 선호 가중치 | [settings.json](api-examples/settings.json) | routers/storage.py |
| 있음 | `POST·GET /api/choices` | 고른 경로 기록 (⑧) | [choices.json](api-examples/choices.json) | routers/storage.py |
| 있음 | `GET /api/arrivals` | 도착 정보. 버스 `stop_id`, 지하철 `station`(+`line`). `demo=true`면 시연 고정값, 아니면 서울시 실시간 | [arrivals.json](api-examples/arrivals.json) | routers/transit.py |
| 있음 | `GET /api/demo/context` | 시연 모드 시각·위치·일정·경로 | [demo_context.json](api-examples/demo_context.json) | routers/transit.py |
| 만들 예정 | `POST /api/tasks/parse` | 할 일 문장 → 장소 종류 (저장 안 함) | [tasks_parse.json](api-examples/tasks_parse.json) | #19, #33 |
| 만들 예정 | `POST /api/plan` | 출발 시각, 경로 카드, 할 일 포함·제외 | [plan.json](api-examples/plan.json) | #33, #35 |
| 만들 예정 | `POST /api/ask` | 이동 중 질문 → 분류 → 계산 → 답변 | [ask.json](api-examples/ask.json) | #38, #41 |

경로 선택 기록은 `/api/choices`(복수)다. 기준 문서의 `/api/choice`는 이 이름으로 맞춘다.

## 도착 정보 응답에서 앱이 쓰는 값

**`/api/arrivals`** ([arrivals.json](api-examples/arrivals.json))
- 항목마다 `route`, `minutes`(분, 내림. 0은 곧 도착), `next_minutes`, `direction`. 버스 `direction`은 종점, 지하철은 다음 역(`보문방면`)
- `fetched_at`: 조회 시각. **실시간(`demo=false`)에만** 있다. 시연 모드에는 없음
- `estimated`: 남은 역 수로 계산한 값이면 `true`라 "약"을 붙여 보여 준다. **지하철 실시간에만** 있다. 버스와 시연 모드에는 없음
- 서울시 응답은 버스·지하철 모두 20초 동안 저장해 다시 쓴다 (하루 1,000건 한도)

## 할 일 상태·출처 (#12 회의 3번)

| 필드 | 값 | 누가 바꾸나 |
| --- | --- | --- |
| `status` | `대기` 새로 넣음, 아직 경로 판단 전 / `포함` 이번 경로에 넣음 / `제외` 이번엔 뺌 / `완료` 끝냄 | `/api/plan`·`/api/ask` 결과, 사용자 |
| `source` | `입력` 할 일 화면에서 / `질문` 이동 중 질문(stopover_check)에서 | 저장할 때 한 번 |
| `importance` | `필수` / `선택`. **`source=질문`이면 항상 필수** | 사용자, change_todo |
| `done` | `status == 완료` 와 같음. 예전 앱 호환용으로만 남김 | – |

계산 모듈(`stopover.decide_stops`)의 결과는 이렇게 바꿔 저장한다: `included` → 포함, `excluded` → 제외, `ask`(필수인데 시간 부족) → 대기 + 앱에 선택지.

## 질문 기록 (#12 회의 4번)

- `/api/ask` 가 질문(`role: user`, AI 분류 결과 `intents`)과 답변(`role: assistant`)을 하나씩 저장한다.
- AI에는 최근 **5턴**(질문+답변 10개)을 함께 보낸다: `repository.recent_messages(user_id)` → `llm.classify_question(text, history=...)`. 3~5턴 안에서 `RECENT_TURNS`로 조정.
- 쌓인 질문은 `scripts/export_questions.py` 로 CSV로 뽑아 정답을 채운 뒤 `ai/testcases/questions.csv`에 더한다 (demo 질문 제외).
- 앱은 `GET /api/messages?user_id=` 로 새로고침 뒤 대화창을 다시 그린다.

## 만들 예정 API 응답에서 앱이 쓰는 값

**`/api/plan`** ([plan.json](api-examples/plan.json), 시연 모드 `demo.decide([1, 2, 3])` 결과)
- `board_at`, `arrive_at`: 탈 차 도착 시각, 목적지 도착 예정
- `routes[]`: 경로 카드 2~3개. `total_min`, `wait_min`, `moving_min`, `transfers`, `fare`, `max_stay_min`(경유지에서 쓸 수 있는 최대 시간, 0이면 경유 불가)
- `todos[]`: 할 일마다 `status`(포함/제외/대기)와 들를 장소. 대기면 `options`를 버튼으로 보여 준다
- `explanation`: AI 한두 문장. 숫자가 계산과 다르면 정해진 문장으로 바뀐다 (`llm.numbers_match`)

**`/api/ask`** ([ask.json](api-examples/ask.json))
- `intents`, `needs_confirm`, `question`: json-format.md 2번 그대로
- `needs_confirm: true` 면 `result: null`, 앱은 `question`을 대화창에 보여 준다
- `todo`: 들르기 질문으로 저장된 할 일 (`source: 질문`, `importance: 필수`). 아니면 `null`
- `result`: 코드 계산 결과. **모양은 #12 회의 8번 미정이라 #37에서 확정** (예시는 제안 값)

## 알려진 차이 (고칠 것)

- DB 시연 데이터(`database.seed_demo_data`)는 일정 "공학관", 할 일 "약 사기·엄마 생신 선물"인데, 시연 모드(`scenario.json`)는 청량리역, "이어폰 사기·커피 사기·다이소 들르기"다. #30 시연 대본에 맞춰 하나로 맞추기
- 서울시 실시간 지하철은 호선에 따라 데이터가 빠질 때가 있다 (11/9 오후 6호선 대부분 `INFO-200`). 이때 `/api/arrivals`는 빈 목록이고, 시연은 `demo=true`로 한다
