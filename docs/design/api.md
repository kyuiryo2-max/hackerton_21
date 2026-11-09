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
| 있음 | `GET /api/arrivals` | 정류소 도착 정보 (지금은 `demo=true`만, 실시간은 501) | [arrivals.json](api-examples/arrivals.json) | routers/transit.py |
| 있음 | `GET /api/demo/context` | 시연 모드 시각·위치·일정·경로 | [demo_context.json](api-examples/demo_context.json) | routers/transit.py |
| 만들 예정 | `POST /api/tasks/parse` | 할 일 문장 → 장소 종류 (저장 안 함) | [tasks_parse.json](api-examples/tasks_parse.json) | #19, #33 |
| 있음 | `POST /api/plan` | 출발 시각, 경로 카드, 할 일 포함·제외 (지금은 `demo=true`만, 실시간은 501) | [plan.json](api-examples/plan.json) | routers/plan.py |
| 만들 예정 | `POST /api/ask` | 이동 중 질문 → 분류 → 계산 → 답변 | [ask.json](api-examples/ask.json) | #38, #41 |

경로 선택 기록은 `/api/choices`(복수)다. 기준 문서의 `/api/choice`는 이 이름으로 맞춘다.

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

**`/api/plan`** ([plan.json](api-examples/plan.json), 실제 응답)
- 요청: `user_id` 필수. `todo_ids`가 없으면 완료하지 않은 할 일 전부. 시연 모드에서는 일정·시각·위치를 시나리오 고정값으로 써서 `schedule_id`는 쓰지 않음
- 들를 장소 종류가 없는 할 일은 계산에서 뺌. 시연 지역에 없는 장소는 `place: null`, 필수면 `대기`·선택이면 `제외`로 보여 주고 상태는 저장하지 않음
- demo가 아닌 사용자는 계산한 `status`가 할 일에 저장됨 (부스 관객이 자기 할 일로 시연)
- `board_at`, `arrive_at`: 탈 차 도착 시각, 목적지 도착 예정
- `routes[]`: 경로 카드 2~3개. `total_min`, `wait_min`, `moving_min`, `transfers`, `fare`, `max_stay_min`(경유지에서 쓸 수 있는 최대 시간, 0이면 경유 불가)
- `todos[]`: 할 일마다 `status`(포함/제외/대기)와 들를 장소. 대기면 `options`를 버튼으로 보여 준다
- `explanation`: 지금은 계산값으로 만든 정해진 문장. AI 문장(#36)이 붙으면 숫자가 계산과 다를 때 이 문장으로 바뀐다 (`llm.numbers_match`)

**`/api/ask`** ([ask.json](api-examples/ask.json))
- `intents`, `needs_confirm`, `question`: json-format.md 2번 그대로
- `needs_confirm: true` 면 `result: null`, 앱은 `question`을 대화창에 보여 준다
- `todo`: 들르기 질문으로 저장된 할 일 (`source: 질문`, `importance: 필수`). 아니면 `null`
- `result`: 코드 계산 결과. **모양은 #12 회의 8번 미정이라 #37에서 확정** (예시는 제안 값)

## 알려진 차이 (고칠 것)

- DB 시연 데이터는 `data/demo/scenario.json`에서 읽어 넣는다 (일정 청량리역, 할 일 이어폰·커피·다이소). 시연 대본을 바꾸면 이 파일만 고치면 된다
- `/api/plan` 실시간(`demo=false`)은 출발 위치가 필요하다. "현재 위치를 받지 않는다" 규칙과 맞물려 있어 정하기 전까지 501
- `/api/arrivals` 실시간(`demo=false`)은 서울 버스 모듈(PR #10)과 아직 연결 안 됨 → 501
