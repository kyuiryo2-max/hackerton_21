# 앱 ↔ 서버 API (#12 회의 9번: GitHub 서버 구조 기준)

이 문서는 **지금 서버 코드에 있는 경로**를 기준으로 쓴다. 앱은 이 모양대로 화면을 만들고, 서버를 고치면 이 문서와 예시도 같이 고친다.

- 예시는 [`api-examples/`](api-examples/) 폴더. 파일 하나가 API 묶음 하나다.
- **있음** 표시 예시는 실제 서버 응답을 그대로 저장한 것이다.
- 시연 모드(`demo=true`) 예시는 `data/demo/scenario.json` 고정값으로 계산한 실제 응답이라 항상 같다.
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
| 오류 | `{"error": {"code", "message"}}` 한 형식 → [errors.json](api-examples/errors.json). 코드: `invalid_request` 422, `not_found` 404, `no_route` 404, `demo_readonly` 403, `method_not_allowed` 405, `upstream_error` 502 (외부 API 실패), `not_configured` 503 (키 없음), `db_busy` 503 (잠시 뒤 다시), `server_error` 500 (예상 못 한 오류, 내용은 서버 로그에만). 오류 응답에도 CORS 헤더가 붙는다 |
| 위치 | 목적지 좌표는 저장, 사용자 현재 위치는 받되 저장하지 않음 (실시간 계획 계산에만 씀) |
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
| 있음 | `GET /api/demo/context` | 시연 모드 시각·위치·일정·경로. 지도용 `route.path`(버스 경로 선, `[경도, 위도]`), `route.stop_points`(정류장), `places`(들를 곳 좌표) | [demo_context.json](api-examples/demo_context.json) | routers/transit.py |
| 있음 | `POST /api/tasks/parse` | 할 일 문장 → 장소 종류 (저장 안 함) | [tasks_parse.json](api-examples/tasks_parse.json) | routers/assistant.py |
| 있음 | `POST /api/plan` | 출발 시각, 경로 카드, 할 일 포함·제외. `demo=true`면 시연, 아니면 `origin`(현재 위치)으로 실시간 | [plan.json](api-examples/plan.json) | routers/plan.py |
| 있음 | `POST /api/ask` | 이동 중 질문 → 분류 → 계산 → 답변. 실제 모드는 마지막 실시간 계획의 경로로 계산 (#59) | [ask.json](api-examples/ask.json) | routers/assistant.py |
| 있음 | `GET /api/places/search?query=` | 목적지 장소 검색 (카카오 키워드, 서울 전체·정확도순 최대 10곳, `lat`·`lng`를 주면 그 근처). 응답 `[{name, address, lat, lng}]` (#61) | – | routers/places.py |

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
| `stay_minutes` | 그곳에 머무를 시간(분, 1~120). 만들 때 안 넣으면 첫 장소 종류의 기본값으로 저장 (편의점 4·약국 5·카페 5·은행 10·마트 15·병원 30분 …, `planner.DEFAULT_STAY_MINUTES_BY_TYPE`, 11/13). 장소가 없으면 `null`이고 계산할 때 4분 | 사용자 (화면 −/+) |

계산 모듈(`stopover.decide_stops`)의 결과는 이렇게 바꿔 저장한다: `included` → 포함, `excluded` → 제외, `ask`(필수인데 시간 부족) → 대기 + 앱에 선택지.

## 질문 기록 (#12 회의 4번)

- `/api/ask` 가 질문(`role: user`, AI 분류 결과 `intents`)과 답변(`role: assistant`)을 하나씩 저장한다.
- AI에는 최근 **5턴**(질문+답변 10개)을 함께 보낸다: `repository.recent_messages(user_id)` → `llm.classify_question(text, history=...)`. 3~5턴 안에서 `RECENT_TURNS`로 조정.
- 쌓인 질문은 `scripts/export_questions.py` 로 CSV로 뽑아 정답을 채운 뒤 `ai/testcases/questions.csv`에 더한다 (demo 질문 제외).
- 앱은 `GET /api/messages?user_id=` 로 새로고침 뒤 대화창을 다시 그린다.

## 계획·질문 응답에서 앱이 쓰는 값

**`/api/plan`** ([plan.json](api-examples/plan.json), 실제 응답)
- 요청: `user_id` 필수. `todo_ids`가 없으면 완료하지 않은 할 일 전부. 시연 모드에서는 일정·시각·위치를 시나리오 고정값으로 써서 `schedule_id`는 쓰지 않음
- 들를 장소 종류가 없는 할 일은 계산에서 뺌. 시연 지역에 없는 장소는 `place: null`, 필수면 `대기`·선택이면 `제외`로 보여 주고 상태는 저장하지 않음
- demo가 아닌 사용자는 계산한 `status`가 할 일에 저장됨 (부스 관객이 자기 할 일로 시연)
- **실시간 계획** (`demo=false`): `origin: {"lat", "lng"}` 필수(한국 범위). 현재 위치는 계산에만 쓰고 저장·기록하지 않는다 (11/9 팀 결정). 현재 위치가 들어간 카카오 호출은 메모리 캐시에도 남기지 않는다. `schedule_id`가 없으면 지금 이후 가장 가까운 일정 (지난 일정만 있으면 404 "다가오는 일정이 없어요")
  - **출발 기준 (11/13 팀 결정)**: 응답 `basis`
    - `arrive_by`: 일정으로 찾고 출발까지 30분보다 많이 남음 → 도착 희망 **5분 전**에 닿도록 **거꾸로** 출발 시각(`depart_at`)을 계산. 실시간 도착은 부르지 않음 (지금 오는 차는 그때 탈 차가 아니고, 호출 한도도 아낌)
    - `realtime`: 일정으로 찾고 출발까지 30분 안 → 실시간 차로 탈 차를 정하고, 그 차를 타려면 늦어도 언제 나가야 하는지(`depart_at`)
    - `now`: `destination: {"name", "lat", "lng"}`을 주면(홈 검색창) 일정 없이 **지금 출발**. 일정이 없어도 됨. 할 일은 `todo_ids`로 고른 것만 (없으면 길만), `schedule.arrive_by`는 `null`
  - 카카오 경로 최대 3개. 처음·마지막 도보는 카카오 도보, 첫 탑승 구간은 서울시 버스·지하철 실시간. 실시간 뒤로는 배차 간격으로 1시간까지 이어 붙여 계산
  - 들를 곳은 탑승 정류장 300m 안에서 찾는다. 할 일의 장소 종류를 **모두** 찾아 합치고(예: 이어폰 → 편의점·다이소), 직선거리로 가까운 3곳만 도보 시간을 재서 `candidates`로 보여 준다 (#62, 11/12). 계산은 도보가 가장 짧은 첫 번째 후보로 한다. 후보 도보 시간은 동시에 묻는다
  - 머무는 시간은 할 일의 `stay_minutes`, 없으면 4분
  - 경로 순서: 필수 할 일을 넣는 경로 → 할 일을 많이 넣는 경로 → 빨리 도착하는 경로. 할 일 상태는 1번 경로 기준
  - 실시간을 못 찾으면 대기 0으로 계산하고 `has_realtime: false`. 근처에 장소가 없으면 시연과 같이 필수 `대기`·선택 `제외`, 저장 안 함
  - 오류: `origin` 없음 422, 일정 없음 404 `not_found`, 경로 없음 404 `no_route`, 키 없음 503, 카카오 실패 502
  - 외부 호출은 한 번에 약 30번(카카오 도보가 가장 많음), 같은 구간을 다시 계산하면 저장값으로 약 10번. 후보 3곳(#62)으로 할 일 하나당 도보가 최대 3번까지 늘어난다
  - 1번 경로를 사용자별로 1시간 동안 메모리에 기억해서 이동 중 질문(#59)에 쓴다. 현재 좌표는 넣지 않는다
- 경로 카드의 `first_walk_min`: 현재 위치 → 탑승 정류장 도보(분). 시연은 정류장에 서 있는 장면이라 0
- `depart_at`: 늦어도 출발해야 하는 시각 (11/13). `board_at`, `arrive_at`: 탈 차 도착 시각(실시간이 없으면 정류장 도착 예정), 목적지 도착 예정
- `routes[]`에도 경로마다 `basis`, `depart_at`, `board_at`, `arrive_at` (모든 경로가 같은 기준이라 앱이 순위별로 따로 계산하지 않아도 됨)
- `routes[].legs[]` (11/13): 구간 목록. 처음 도보 → 버스·지하철 → 환승 도보 → … → 마지막 도보
  - `type`(`WALK`/`BUS`/`SUBWAY`), `name`(노선, 도보는 "도보"·"환승 도보"), `from`→`to`(정류장, 처음·끝은 "출발지"·"도착지"), `minutes`, `stop_count`(버스·지하철), `points`(지도에 그릴 `[경도, 위도]` 최대 40개)
- `routes[]`: 경로 카드 2~3개. `total_min`, `wait_min`, `moving_min`, `transfers`, `fare`, `max_stay_min`(경유지에서 쓸 수 있는 최대 시간, 0이면 경유 불가)
- `todos[]`: 할 일마다 `status`(포함/제외/대기)와 들를 장소(`place`, 좌표 `lng`·`lat` 포함). 대기면 `options`를 버튼으로 보여 준다
  - `stay_min`: 머무는 시간(분). 할 일의 `stay_minutes`, 없으면 4분 (시연은 시나리오 값)
  - `candidates[]`: 경유 후보 최대 3곳 (`place_type`, `name`, `address`, `lng`, `lat`, `detour_min`). 첫 번째가 `place`와 같다
- `explanation`: 지금은 계산값으로 만든 정해진 문장. AI 문장(#36)이 붙으면 숫자가 계산과 다를 때 이 문장으로 바뀐다 (`llm.numbers_match`)

**`/api/ask`** ([ask.json](api-examples/ask.json))
- `intents`, `needs_confirm`, `question`: json-format.md 2번 그대로
- `needs_confirm: true` 면 `result: null`, 앱은 `question`을 대화창에 보여 준다
- `todo`: 들르기 질문으로 저장된 할 일 (`source: 질문`, `importance: 필수`). 아니면 `null`
- `todos`: 이번 질문으로 저장된 할 일 전부 (11/12). "편의점 들렀다가 약국도 갈 수 있어?"처럼 들를 곳이 두 군데면 AI가 들르기를 장소마다 따로 뽑고, 서버는 뒤 장소를 앞 장소와 **함께** 들를 수 있는지로 판단한다. `todo`는 그중 마지막 것 (예전 앱 호환)
- `result`: 코드 계산 결과. 질문이 여러 종류면 마지막 계산 결과이고, `answer`는 순서대로 이어 붙인다. #12 회의 8번은 아직 미정이라 아래는 지금 서버 모양이다
  - `next_vehicle`: `route`, `minutes`, `next_minutes`
  - `stopover_check`: `feasible`, `place{name, address}`, `max_stay_min`, `board_at`
  - `running_late`: `delay_minutes`, `missed`, `on_time`, `board_at`, `arrive_at` (뒤 질문도 늦어진 시각으로 계산). 분이 없고 "놓쳤어"면 지금 차를 놓친 것으로 보고 다음 차 기준(`missed: true`), 그 밖에는 "몇 분 늦을 것 같아요?"로 되물음
  - `time_left`: `minutes`, `leave_by` (차 도착에서 여유 2분을 뺀 시각)
  - `place_info`: `place`, `change_route`: `route`, `change_todo`: `todo_id`, `action`, `unsupported`: 없음
  - `demo=false`(실제 모드, #59, 11/12): 교통 질문 6종 모두 마지막 실시간 계획(`/api/plan`, 1시간 안)의 1번 경로로, 실시간 도착을 다시 물어 계산한다. 계획 뒤 지난 시간만큼 정류장으로 걸어갔다고 보고 판단한다(추정)
    - `running_late`: 늦는 분만큼 시각을 미뤄 다시 계산. 분이 없으면 지금 차를 놓친 것으로 봄
    - `stopover_check`·`place_info`: 그 경로의 탑승 정류장 근처에서 찾음. `place_info`는 `places[]`(최대 3곳, `round_trip_min`)도 줌
    - `change_route`: `routes[]`(추천한 경로 요약)를 알려 주기만 하고 경로를 바꾸지 않음. 바꾸는 건 길찾기 화면. `preference`(환승·시간·요금)가 있으면 그 기준으로 가장 좋은 경로를 알려 줌
    - `running_late`의 `delay_minutes: 0`은 "지금 출발하면 늦어?" ("늦지 않아요"까지 답함), `change_todo`의 `action: done`은 "우유는 샀어" → 상태 완료
    - 계획이 없거나 1시간이 지났으면 `{"intent", "available": false}` 와 "먼저 길찾기에서 경로를 추천받아 주세요"
    - 실시간 차가 없을 때 (11/13): 출발이 먼 계획(`basis: arrive_by`)이면 실시간을 부르지 않고 `depart_at`으로 답함 ("17시 48분에 출발하면 돼요", "10분 늦게 출발하면 … 늦어요", 들르기는 "… 출발하면 돼요"). 출발이 가까운데 없으면 "운행 시간이 아니거나 실시간 정보를 주지 않는 노선(마을버스 등)"이라고 이유를 알려 줌
- `answer` (AI 답변 문장, #37, 11/12 모든 질문 종류로 확대): `EXPLAIN_WITH_AI=true`면 코드가 만든 기본 답변을 초안(`draft`)으로 AI에 주고, AI 문장이 아래 검사를 모두 통과할 때만 쓴다. 하나라도 걸리면 기본 답변
  - 숫자: 계산 결과와 초안에 있는 숫자만 (`llm.numbers_match`)
  - 경고 유지: 들르기 불가·늦음·장소 없음이면 "부족해요·늦어요·없어요·못 찾았어요" 같은 말이 있어야 함 (`assistant._ai_content_ok`)
  - 하지 않은 일 금지: 할 일 변경이 아닌데 "삭제했·변경했·예약…"을 말하면 안 됨
  - 200자 이내. 계산을 못 한 안내(`available: false`, 도착 정보 없음, 할 일 못 찾음)는 AI에 보내지 않음
  - 질문이 여러 개면 결과 목록을 함께 보내 한 답으로 이어 말하게 함
- `engine`: `ai` 또는 `rule`. AI 키가 없거나, AI 호출이 실패하거나, AI 출력 형식이 맞지 않으면 키워드 규칙(`services/rules.py`)으로 답한다. 규칙 정확도는 팀 테스트 문장 기준 의도 14/25, 장소 10/15라 AI보다 낮다
- 질문과 할 일 문장은 200자까지
- `demo` 사용자는 부스에서 여럿이 함께 써서 질문 기록을 저장하지 않고 AI에 이전 대화도 보내지 않는다
- `demo` 사용자의 들르기 판단은 시연 계획에서 이미 포함된 할 일(이어폰)과 함께 계산한다. 같은 장소는 다시 더하지 않는다

## 알려진 차이 (고칠 것)

- DB 시연 데이터는 `data/demo/scenario.json`에서 읽어 넣는다 (일정 청량리역, 할 일 이어폰·커피·다이소). 시연 대본을 바꾸면 이 파일만 고치면 된다
- 서울시 실시간 지하철은 호선에 따라 데이터가 빠질 때가 있다 (11/9 오후 6호선 대부분 `INFO-200`). 이때 `/api/arrivals`는 빈 목록이고, 시연은 `demo=true`로 한다
